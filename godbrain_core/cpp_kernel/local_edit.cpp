#include "local_edit.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <map>
#include <mutex>
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

namespace local_edit {
namespace {

using json = nlohmann::json;

std::string exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    const size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

std::string repo_root() {
    std::string dir = exe_dir();
    if (dir.empty()) return "";
    dir += "\\..\\..";
    char canon[MAX_PATH];
    if (GetFullPathNameA(dir.c_str(), MAX_PATH, canon, nullptr) == 0) return "";
    return std::string(canon);
}

std::string ascii_lower(std::string value) {
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string replace_slashes(std::string path) {
    for (char& ch : path) {
        if (ch == '/') ch = '\\';
    }
    return path;
}

bool ends_with(const std::string& value, const std::string& suf) {
    return value.size() >= suf.size() &&
           value.compare(value.size() - suf.size(), suf.size(), suf) == 0;
}

std::string content_hash(const std::string& body) {
    uint8_t hash[32] = {};
    Keccak256::getHash(
        reinterpret_cast<const uint8_t*>(body.data()), body.size(), hash);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (int i = 0; i < 32; ++i) {
        out << std::setw(2) << static_cast<int>(hash[i]);
    }
    return out.str();
}

std::string clip_preview(std::string text, size_t max) {
    if (text.size() > max) {
        text.resize(max);
        text += "...";
    }
    return text;
}

std::string json_escape(const std::string& text) {
    std::ostringstream out;
    for (unsigned char ch : text) {
        if (ch == '\\' || ch == '"') {
            out << '\\' << static_cast<char>(ch);
        } else if (ch == '\n') {
            out << "\\n";
        } else if (ch == '\r') {
            continue;
        } else {
            out << static_cast<char>(ch);
        }
    }
    return out.str();
}

std::string check_profile_for_impl(std::string rel) {
    rel = ascii_lower(replace_slashes(rel));
    if (rel == "godbrain_core\\frontend\\galaxy.html") {
        return "galaxy-html-static-v1";
    }
    if (rel.rfind("godbrain_core\\memory_store\\", 0) == 0 && ends_with(rel, ".go")) {
        return "memory-store-go-v1";
    }
    if (rel == "godbrain_core\\cpp_tools\\librarian.cpp") {
        return "librarian-self-test-v1";
    }
    if (rel.rfind("godbrain_core\\cpp_kernel\\", 0) == 0 &&
        (ends_with(rel, ".cpp") || ends_with(rel, ".h"))) {
        return "kernel-file-v1";
    }
    if (ends_with(rel, ".ps1")) return "powershell-parse-v1";
    return "local-edit-apply-v1";
}

std::string find_pwsh() {
    char buf[MAX_PATH] = {};
    DWORD n = SearchPathA(nullptr, "pwsh.exe", nullptr, MAX_PATH, buf, nullptr);
    if (n > 0 && n < MAX_PATH) return std::string(buf);
    n = SearchPathA(nullptr, "powershell.exe", nullptr, MAX_PATH, buf, nullptr);
    if (n > 0 && n < MAX_PATH) return std::string(buf);
    return "";
}

struct CheckOutcome {
    bool ran = false;
    bool ok = false;
    std::string profile;
    std::string detail;
};

CheckOutcome run_edit_check(const std::vector<std::string>& edited) {
    CheckOutcome out;
    if (edited.empty()) {
        out.profile = "local-edit-apply-v1";
        return out;
    }
    std::vector<std::string> profiles;
    for (const auto& rel : edited) {
        const std::string profile = check_profile_for_impl(rel);
        if (std::find(profiles.begin(), profiles.end(), profile) == profiles.end()) {
            profiles.push_back(profile);
        }
    }
    std::ostringstream joined;
    for (size_t i = 0; i < profiles.size(); ++i) {
        if (i) joined << "+";
        joined << profiles[i];
    }
    out.profile = joined.str();
    const std::string root = repo_root();
    const std::string script = root + "\\scripts\\Verify-LocalEdit.ps1";
    if (root.empty() || GetFileAttributesA(script.c_str()) == INVALID_FILE_ATTRIBUTES) {
        out.detail = "missing Verify-LocalEdit.ps1";
        return out;
    }
    const std::string shell = find_pwsh();
    if (shell.empty()) {
        out.detail = "pwsh not on PATH";
        return out;
    }
    std::ostringstream cmd;
    cmd << '"' << shell << "\" -NoProfile -ExecutionPolicy Bypass -File \""
        << script << "\" -RepoRoot \"" << root << "\" -PathList \"";
    for (size_t i = 0; i < edited.size(); ++i) {
        if (i) cmd << ';';
        cmd << replace_slashes(edited[i]);
    }
    cmd << '"';
    std::string cmdline = cmd.str();
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE out_rd = nullptr;
    HANDLE out_wr = nullptr;
    if (!CreatePipe(&out_rd, &out_wr, &sa, 0)) {
        out.detail = "pipe failed";
        return out;
    }
    SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = out_wr;
    si.hStdError = out_wr;
    si.hStdInput = nullptr;
    PROCESS_INFORMATION pi{};
    std::vector<char> mutable_cmd(cmdline.begin(), cmdline.end());
    mutable_cmd.push_back('\0');
    HANDLE job = CreateJobObjectA(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(
                job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) {
            CloseHandle(job);
            job = nullptr;
        }
    }
    if (!CreateProcessA(
            shell.c_str(),
            mutable_cmd.data(),
            nullptr,
            nullptr,
            TRUE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED,
            nullptr,
            root.c_str(),
            &si,
            &pi)) {
        CloseHandle(out_rd);
        CloseHandle(out_wr);
        if (job) CloseHandle(job);
        out.detail = "CreateProcess failed";
        return out;
    }
    CloseHandle(out_wr);
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        CloseHandle(out_rd);
        CloseHandle(job);
        out.detail = "Job Object assign failed";
        return out;
    }
    ResumeThread(pi.hThread);
    out.ran = true;
    std::string captured;
    char buf[4096];
    const DWORD deadline = GetTickCount() + 70000;
    bool timed_out = false;
    for (;;) {
        DWORD avail = 0;
        if (PeekNamedPipe(out_rd, nullptr, 0, nullptr, &avail, nullptr) &&
            avail > 0 && captured.size() < 65536) {
            DWORD read = 0;
            const DWORD want = static_cast<DWORD>(
                (std::min)(sizeof(buf), static_cast<size_t>(avail)));
            if (ReadFile(out_rd, buf, want, &read, nullptr) && read > 0) {
                captured.append(buf, read);
            }
        }
        const DWORD left = deadline - GetTickCount();
        if (static_cast<int>(left) <= 0) {
            timed_out = true;
            break;
        }
        const DWORD slice = left > 100 ? 100 : left;
        if (WaitForSingleObject(pi.hProcess, slice) == WAIT_OBJECT_0) break;
    }
    if (timed_out) {
        if (job) TerminateJobObject(job, 1);
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
        out.ok = false;
        out.detail = "check timed out";
    }
    DWORD read = 0;
    while (captured.size() < 65536 &&
           ReadFile(out_rd, buf, sizeof(buf), &read, nullptr) && read > 0) {
        captured.append(buf, read);
    }
    if (!timed_out) {
        DWORD code = 1;
        GetExitCodeProcess(pi.hProcess, &code);
        json parsed;
        try {
            std::string line = captured;
            const auto brace = captured.rfind('{');
            if (brace != std::string::npos) line = captured.substr(brace);
            parsed = json::parse(line);
            out.ok = parsed.value("ok", false) && code == 0;
            const std::string got = parsed.value("profile", out.profile);
            if (!got.empty()) out.profile = got;
            out.detail = parsed.value("detail", captured);
        } catch (const json::exception&) {
            out.ok = false;
            out.detail = captured.empty() ? "check produced no JSON" : captured;
        }
        if (code != 0) out.ok = false;
    }
    CloseHandle(out_rd);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    if (out.detail.size() > 400) out.detail.resize(400);
    return out;
}

bool path_ok(const std::string& rel) {
    if (rel.empty() || rel.size() > 240) return false;
    if (rel.find("..") != std::string::npos) return false;
    if (rel.size() >= 2 && rel[1] == ':') return false;
    const std::string lower = ascii_lower(rel);
    if (lower.rfind(".git\\", 0) == 0 || lower.find("\\.git\\") != std::string::npos) {
        return false;
    }
    static const char* denied[] = {
        "build\\", "target\\", "out\\", "cache\\", "node_modules\\",
        "llm\\", "archive\\", "godbrain_core\\smart_contracts\\lib\\",
    };
    for (const char* d : denied) {
        if (lower.rfind(d, 0) == 0 || lower.find(std::string("\\") + d) != std::string::npos) {
            return false;
        }
    }
    const bool root_file = lower.find('\\') == std::string::npos;
    if (root_file) {
        return ends_with(lower, ".ps1") || ends_with(lower, ".cmd") ||
               ends_with(lower, ".md");
    }
    if (lower.rfind("scripts\\", 0) == 0) {
        return ends_with(lower, ".ps1") &&
               lower.find('\\', 8) == std::string::npos;
    }
    if (lower.rfind("docs\\", 0) == 0) {
        return ends_with(lower, ".md");
    }
    return lower.rfind("godbrain_core\\", 0) == 0;
}

bool read_all(const std::string& path, std::string& body) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream out;
    out << in.rdbuf();
    if (!in && !in.eof()) return false;
    body = out.str();
    return true;
}

bool write_all(const std::string& path, const std::string& body) {
    const std::string tmp = path + ".edit.tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out << body;
        if (!out) return false;
    }
    return MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
}

std::string strip_cr(std::string text) {
    std::string out;
    out.reserve(text.size());
    for (char ch : text) {
        if (ch != '\r') out.push_back(ch);
    }
    return out;
}

std::string to_crlf(const std::string& text) {
    const std::string lf = strip_cr(text);
    std::string out;
    out.reserve(lf.size() + 8);
    for (char ch : lf) {
        if (ch == '\n') out += "\r\n";
        else out.push_back(ch);
    }
    return out;
}

void match_file_newlines(std::string& old_text, std::string& new_text,
                         const std::string& body) {
    if (body.find("\r\n") != std::string::npos) {
        old_text = to_crlf(old_text);
        new_text = to_crlf(new_text);
    } else {
        old_text = strip_cr(old_text);
        new_text = strip_cr(new_text);
    }
}

struct Hunk {
    std::string path;
    std::string old_text;
    std::string new_text;
};

size_t find_marker(const std::string& text, size_t from,
                     const char* spaced, const char* tight) {
    const size_t a = text.find(spaced, from);
    const size_t b = text.find(tight, from);
    if (a == std::string::npos) return b;
    if (b == std::string::npos) return a;
    return a < b ? a : b;
}

std::string trim_path_token(std::string path) {
    while (!path.empty() && (path.front() == '`' || path.front() == '"' ||
                             path.front() == '\'' || path.front() == ' ' ||
                             path.front() == '\t')) {
        path.erase(path.begin());
    }
    while (!path.empty() && (path.back() == '`' || path.back() == '"' ||
                             path.back() == '\'' || path.back() == ' ' ||
                             path.back() == '\t' || path.back() == '\r')) {
        path.pop_back();
    }
    return replace_slashes(path);
}

std::vector<Hunk> parse_apply_blocks(const std::string& text) {
    std::vector<Hunk> hunks;
    size_t pos = 0;
    while (hunks.size() < 6) {
        const size_t start = find_marker(text, pos, "*** APPLY", "***APPLY");
        if (start == std::string::npos) break;
        size_t stop = find_marker(text, start, "*** END", "***END");
        if (stop == std::string::npos) {
            // Mouth often drops *** END. Inner markers are the hunk.
            const size_t gt = text.find(">>>>", start);
            if (gt == std::string::npos) break;
            stop = gt + 4;
        }
        const std::string block = text.substr(start, stop - start);
        Hunk hunk;
        const size_t path_at = block.find("path:");
        if (path_at == std::string::npos) {
            pos = stop + 6;
            continue;
        }
        size_t path_line = path_at + 5;
        while (path_line < block.size() &&
               (block[path_line] == ' ' || block[path_line] == '\t')) {
            ++path_line;
        }
        size_t path_end = block.find_first_of("\r\n", path_line);
        if (path_end == std::string::npos) path_end = block.size();
        hunk.path = trim_path_token(block.substr(path_line, path_end - path_line));
        const size_t old_at = block.find("<<<<");
        const size_t mid_at = block.find("====", old_at == std::string::npos ? 0 : old_at);
        const size_t new_at = block.find(">>>>", mid_at == std::string::npos ? 0 : mid_at);
        if (old_at == std::string::npos || mid_at == std::string::npos ||
            new_at == std::string::npos) {
            pos = stop + 6;
            continue;
        }
        hunk.old_text = block.substr(old_at + 4, mid_at - (old_at + 4));
        hunk.new_text = block.substr(mid_at + 4, new_at - (mid_at + 4));
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\r') hunk.old_text.erase(0, 1);
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\n') hunk.old_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\r') hunk.new_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\n') hunk.new_text.erase(0, 1);
        if (!hunk.path.empty()) hunks.push_back(hunk);
        pos = stop + 6;
    }
    return hunks;
}

std::mutex g_plan_mu;
std::string g_plan;

void save_plan(const std::string& user_msg, const std::string& first_answer) {
    const size_t apply = first_answer.rfind("*** APPLY");
    if (apply != std::string::npos) {
        g_plan = first_answer.substr(apply);
    } else {
        g_plan = first_answer;
    }
    if (g_plan.size() > 8000) g_plan.resize(8000);
    const std::string path = repo_root() + "\\logs\\last-edit-plan.txt";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << "USER\n" << user_msg << "\n\nPLAN\n" << g_plan << "\n";
}

void append_plan_section(const std::string& title, const std::string& body) {
    const std::string path = repo_root() + "\\logs\\last-edit-plan.txt";
    std::ofstream out(path, std::ios::binary | std::ios::app);
    if (!out) return;
    out << "\n" << title << "\n" << body << "\n";
}

void save_result(
    bool applied,
    bool rolled_back,
    const std::string& report,
    const CheckOutcome& check,
    const Result& extra) {
    const std::string path = repo_root() + "\\logs\\last-edit-result.json";
    const std::string profile =
        check.profile.empty() ? "local-edit-apply-v1" : check.profile;
    std::ostringstream payload;
    payload << "{\"applied\":" << (applied ? "true" : "false")
            << ",\"rolled_back\":" << (rolled_back ? "true" : "false")
            << ",\"verification_profile\":\"local-edit-apply-v1\""
            << ",\"check_profile\":\"" << json_escape(profile) << "\""
            << ",\"check_ran\":" << (check.ran ? "true" : "false")
            << ",\"check_ok\":" << (check.ok ? "true" : "false")
            << ",\"skill_promote_eligible\":false"
            << ",\"before_hash\":\"" << json_escape(extra.before_hash) << "\""
            << ",\"after_hash\":\"" << json_escape(extra.after_hash) << "\""
            << ",\"preview_path\":\"" << json_escape(extra.preview_path) << "\""
            << ",\"preview_old\":\"" << json_escape(clip_preview(extra.preview_old, 240)) << "\""
            << ",\"preview_new\":\"" << json_escape(clip_preview(extra.preview_new, 240)) << "\""
            << ",\"report\":\"" << json_escape(report) << "\""
            << ",\"check_detail\":\"" << json_escape(check.detail) << "\"}\n";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << payload.str();
}

bool looks_rel_path(const std::string& path) {
    if (!path_ok(path)) return false;
    const std::string lower = ascii_lower(path);
    return ends_with(lower, ".ps1") || ends_with(lower, ".cpp") ||
           ends_with(lower, ".h") || ends_with(lower, ".go") ||
           ends_with(lower, ".html") || ends_with(lower, ".md") ||
           ends_with(lower, ".cmd") || ends_with(lower, ".txt");
}

std::string take_path_token(const std::string& text, size_t from) {
    size_t i = from;
    while (i < text.size() &&
           (text[i] == ' ' || text[i] == '\t' || text[i] == '`' ||
            text[i] == '"' || text[i] == '\'')) {
        ++i;
    }
    size_t j = i;
    while (j < text.size()) {
        const unsigned char ch = static_cast<unsigned char>(text[j]);
        if (ch <= 32 || ch == '`' || ch == '"' || ch == '\'' || ch == '<' ||
            ch == '*' || ch == ',') {
            break;
        }
        ++j;
    }
    return trim_path_token(text.substr(i, j - i));
}

std::string guess_file(const std::string& text) {
    const std::string lower = ascii_lower(text);
    const size_t path_at = lower.find("path:");
    if (path_at != std::string::npos) {
        const std::string p = take_path_token(text, path_at + 5);
        if (looks_rel_path(p)) return replace_slashes(p);
    }
    const size_t edit_at = lower.find("/edit");
    if (edit_at != std::string::npos) {
        const std::string p = take_path_token(text, edit_at + 5);
        if (looks_rel_path(p)) return replace_slashes(p);
    }
    static const char* prefixes[] = {
        "godbrain_core/", "godbrain_core\\", "scripts/", "scripts\\",
        "docs/", "docs\\",
    };
    for (const char* prefix : prefixes) {
        const size_t at = lower.find(prefix);
        if (at == std::string::npos) continue;
        const std::string p = take_path_token(text, at);
        if (looks_rel_path(p)) return replace_slashes(p);
    }
    if (lower.find("galaxy.html") != std::string::npos) {
        return "godbrain_core\\frontend\\galaxy.html";
    }
    static const char* names[] = {
        "start-llamaserver.ps1", "start-godbrain.ps1", "heal-godbrain.ps1",
        "watch-godbrain.ps1", "watch-cs2pause.ps1", "godbrain-cs2.ps1",
        "start-cs2.ps1", "main.cpp", "coli_sse.h", "memory.cpp",
    };
    for (const char* name : names) {
        if (lower.find(name) != std::string::npos) {
            if (std::string(name) == "start-llamaserver.ps1") return "scripts\\Start-LlamaServer.ps1";
            if (std::string(name) == "start-godbrain.ps1") return "Start-GodBrain.ps1";
            if (std::string(name) == "heal-godbrain.ps1") return "Heal-GodBrain.ps1";
            if (std::string(name) == "watch-godbrain.ps1") return "Watch-GodBrain.ps1";
            if (std::string(name) == "watch-cs2pause.ps1") return "Watch-Cs2Pause.ps1";
            if (std::string(name) == "godbrain-cs2.ps1") return "GodBrain-Cs2.ps1";
            if (std::string(name) == "start-cs2.ps1") return "Start-CS2.ps1";
            if (std::string(name) == "main.cpp") return "godbrain_core\\cpp_kernel\\main.cpp";
            if (std::string(name) == "coli_sse.h") return "godbrain_core\\cpp_kernel\\coli_sse.h";
            if (std::string(name) == "memory.cpp") return "godbrain_core\\cpp_kernel\\memory.cpp";
        }
    }
    return "";
}

size_t excerpt_at(const std::string& body, const std::string& rel,
                  const std::string& hint) {
    size_t at = std::string::npos;
    size_t best = 7;
    auto consider = [&](const std::string& s) {
        if (s.size() <= best) return;
        const size_t found = body.find(s);
        if (found == std::string::npos) return;
        best = s.size();
        at = found;
    };
    size_t line_start = 0;
    while (line_start < hint.size()) {
        size_t line_end = hint.find('\n', line_start);
        if (line_end == std::string::npos) line_end = hint.size();
        std::string line = hint.substr(line_start, line_end - line_start);
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t' ||
                                 line.front() == '\r')) {
            line.erase(line.begin());
        }
        consider(line);
        line_start = line_end + 1;
    }
    std::string token;
    for (size_t i = 0; i <= hint.size(); ++i) {
        const bool end = i == hint.size();
        const unsigned char ch = end ? ' ' : static_cast<unsigned char>(hint[i]);
        if (!end && ch > 32) {
            token.push_back(static_cast<char>(ch));
        } else {
            consider(token);
            token.clear();
        }
    }
    if (at == std::string::npos) {
        const std::string lower_hint = ascii_lower(hint);
        const std::string lower_rel = ascii_lower(rel);
        static const char* markers[] = {
            "Inbox: none", "Heal: none", "CS2: idle", "GPU: none",
            "Judge: none", "Edit: none", "host-card", "function paintStatus",
        };
        auto take_marker = [&](bool hint_only) {
            for (const char* marker : markers) {
                if (hint_only) {
                    if (lower_hint.find(ascii_lower(marker)) ==
                        std::string::npos) {
                        continue;
                    }
                } else if (lower_rel.find("galaxy.html") == std::string::npos) {
                    continue;
                }
                const size_t found = body.find(marker);
                if (found != std::string::npos) {
                    at = found;
                    return true;
                }
            }
            return false;
        };
        if (!take_marker(true)) take_marker(false);
    }
    if (at == std::string::npos) at = body.find("function paintStatus");
    if (at == std::string::npos) at = body.find("host-card");
    return at;
}

std::string excerpt(const std::string& rel, const std::string& hint = "") {
    const std::string full = repo_root() + "\\" + rel;
    std::string body;
    if (!read_all(full, body)) return "";
    const size_t at = excerpt_at(body, rel, hint);
    if (at == std::string::npos) {
        if (body.size() > 4000) {
            return body.substr(body.size() - 4000);
        }
        return body;
    }
    const size_t win = 800;
    const size_t start = at > win ? at - win : 0;
    size_t n = 2400;
    if (start + n > body.size()) n = body.size() - start;
    return body.substr(start, n);
}

struct ApplyOutcome {
    bool ok = false;
    std::string report;
    std::vector<std::string> edited;
    std::map<std::string, std::string> originals;
    std::string before_hash;
    std::string after_hash;
    std::string preview_path;
    std::string preview_old;
    std::string preview_new;
    bool wrote = false;
};

bool restore_originals(const std::map<std::string, std::string>& originals);

ApplyOutcome apply_hunks(const std::vector<Hunk>& hunks, const std::string& hint) {
    ApplyOutcome out;
    const std::string root = repo_root();
    if (root.empty()) {
        out.report = "FAIL: cannot resolve repo root";
        return out;
    }
    std::ostringstream report;
    int ok = 0;
    std::map<std::string, std::string> working;
    for (const Hunk& hunk : hunks) {
        if (!path_ok(hunk.path)) {
            report << "skip bad path " << hunk.path << "\n";
            continue;
        }
        const std::string full = root + "\\" + hunk.path;
        std::string body;
        if (working.count(hunk.path)) {
            body = working[hunk.path];
        } else if (!read_all(full, body)) {
            report << "skip missing " << hunk.path << "\n";
            continue;
        } else {
            out.originals[hunk.path] = body;
            if (out.preview_path.empty()) {
                out.before_hash = content_hash(body);
            }
        }
        if (out.preview_path.empty()) {
            out.preview_path = hunk.path;
            out.preview_old = hunk.old_text;
            out.preview_new = hunk.new_text;
        }
        std::string old_text = hunk.old_text;
        std::string new_text = hunk.new_text;
        match_file_newlines(old_text, new_text, body);
        if (body.empty() && old_text.empty()) {
            working[hunk.path] = new_text;
            ++ok;
            if (std::find(out.edited.begin(), out.edited.end(), hunk.path) ==
                out.edited.end()) {
                out.edited.push_back(hunk.path);
            }
            report << "edited " << hunk.path << "\n";
            continue;
        }
        const size_t at = body.find(old_text);
        if (at == std::string::npos) {
            report << "skip no match " << hunk.path << "\n";
            continue;
        }
        if (body.find(old_text, at + 1) != std::string::npos) {
            report << "skip ambiguous " << hunk.path << "\n";
            continue;
        }
        const std::string bound = excerpt(hunk.path, hint);
        if (!bound.empty() &&
            strip_cr(bound).find(strip_cr(old_text)) == std::string::npos) {
            report << "skip old not in excerpt " << hunk.path << "\n";
            continue;
        }
        body.replace(at, old_text.size(), new_text);
        working[hunk.path] = body;
        ++ok;
        if (std::find(out.edited.begin(), out.edited.end(), hunk.path) ==
            out.edited.end()) {
            out.edited.push_back(hunk.path);
        }
        report << "edited " << hunk.path << "\n";
    }
    if (ok == 0) {
        out.report = "FAIL\n" + report.str();
        return out;
    }
    for (const auto& kv : working) {
        const std::string full = root + "\\" + kv.first;
        if (!write_all(full, kv.second)) {
            restore_originals(out.originals);
            DeleteFileA((full + ".edit.tmp").c_str());
            out.report = "FAIL\nwrite failed " + kv.first + "\n" + report.str();
            out.ok = false;
            return out;
        }
        out.wrote = true;
    }
    if (!out.preview_path.empty() && working.count(out.preview_path)) {
        out.after_hash = content_hash(working[out.preview_path]);
    }
    out.ok = true;
    out.report = "DONE\n" + report.str();
    return out;
}

bool restore_originals(const std::map<std::string, std::string>& originals) {
    const std::string root = repo_root();
    if (root.empty()) return false;
    bool ok = true;
    for (const auto& kv : originals) {
        const std::string full = root + "\\" + kv.first;
        if (!write_all(full, kv.second)) ok = false;
    }
    return ok;
}

}  // namespace

std::string check_profile_for(const std::string& rel) {
    return check_profile_for_impl(rel);
}

bool apply_still_open(const std::string& text) {
    const size_t apply_sp = text.rfind("*** APPLY");
    const size_t apply_t = text.rfind("***APPLY");
    size_t apply = std::string::npos;
    if (apply_sp == std::string::npos) {
        apply = apply_t;
    } else if (apply_t == std::string::npos) {
        apply = apply_sp;
    } else {
        apply = apply_sp > apply_t ? apply_sp : apply_t;
    }
    if (apply == std::string::npos) return false;
    const size_t gt = text.rfind(">>>>");
    return gt == std::string::npos || apply > gt;
}

std::string edit_user_with_excerpt(const std::string& user_msg) {
    std::ostringstream usr;
    usr << user_msg << "\n\n";
    const std::string file = guess_file(user_msg);
    if (!file.empty()) {
        usr << "File " << file << " excerpt:\n" << excerpt(file, user_msg)
            << "\n\n";
    }
    usr << "This message is the operator, not RAG. "
           "Copy old text from the excerpt only. Do not patch a different "
           "occurrence. Emit ONLY apply blocks:\n"
           "*** APPLY\n"
           "path: relative/from/repo\n"
           "<<<<\n"
           "exact old text\n"
           "====\n"
           "exact new text\n"
           ">>>>\n"
           "*** END\n";
    return usr.str();
}

bool looks_like_edit_request(const std::string& user_msg) {
    const std::string lower = ascii_lower(user_msg);
    if (lower.rfind("/edit", 0) == 0) return true;
    const bool named =
        lower.find(".ps1") != std::string::npos ||
        lower.find(".cpp") != std::string::npos ||
        lower.find(".h") != std::string::npos ||
        lower.find(".go") != std::string::npos ||
        lower.find(".html") != std::string::npos ||
        lower.find(".md") != std::string::npos;
    if (!named) return false;
    return lower.find("edit") != std::string::npos ||
           lower.find("add") != std::string::npos ||
           lower.find("change") != std::string::npos ||
           lower.find("fix") != std::string::npos ||
           lower.find("guard") != std::string::npos ||
           lower.find("patch") != std::string::npos ||
           lower.find("write") != std::string::npos ||
           lower.find("do not launch") != std::string::npos;
}

Result maybe_apply(
    const std::string& user_msg,
    const std::string& first_answer,
    const std::function<std::string(const std::string&, const std::string&)>& generate) {
    Result result;
    if (!looks_like_edit_request(user_msg)) return result;
    std::lock_guard<std::mutex> lock(g_plan_mu);
    result.attempted = true;
    save_plan(user_msg, first_answer);

    std::vector<Hunk> hunks = parse_apply_blocks(first_answer);
    if (hunks.empty()) hunks = parse_apply_blocks(user_msg);

    ApplyOutcome applied;
    if (!hunks.empty()) applied = apply_hunks(hunks, user_msg);
    if (!applied.ok && generate && !applied.wrote) {
        std::ostringstream usr;
        usr << "First pass did not apply. "
            << local_edit::edit_user_with_excerpt(user_msg);
        const std::string sys =
            "You are a local file editor. Output apply blocks only. "
            "No git. No push. No extra files. Copy old text from the excerpt.";
        const std::string second = generate(sys, usr.str());
        append_plan_section("SECOND", second.empty() ? "(empty)" : second);
        hunks = parse_apply_blocks(second);
        if (hunks.empty()) {
            if (applied.report.empty()) {
                result.report =
                    "Plan saved. Second pass had no apply blocks. "
                    "Ask again with /edit and a file name.";
            } else {
                result.report = applied.report;
                if (result.report.back() != '\n') result.report += '\n';
                result.report += "Second pass had no apply blocks.\n";
            }
            save_result(false, false, result.report, CheckOutcome{}, result);
            return result;
        }
        applied = apply_hunks(hunks, user_msg);
    } else if (!applied.ok && hunks.empty()) {
        result.report = "Plan saved. No apply blocks and no second pass.";
        save_result(false, false, result.report, CheckOutcome{}, result);
        return result;
    }
    result.report = applied.report;
    result.applied = applied.ok;
    result.before_hash = applied.before_hash;
    result.after_hash = applied.after_hash;
    result.preview_path = applied.preview_path;
    result.preview_old = applied.preview_old;
    result.preview_new = applied.preview_new;
    CheckOutcome check;
    if (applied.ok) {
        check = run_edit_check(applied.edited);
        result.check_ran = check.ran;
        result.check_ok = check.ok;
        result.check_profile = check.profile;
        if (!check.detail.empty()) {
            result.report += "check " + check.profile + "=" +
                             (check.ok ? "ok" : "fail") + " " + check.detail +
                             "\n";
        }
        if (check.ran && !check.ok) {
            if (restore_originals(applied.originals)) {
                result.applied = false;
                result.rolled_back = true;
                result.after_hash = result.before_hash;
                result.report += "rolled back (check failed)\n";
            } else {
                result.report += "rollback write failed\n";
            }
        }
    } else {
        check.profile = "local-edit-apply-v1";
    }
    if (!result.before_hash.empty()) {
        result.report += "hash " + result.before_hash.substr(0, 12);
        if (!result.after_hash.empty()) {
            result.report += " -> " + result.after_hash.substr(0, 12);
        }
        result.report += "\n";
    }
    save_result(result.applied, result.rolled_back, result.report, check, result);
    return result;
}

Preview preview_apply_blocks(const std::string& text) {
    Preview out;
    const auto hunks = parse_apply_blocks(text);
    out.count = static_cast<int>(hunks.size());
    if (!hunks.empty()) {
        out.first_path = hunks[0].path;
        out.first_old = hunks[0].old_text;
        out.first_new = hunks[0].new_text;
        const std::string full = repo_root() + "\\" + hunks[0].path;
        std::string body;
        if (read_all(full, body)) out.first_hash = content_hash(body);
    }
    return out;
}

}  // namespace local_edit
