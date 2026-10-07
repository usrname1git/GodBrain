#include "jarvis_job.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cctype>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>

#include "../cpp_tools/keccak256.hpp"

#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable : 4127)
#endif
#include "json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

namespace jarvis_job {
namespace {

using json = nlohmann::json;

constexpr size_t kMaxBytes = 256 * 1024;
constexpr DWORD kVerifyMs = 20000;

struct State {
    std::string id;
    std::string status;
    std::string file_name;
    std::string verifier_name;
    std::string old_text;
    std::string new_text;
    std::string before_hash;
    std::string after_hash;
    std::string original;
    std::string patched;
    int writes = 0;
    int verifier_exit = -1;
    bool authorized = false;
    std::string lesson_trust;
    std::string lesson;
};

std::string content_hash(const std::string& body) {
    uint8_t hash[32] = {};
    Keccak256::getHash(reinterpret_cast<const uint8_t*>(body.data()), body.size(), hash);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (int i = 0; i < 32; ++i) {
        out << std::setw(2) << static_cast<int>(hash[i]);
    }
    return out.str();
}

std::string canon(const std::string& path) {
    char buf[MAX_PATH] = {};
    DWORD n = GetFullPathNameA(path.c_str(), MAX_PATH, buf, nullptr);
    if (n == 0 || n >= MAX_PATH) return "";
    return std::string(buf);
}

bool single_segment(const std::string& name) {
    if (name.empty() || name.size() > 64 || name == "." || name == "..") return false;
    if (name == "jarvis-job.json") return false;
    for (unsigned char c : name) {
        if (std::isalnum(c) != 0 || c == '.' || c == '_' || c == '-') continue;
        return false;
    }
    return true;
}

std::string state_path(const std::string& work_dir) {
    return work_dir + "\\jarvis-job.json";
}

bool read_all(const std::string& path, std::string* body) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream out;
    out << in.rdbuf();
    if (!in && !in.eof()) return false;
    *body = out.str();
    return body->size() <= kMaxBytes;
}

bool write_all(const std::string& path, const std::string& body) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(body.data(), static_cast<std::streamsize>(body.size()));
        if (!out) return false;
    }
    return MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

json state_json(const State& st) {
    return json{
        {"id", st.id},
        {"status", st.status},
        {"file_name", st.file_name},
        {"verifier_name", st.verifier_name},
        {"old_text", st.old_text},
        {"new_text", st.new_text},
        {"before_hash", st.before_hash},
        {"after_hash", st.after_hash},
        {"original", st.original},
        {"patched", st.patched},
        {"writes", st.writes},
        {"verifier_exit", st.verifier_exit},
        {"authorized", st.authorized},
        {"lesson_trust", st.lesson_trust},
        {"lesson", st.lesson},
    };
}

bool save_state(const std::string& work_dir, const State& st) {
    return write_all(state_path(work_dir), state_json(st).dump());
}

bool load_state(const std::string& work_dir, State* st) {
    std::string body;
    if (!read_all(state_path(work_dir), &body)) return false;
    json doc;
    try {
        doc = json::parse(body);
    } catch (const json::exception&) {
        return false;
    }
    if (!doc.is_object()) return false;
    st->id = doc.value("id", "");
    st->status = doc.value("status", "");
    st->file_name = doc.value("file_name", "");
    st->verifier_name = doc.value("verifier_name", "");
    st->old_text = doc.value("old_text", "");
    st->new_text = doc.value("new_text", "");
    st->before_hash = doc.value("before_hash", "");
    st->after_hash = doc.value("after_hash", "");
    st->original = doc.value("original", "");
    st->patched = doc.value("patched", "");
    st->writes = doc.value("writes", 0);
    st->verifier_exit = doc.value("verifier_exit", -1);
    st->authorized = doc.value("authorized", false);
    st->lesson_trust = doc.value("lesson_trust", "");
    st->lesson = doc.value("lesson", "");
    return single_segment(st->file_name) && single_segment(st->verifier_name);
}

Outcome from_state(const State& st, bool paused_ok) {
    Outcome out;
    out.ok = st.status == "verified" || paused_ok;
    out.status = st.status;
    out.id = st.id;
    out.before_hash = st.before_hash;
    out.after_hash = st.after_hash;
    out.writes = st.writes;
    out.verifier_exit = st.verifier_exit;
    out.lesson_trust = st.lesson_trust;
    out.lesson = st.lesson;
    return out;
}

bool terminal(const std::string& status) {
    return status == "denied" || status == "cancelled" || status == "verified" ||
           status == "rolled_back" || status == "failed";
}

void set_lesson(State* st) {
    st->lesson_trust = "candidate";
    st->lesson = "candidate " + st->id + " before=" + st->before_hash + " after=" + st->after_hash +
                 " verifier=" + std::to_string(st->verifier_exit) + " status=" + st->status;
}

std::string find_pwsh() {
    char buf[MAX_PATH] = {};
    DWORD n = SearchPathA(nullptr, "pwsh.exe", nullptr, MAX_PATH, buf, nullptr);
    if (n > 0 && n < MAX_PATH) return std::string(buf);
    const char* fixed = "C:\\pwsh\\pwsh.exe";
    if (GetFileAttributesA(fixed) != INVALID_FILE_ATTRIBUTES) return fixed;
    return "";
}

std::string quote_arg(const std::string& text) {
    if (text.empty() || text.find('"') != std::string::npos) return "";
    return "\"" + text + "\"";
}

int run_verifier(const std::string& work_dir, const std::string& script, const std::string& fixture) {
    const std::string pwsh = find_pwsh();
    const std::string qp = quote_arg(pwsh);
    const std::string qs = quote_arg(script);
    const std::string qf = quote_arg(fixture);
    if (qp.empty() || qs.empty() || qf.empty()) return -1;
    std::string cmd = qp + " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + qs + " -Fixture " + qf;
    std::vector<char> mutable_cmd(cmd.begin(), cmd.end());
    mutable_cmd.push_back('\0');

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE nul = CreateFileA("NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &sa, OPEN_EXISTING, 0, nullptr);
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    if (nul != INVALID_HANDLE_VALUE) {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = nul;
        si.hStdOutput = nul;
        si.hStdError = nul;
    }
    PROCESS_INFORMATION pi{};
    const BOOL created = CreateProcessA(nullptr, mutable_cmd.data(), nullptr, nullptr, TRUE,
                                        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, work_dir.c_str(), &si, &pi);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!created) return -1;

    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    const bool job_ok = job != nullptr &&
                        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info)) &&
                        AssignProcessToJobObject(job, pi.hProcess);
    if (!job_ok) {
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        if (job) CloseHandle(job);
        return -1;
    }
    ResumeThread(pi.hThread);
    const DWORD wait = WaitForSingleObject(pi.hProcess, kVerifyMs);
    int code = -1;
    if (wait == WAIT_TIMEOUT) {
        TerminateJobObject(job, 1);
        WaitForSingleObject(pi.hProcess, 5000);
    } else {
        DWORD exit_code = 1;
        if (GetExitCodeProcess(pi.hProcess, &exit_code)) code = static_cast<int>(exit_code);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(job);
    return code;
}

std::string file_path(const std::string& work_dir, const std::string& name) {
    return work_dir + "\\" + name;
}

bool restore_original(const std::string& path, const State& st) {
    if (!write_all(path, st.original)) return false;
    std::string back;
    if (!read_all(path, &back)) return false;
    return content_hash(back) == st.before_hash;
}

Outcome finish_saved(const std::string& work_dir, State* st, bool paused_ok) {
    if (!save_state(work_dir, *st)) {
        Outcome out = from_state(*st, false);
        out.ok = false;
        out.status = "failed";
        return out;
    }
    return from_state(*st, paused_ok);
}

Outcome verify_and_close(const std::string& work_dir, State* st) {
    const std::string path = file_path(work_dir, st->file_name);
    const std::string script = file_path(work_dir, st->verifier_name);
    st->verifier_exit = run_verifier(work_dir, script, path);
    if (st->verifier_exit == 0) {
        std::string now;
        if (!read_all(path, &now) || content_hash(now) != st->after_hash) {
            st->status = "failed";
            return finish_saved(work_dir, st, false);
        }
        st->status = "verified";
        set_lesson(st);
        return finish_saved(work_dir, st, false);
    }
    if (!restore_original(path, *st)) {
        st->status = "failed";
        return finish_saved(work_dir, st, false);
    }
    st->status = "rolled_back";
    set_lesson(st);
    return finish_saved(work_dir, st, false);
}

Outcome continue_job(const std::string& work_dir, State* st, const std::string& stop_after) {
    const std::string path = file_path(work_dir, st->file_name);
    std::string now;
    if (!read_all(path, &now)) {
        st->status = "failed";
        return finish_saved(work_dir, st, false);
    }
    const std::string now_hash = content_hash(now);
    if (st->status == "proposed") {
        if (now_hash == st->after_hash) {
            st->status = "applied";
        } else if (now_hash == st->before_hash) {
            if (!write_all(path, st->patched)) {
                st->status = "failed";
                return finish_saved(work_dir, st, false);
            }
            std::string written;
            if (!read_all(path, &written) || content_hash(written) != st->after_hash) {
                st->status = "failed";
                return finish_saved(work_dir, st, false);
            }
            st->writes += 1;
            st->status = "applied";
        } else {
            st->status = "failed";
            return finish_saved(work_dir, st, false);
        }
        // Pause before the verifier so resume can prove it does not write again.
        if (stop_after == "applied") return finish_saved(work_dir, st, true);
        if (!save_state(work_dir, *st)) {
            st->status = "failed";
            return finish_saved(work_dir, st, false);
        }
    }
    if (st->status == "applied") {
        std::string applied;
        if (!read_all(path, &applied) || content_hash(applied) != st->after_hash) {
            st->status = "failed";
            return finish_saved(work_dir, st, false);
        }
        return verify_and_close(work_dir, st);
    }
    st->status = "failed";
    return finish_saved(work_dir, st, false);
}

}  // namespace

Outcome run(const Request& request) {
    Outcome out;
    const std::string work = canon(request.work_dir);
    if (work.empty() || !single_segment(request.file_name) || !single_segment(request.verifier_name)) {
        out.status = "failed";
        return out;
    }
    if (!request.stop_after.empty() && request.stop_after != "proposed" && request.stop_after != "applied") {
        out.status = "failed";
        return out;
    }
    const DWORD attr = GetFileAttributesA(work.c_str());
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        out.status = "failed";
        return out;
    }
    if (GetFileAttributesA(state_path(work).c_str()) != INVALID_FILE_ATTRIBUTES) {
        out.status = "failed";
        return out;
    }
    const std::string script = file_path(work, request.verifier_name);
    if (GetFileAttributesA(script.c_str()) == INVALID_FILE_ATTRIBUTES) {
        out.status = "failed";
        return out;
    }

    State st;
    st.file_name = request.file_name;
    st.verifier_name = request.verifier_name;
    st.old_text = request.old_text;
    st.new_text = request.new_text;
    st.authorized = request.authorized;
    const std::string path = file_path(work, request.file_name);
    if (!read_all(path, &st.original)) {
        st.status = "failed";
        st.id = "000000000000";
        finish_saved(work, &st, false);
        return from_state(st, false);
    }
    st.before_hash = content_hash(st.original);
    st.id = st.before_hash.substr(0, 12);
    if (!request.authorized) {
        st.status = "denied";
        return finish_saved(work, &st, false);
    }
    if (request.old_text.empty() || request.old_text == request.new_text) {
        st.status = "failed";
        return finish_saved(work, &st, false);
    }
    const size_t at = st.original.find(request.old_text);
    if (at == std::string::npos) {
        st.status = "failed";
        return finish_saved(work, &st, false);
    }
    st.patched = st.original;
    st.patched.replace(at, request.old_text.size(), request.new_text);
    if (st.patched.size() > kMaxBytes) {
        st.status = "failed";
        return finish_saved(work, &st, false);
    }
    st.after_hash = content_hash(st.patched);
    st.status = "proposed";
    st.writes = 0;
    if (request.stop_after == "proposed") return finish_saved(work, &st, true);
    return continue_job(work, &st, request.stop_after);
}

Outcome resume(const std::string& work_dir) {
    const std::string work = canon(work_dir);
    State st;
    if (work.empty() || !load_state(work, &st)) {
        Outcome out;
        out.status = "failed";
        return out;
    }
    if (terminal(st.status)) return from_state(st, false);
    if (st.status == "proposed" || st.status == "applied") return continue_job(work, &st, "");
    st.status = "failed";
    return finish_saved(work, &st, false);
}

Outcome cancel(const std::string& work_dir) {
    const std::string work = canon(work_dir);
    State st;
    if (work.empty() || !load_state(work, &st)) {
        Outcome out;
        out.status = "failed";
        return out;
    }
    if (terminal(st.status)) return from_state(st, false);
    st.status = "cancelled";
    return finish_saved(work, &st, false);
}

}  // namespace jarvis_job
