#include "local_tools.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable : 4127)
#endif
#include "json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

namespace local_tools {
namespace {

using json = nlohmann::json;

constexpr size_t kMaxReadBytes = 256 * 1024;
constexpr size_t kMaxWriteBytes = 2 * 1024 * 1024;
constexpr size_t kMaxListEntries = 500;
constexpr size_t kMaxPwshBytes = 64 * 1024;
constexpr DWORD kToolTimeoutMs = 30000;
constexpr DWORD kPwshTimeoutMs = 60000;

const char kSysintDir[] = "C:\\Tools\\SysInternals";
const char kMinSudo[] = "C:\\Tools\\TeamM2\\MinSudo.exe";
const char kWsudo[] = "C:\\Tools\\TeamM2\\wsudo.exe";

std::string ascii_lower(std::string value) {
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string trim(std::string value) {
    size_t b = 0;
    while (b < value.size() &&
           std::isspace(static_cast<unsigned char>(value[b]))) {
        ++b;
    }
    size_t e = value.size();
    while (e > b && std::isspace(static_cast<unsigned char>(value[e - 1]))) {
        --e;
    }
    return value.substr(b, e - b);
}

bool contains_ci(const std::string& hay, const std::string& needle) {
    return ascii_lower(hay).find(ascii_lower(needle)) != std::string::npos;
}

std::string first_word(const std::string& value) {
    const std::string t = trim(value);
    size_t i = 0;
    while (i < t.size() && !std::isspace(static_cast<unsigned char>(t[i]))) {
        ++i;
    }
    return ascii_lower(t.substr(0, i));
}

bool args_have_newline(const std::string& args) {
    return args.find('\n') != std::string::npos ||
           args.find('\r') != std::string::npos;
}

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
    if (GetFullPathNameA(dir.c_str(), MAX_PATH, canon, nullptr) == 0) {
        return "";
    }
    return std::string(canon);
}

std::string logs_dir() {
    return repo_root() + "\\logs";
}

std::string yolo_path() {
    return logs_dir() + "\\tool-yolo.json";
}

std::string canon_path(const std::string& path) {
    if (path.empty()) return "";
    char buf[MAX_PATH];
    if (GetFullPathNameA(path.c_str(), MAX_PATH, buf, nullptr) == 0) {
        return "";
    }
    return std::string(buf);
}

bool starts_with_ci(const std::string& value, const std::string& prefix) {
    if (value.size() < prefix.size()) return false;
    return ascii_lower(value.substr(0, prefix.size())) == ascii_lower(prefix);
}

bool file_exists(const std::string& path) {
    return GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

void close_handle(HANDLE& handle) {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        handle = nullptr;
    }
}

std::string read_file_limited(const std::string& path, size_t cap, bool* truncated) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return "";
    std::string data;
    data.resize(cap + 1);
    DWORD got = 0;
    const BOOL ok = ReadFile(h, &data[0], static_cast<DWORD>(cap + 1), &got, nullptr);
    CloseHandle(h);
    if (!ok) return "";
    if (truncated) *truncated = got > cap;
    if (got > cap) data.resize(cap);
    else data.resize(got);
    return data;
}

bool looks_binary(const std::string& data) {
    const size_t n = (std::min)(data.size(), static_cast<size_t>(512));
    for (size_t i = 0; i < n; ++i) {
        if (data[i] == '\0') return true;
    }
    return false;
}

std::string run_process(const std::string& exe, const std::string& args,
                        DWORD timeout_ms) {
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE out_rd = nullptr;
    HANDLE out_wr = nullptr;
    if (!CreatePipe(&out_rd, &out_wr, &sa, 0)) {
        return "Error: pipe failed.";
    }
    SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.hStdOutput = out_wr;
    si.hStdError = out_wr;
    si.dwFlags |= STARTF_USESTDHANDLES;

    std::string cmd = "\"" + exe + "\"";
    if (!args.empty()) cmd += " " + args;
    std::vector<char> buf(cmd.begin(), cmd.end());
    buf.push_back('\0');

    PROCESS_INFORMATION pi{};
    HANDLE job = CreateJobObjectA(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(
                job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) {
            close_handle(job);
        }
    }

    const BOOL started = CreateProcessA(
        exe.c_str(), buf.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &si, &pi);
    close_handle(out_wr);
    if (!started) {
        close_handle(out_rd);
        close_handle(job);
        return "Error: CreateProcess failed for " + exe;
    }
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 4000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        close_handle(out_rd);
        close_handle(job);
        return "Error: Job Object assign failed.";
    }
    ResumeThread(pi.hThread);

    std::mutex mu;
    std::string out;
    bool truncated = false;
    std::thread reader([&]() {
        char tmp[4096];
        DWORD read = 0;
        while (ReadFile(out_rd, tmp, sizeof(tmp), &read, nullptr) && read > 0) {
            std::lock_guard<std::mutex> lock(mu);
            if (out.size() >= kMaxReadBytes) {
                truncated = true;
                continue;
            }
            const size_t room = kMaxReadBytes - out.size();
            const size_t take = (std::min)(room, static_cast<size_t>(read));
            out.append(tmp, take);
        }
    });

    const DWORD wait = WaitForSingleObject(pi.hProcess, timeout_ms);
    if (wait == WAIT_TIMEOUT) {
        if (job) TerminateJobObject(job, 1);
        TerminateProcess(pi.hProcess, 1);
        std::lock_guard<std::mutex> lock(mu);
        out += "\n[timeout]";
    }
    if (reader.joinable()) reader.join();
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    close_handle(out_rd);
    close_handle(job);
    if (truncated) out += "\n[truncated 256KiB]";
    return out.empty() ? "(no output)" : out;
}

std::string find_on_path(const char* name) {
    char buf[MAX_PATH];
    DWORD n = SearchPathA(nullptr, name, ".exe", MAX_PATH, buf, nullptr);
    if (n > 0 && n < MAX_PATH) return std::string(buf);
    return "";
}

std::string find_exe(const char* name) {
    std::string found = find_on_path(name);
    if (!found.empty()) return found;
    const char* extra[] = {
        "C:\\Tools\\SysInternals\\strings64.exe",
        "C:\\Tools\\SysInternals\\strings.exe",
        nullptr};
    for (int i = 0; extra[i]; ++i) {
        if (file_exists(extra[i]) &&
            ascii_lower(extra[i]).find(ascii_lower(name)) != std::string::npos) {
            return extra[i];
        }
    }
    return "";
}

std::string strip_exe(std::string stem) {
    stem = ascii_lower(trim(stem));
    const size_t slash = stem.find_last_of("\\/");
    if (slash != std::string::npos) stem = stem.substr(slash + 1);
    if (stem.size() > 4 && stem.substr(stem.size() - 4) == ".exe") {
        stem.resize(stem.size() - 4);
    }
    return stem;
}

std::string sysint_base(std::string stem) {
    stem = strip_exe(stem);
    if (stem.size() > 2 && stem.substr(stem.size() - 2) == "64") {
        stem.resize(stem.size() - 2);
    }
    return stem;
}

bool sysint_banned(const std::string& base) {
    static const char* kBan[] = {
        "pskill", "psexec", "psshutdown", "pssuspend", "pspasswd",
        "notmyfault", "notmyfaultc", "sysmon", "livekd",
        "sdelete", "movefile", "volumeid", "ctrl2cap", "autologon",
        "contig", "cacheset", "cpustres", "testlimit", "disk2vhd",
        "efsdump", "zoomit", "bginfo", "desktops", "rammap", "vmmap",
        "procexp", "procmon", "tcpview", "diskmon", "diskview", "winobj",
        "accessenum", "shareenum", "adexplorer", "adinsight", "portmon",
        "rdcman", "shellrunas", "dbgview", "regdelnull", "adrestore",
        "loadord", "autoruns", nullptr};
    for (int i = 0; kBan[i]; ++i) {
        if (base == kBan[i]) return true;
    }
    return false;
}

bool host_tool(const std::string& stem) {
    static const char* kHost[] = {
        "tasklist", "whoami", "hostname", "where", "systeminfo",
        "netstat", "fltmc", "driverquery", "ipconfig", "sc", nullptr};
    for (int i = 0; kHost[i]; ++i) {
        if (stem == kHost[i]) return true;
    }
    return false;
}

bool sysint_allowed(const std::string& base) {
    static const char* kOk[] = {
        "accesschk", "autorunsc", "clockres", "coreinfo", "coreinfoex",
        "diskext", "du", "findlinks", "handle", "hex2dec", "junction",
        "listdlls", "loadordc", "logonsessions", "ntfsinfo", "pendmoves",
        "pipelist", "psfile", "psgetsid", "psinfo", "pslist", "psloggedon",
        "psloglist", "psping", "psservice", "ru", "sigcheck", "streams",
        "strings", "tcpvcon", "whois", nullptr};
    for (int i = 0; kOk[i]; ++i) {
        if (base == kOk[i]) return true;
    }
    return false;
}

std::string find_sysint(const std::string& name) {
    const std::string stem = strip_exe(name);
    if (stem.empty() || stem.find("..") != std::string::npos) return "";
    const std::string dir = std::string(kSysintDir) + "\\";
    const std::string cands[] = {
        dir + stem + ".exe",
        dir + stem + "64.exe",
        dir + sysint_base(stem) + "64.exe",
        dir + sysint_base(stem) + ".exe",
    };
    // Prefer the 64-bit console build when the caller omitted the suffix.
    if (stem.find("64") == std::string::npos) {
        const std::string p64 = dir + stem + "64.exe";
        if (file_exists(p64)) return p64;
    }
    for (const auto& p : cands) {
        if (file_exists(p)) return p;
    }
    return "";
}

bool yolo_required_msg(std::ostringstream& out, const std::string& name) {
    if (yolo_active()) return false;
    out << name << " denied: YOLO required (/yolo N). Mutate/elevate/inline-pwsh "
                   "are timed, not permanent. MFIT/kill/--ti still GO.\n";
    return true;
}

bool dangerous_script(const std::string& text) {
    static const char* kBad[] = {
        "git push", "stop-computer", "restart-computer",
        "format-volume", "clear-disk", "initialize-disk",
        "bcdedit", "dism.exe", "dism /", "notmyfault",
        "pskill", "psexec", "psshutdown", "pssuspend", "pspasswd",
        "shutdown.exe", "shutdown /", "disable-computerrestore",
        "remove-windowsfeature", "mongosh", "mongodb://", "pymongo",
        nullptr};
    const std::string low = ascii_lower(text);
    for (int i = 0; kBad[i]; ++i) {
        if (low.find(kBad[i]) != std::string::npos) return true;
    }
    return false;
}

bool elevate_flags_denied(const std::string& text) {
    const std::string low = ascii_lower(text);
    return low.find("--ti") != std::string::npos ||
           low.find("-ti ") != std::string::npos ||
           low.find("trustedinstaller") != std::string::npos ||
           low.find("--system") != std::string::npos;
}

bool mentions_godbrain_task(const std::string& args) {
    return contains_ci(args, "godbrain");
}

bool protected_service(const std::string& args) {
    static const char* kSvc[] = {
        "bfe", "mpssvc", "mpsdrv", "dnscache", "winmgmt", "mongodb",
        "eventlog", "rpcss", "plugplay", "dcomlaunch", "samss", nullptr};
    const std::string low = ascii_lower(args);
    for (int i = 0; kSvc[i]; ++i) {
        if (low.find(kSvc[i]) != std::string::npos) return true;
    }
    return false;
}

bool schtasks_mutates(const std::string& word) {
    return word == "/create" || word == "/change" || word == "/delete" ||
           word == "/run" || word == "/end" || word == "/disable" ||
           word == "/enable" || word == "create" || word == "change" ||
           word == "delete" || word == "run" || word == "end" ||
           word == "disable" || word == "enable";
}

bool schtasks_destroys(const std::string& word) {
    return word == "/delete" || word == "/change" || word == "/end" ||
           word == "/disable" || word == "delete" || word == "change" ||
           word == "end" || word == "disable";
}

std::string system32(const char* name) {
    char buf[MAX_PATH];
    UINT n = GetSystemDirectoryA(buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return std::string("C:\\Windows\\System32\\") + name;
    return std::string(buf) + "\\" + name;
}

std::string quote_path(const std::string& path) {
    return "\"" + path + "\"";
}

std::string with_accepteula(const std::string& args) {
    if (contains_ci(args, "-accepteula") || contains_ci(args, "/accepteula")) {
        return args;
    }
    if (args.empty()) return "-accepteula";
    return "-accepteula " + args;
}

bool skip_noise_dir(const std::string& name) {
    const std::string n = ascii_lower(name);
    return n == ".git" || n == "node_modules" || n == "__pycache__" ||
           n == ".venv" || n == "venv" || n == "appdata";
}

int arg_int(const std::string& args, const char* key, int defval) {
    const std::string low = ascii_lower(args);
    std::string pat = std::string(key) + "=";
    size_t p = low.find(ascii_lower(pat));
    if (p == std::string::npos) {
        pat = std::string(key) + ":";
        p = low.find(ascii_lower(pat));
    }
    if (p == std::string::npos) return defval;
    p += pat.size();
    while (p < args.size() &&
           std::isspace(static_cast<unsigned char>(args[p]))) {
        ++p;
    }
    try {
        return std::stoi(args.substr(p));
    } catch (...) {
        return defval;
    }
}

void ensure_dir(const std::string& dir) {
    std::string acc;
    for (size_t i = 0; i < dir.size(); ++i) {
        acc.push_back(dir[i]);
        if (dir[i] == '\\' || i + 1 == dir.size()) {
            std::string d = acc;
            while (!d.empty() && d.back() == '\\') d.pop_back();
            if (d.size() > 3) CreateDirectoryA(d.c_str(), nullptr);
        }
    }
}

std::string slice_lines(const std::string& data, int offset, int limit) {
    std::vector<std::string> lines;
    std::string cur;
    for (size_t i = 0; i < data.size(); ++i) {
        const char ch = data[i];
        if (ch == '\n') {
            if (!cur.empty() && cur.back() == '\r') cur.pop_back();
            lines.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(ch);
        }
    }
    if (!cur.empty() || lines.empty()) {
        if (!cur.empty() && cur.back() == '\r') cur.pop_back();
        lines.push_back(cur);
    }
    if (lines.size() > 1 && lines.back().empty()) lines.pop_back();
    const int n = static_cast<int>(lines.size());
    int start = 0;
    int take = n;
    if (offset < 0) {
        take = -offset;
        if (take > n) take = n;
        start = n - take;
    } else {
        start = offset;
        take = n - start;
        if (take < 0) take = 0;
    }
    if (limit > 0 && take > limit) take = limit;
    if (start < 0) start = 0;
    if (start >= n || take <= 0) {
        return (offset < 0 && !data.empty()) ? data : "";
    }
    std::ostringstream o;
    for (int k = 0; k < take; ++k) {
        o << lines[static_cast<size_t>(start + k)] << "\n";
    }
    return o.str();
}

void search_dir(const std::string& dir, const std::string& needle, int depth,
                int max_depth, bool content, size_t& seen, size_t& hits,
                std::ostringstream& out) {
    if (max_depth < 1) max_depth = 1;
    if (max_depth > 8) max_depth = 8;
    if (depth >= max_depth || hits >= 80 || seen >= 400) return;
    WIN32_FIND_DATAA fd{};
    const std::string glob = dir + "\\*";
    HANDLE h = FindFirstFileA(glob.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        const std::string name = fd.cFileName;
        if (name == "." || name == "..") continue;
        ++seen;
        const bool isdir =
            (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        const bool link =
            (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
        const std::string full = dir + "\\" + name;
        if (!content) {
            if (needle.empty() || contains_ci(name, needle)) {
                if (hits < 80) {
                    out << (isdir ? "d " : "f ") << full << "\n";
                    ++hits;
                }
            }
        } else if (!isdir && !link) {
            bool trunc = false;
            const std::string data = read_file_limited(full, 64 * 1024, &trunc);
            if (!looks_binary(data) && contains_ci(data, needle)) {
                if (hits < 80) {
                    out << "f " << full << "\n";
                    ++hits;
                }
            }
        }
        if (isdir && !link && !skip_noise_dir(name) && depth < max_depth &&
            seen < 400 && hits < 80) {
            search_dir(full, needle, depth + 1, max_depth, content, seen, hits,
                       out);
        }
    } while (FindNextFileA(h, &fd) && hits < 80 && seen < 400);
    FindClose(h);
}

void audit_append(const Call& c) {
    const std::string dir = logs_dir();
    CreateDirectoryA(dir.c_str(), nullptr);
    const std::string path = dir + "\\tool-audit.jsonl";
    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &fad)) {
        ULARGE_INTEGER sz;
        sz.LowPart = fad.nFileSizeLow;
        sz.HighPart = fad.nFileSizeHigh;
        if (sz.QuadPart > 10ull * 1024ull * 1024ull) {
            const std::string bak = path + ".1";
            DeleteFileA(bak.c_str());
            MoveFileA(path.c_str(), bak.c_str());
        }
    }
    const auto now = std::chrono::system_clock::to_time_t(
        std::chrono::system_clock::now());
    json j = {
        {"ts", static_cast<long long>(now)},
        {"name", c.name},
        {"path", c.path.substr(0, 240)},
        {"args", c.args.substr(0, 240)},
    };
    std::ofstream out(path, std::ios::binary | std::ios::app);
    if (out) out << j.dump() << "\n";
}

std::string write_temp_script(const std::string& body, const char* ext) {
    CreateDirectoryA("C:\\Temp\\GitHub", nullptr);
    const std::string path =
        std::string("C:\\Temp\\GitHub\\.godbrain-tool-last") + ext;
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return "";
    out.write(body.data(), static_cast<std::streamsize>(body.size()));
    return path;
}

std::string write_temp_ps1(const std::string& body) {
    return write_temp_script(body, ".ps1");
}

std::string find_rg() {
    std::string p = find_on_path("rg");
    if (!p.empty()) return p;
    const char* extra[] = {
        "C:\\Users\\autismo\\scoop\\shims\\rg.exe",
        "C:\\Users\\autismo\\AppData\\Local\\Programs\\Microsoft VS Code\\"
        "resources\\app\\node_modules\\@vscode\\ripgrep\\bin\\rg.exe",
        nullptr};
    for (int i = 0; extra[i]; ++i) {
        if (file_exists(extra[i])) return extra[i];
    }
    return "";
}

std::string find_python() {
    std::string p = find_on_path("python");
    if (!p.empty()) return p;
    p = find_on_path("py");
    if (!p.empty()) return p;
    if (file_exists("C:\\Program Files\\Python313\\python.exe")) {
        return "C:\\Program Files\\Python313\\python.exe";
    }
    return "";
}

std::string find_pwsh() {
    std::string p = find_on_path("pwsh");
    if (!p.empty()) return p;
    const char* cands[] = {
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe",
        nullptr};
    for (int i = 0; cands[i]; ++i) {
        if (file_exists(cands[i])) return cands[i];
    }
    return find_on_path("powershell");
}

std::string unknown_tool_msg(const std::string& name) {
    return "unknown tool " + name +
           " (list_local_dir read_local_file write_local_file create_local_dir "
           "move_local_file get_file_info search_local edit_local_file "
           "run_strings run_sqlite3 run_sysint run_reg run_wevtutil run_logman "
           "run_schtasks run_pwsh run_python run_node run_elevate run_host). "
           "Never pskill/kill_process/psexec/psshutdown/notmyfault/sysmon/MFIT/"
           "--ti/mongo. Heal never launches these.\n";
}

}  // namespace

std::vector<std::string> default_roots() {
    return {
        "C:\\Users\\autismo",
        "C:\\Temp\\GitHub",
    };
}

bool path_is_granted(const std::string& path, std::string* err) {
    const std::string full = canon_path(path);
    if (full.empty()) {
        if (err) *err = "cannot canonicalize path";
        return false;
    }
    for (const auto& root : default_roots()) {
        const std::string r = canon_path(root);
        if (r.empty()) continue;
        if (ascii_lower(full) == ascii_lower(r)) return true;
        const std::string prefix = r + "\\";
        if (starts_with_ci(full, prefix)) return true;
    }
    if (err) *err = "path not in granted roots (C:\\Users\\autismo or C:\\Temp\\GitHub)";
    return false;
}

bool yolo_active() {
    std::ifstream in(yolo_path());
    if (!in) return false;
    try {
        json j;
        in >> j;
        if (!j.contains("until")) return false;
        long long ts = 0;
        if (j["until"].is_number()) {
            ts = j["until"].get<long long>();
        } else if (j["until"].is_string()) {
            try {
                ts = std::stoll(j["until"].get<std::string>());
            } catch (...) {
                return false;
            }
        } else {
            return false;
        }
        const auto now = std::chrono::system_clock::to_time_t(
            std::chrono::system_clock::now());
        return ts > static_cast<long long>(now);
    } catch (...) {
        return false;
    }
}

std::string set_yolo_minutes(int minutes) {
    CreateDirectoryA(logs_dir().c_str(), nullptr);
    if (minutes <= 0) {
        DeleteFileA(yolo_path().c_str());
        return "YOLO off.";
    }
    const auto now = std::chrono::system_clock::to_time_t(
        std::chrono::system_clock::now());
    const long long until = static_cast<long long>(now) + minutes * 60LL;
    json j = {{"until", until}, {"minutes", minutes}};
    std::ofstream out(yolo_path(), std::ios::binary | std::ios::trunc);
    out << j.dump();
    return "YOLO on for " + std::to_string(minutes) +
           " min (elevate, reg/schtasks/etw mutate). FS and pwsh are already "
           "on. Not --ti, not kill, not MFIT, not GodBrain task delete. "
           "/yolo off to clear.";
}

std::string yolo_status_line() {
    if (!yolo_active()) return "YOLO off.";
    return "YOLO on.";
}

bool has_tool_block(const std::string& text) {
    return text.find("*** TOOL") != std::string::npos;
}

std::vector<Call> parse_tool_blocks(const std::string& text) {
    std::vector<Call> calls;
    size_t pos = 0;
    while ((pos = text.find("*** TOOL", pos)) != std::string::npos) {
        size_t end = text.find("*** END", pos + 8);
        std::string block;
        if (end == std::string::npos) {
            block = text.substr(pos + 8);
            pos = text.size();
        } else {
            block = text.substr(pos + 8, end - (pos + 8));
            pos = end + 7;
        }
        Call c;
        const size_t body_a = block.find("<<<<");
        const size_t body_b = block.find(">>>>");
        if (body_a != std::string::npos && body_b != std::string::npos &&
            body_b > body_a) {
            c.content = block.substr(body_a + 4, body_b - (body_a + 4));
            if (!c.content.empty() && c.content.front() == '\n') {
                c.content.erase(c.content.begin());
            }
            block = block.substr(0, body_a);
        }
        std::istringstream lines(block);
        std::string line;
        while (std::getline(lines, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            const std::string t = trim(line);
            const auto colon = t.find(':');
            if (colon == std::string::npos) continue;
            const std::string key = ascii_lower(trim(t.substr(0, colon)));
            const std::string val = trim(t.substr(colon + 1));
            if (key == "name") c.name = ascii_lower(val);
            else if (key == "path") c.path = val;
            else if (key == "sql") c.sql = val;
            else if (key == "exe") c.exe = val;
            else if (key == "args") c.args = val;
            else if (key == "old" || key == "old_text") c.old_text = val;
            else if (key == "dest") c.dest = val;
        }
        if (!c.name.empty()) calls.push_back(c);
    }
    return calls;
}

std::string execute_calls(const std::vector<Call>& calls) {
    std::ostringstream out;
    const size_t cap = yolo_active() ? 16u : 8u;
    size_t n = 0;
    for (const auto& raw : calls) {
        if (n >= cap) {
            out << "[capped at " << cap << " tools this round]\n";
            break;
        }
        ++n;
        Call c = raw;
        std::string err;

        if (c.name == "taskschd" || c.name == "task_scheduler") c.name = "run_schtasks";
        else if (c.name == "etw") c.name = "run_wevtutil";
        else if (c.name == "reg" || c.name == "regedit" || c.name == "reg.exe") {
            c.name = "run_reg";
        } else if (c.name == "pwsh" || c.name == "powershell") c.name = "run_pwsh";
        else if (c.name == "elevate" || c.name == "wsudo" || c.name == "minsudo") {
            c.name = "run_elevate";
        } else if (c.name == "wevtutil") c.name = "run_wevtutil";
        else if (c.name == "logman") c.name = "run_logman";
        else if (c.name == "schtasks") c.name = "run_schtasks";
        else if (c.name == "sysint") c.name = "run_sysint";
        else if (c.name == "start_search" || c.name == "search_files" ||
                 c.name == "list_directory") {
            if (c.name == "list_directory") c.name = "list_local_dir";
            else c.name = "search_local";
        } else if (c.name == "edit_block" || c.name == "edit_file") {
            c.name = "edit_local_file";
        } else if (c.name == "start_process" || c.name == "execute_command" ||
                   c.name == "run_terminal") {
            c.name = "run_pwsh";
        } else if (c.name == "read_file") c.name = "read_local_file";
        else if (c.name == "write_file") c.name = "write_local_file";
        else if (c.name == "create_directory" || c.name == "mkdir" ||
                 c.name == "ensure_local_dir") {
            c.name = "create_local_dir";
        } else if (c.name == "move_file") {
            c.name = "move_local_file";
        } else if (c.name == "get_metadata") {
            c.name = "get_file_info";
        } else if (c.name == "python") {
            c.name = "run_python";
        } else if (c.name == "node") {
            c.name = "run_node";
        } else if (c.name == "list_processes") {
            c.exe = "tasklist";
            c.name = "run_host";
        } else if (host_tool(strip_exe(c.name))) {
            if (c.exe.empty()) c.exe = strip_exe(c.name);
            c.name = "run_host";
        }
        audit_append(c);

        const std::string sys_stem = c.name == "run_sysint"
                                         ? sysint_base(c.exe.empty() ? c.path : c.exe)
                                         : sysint_base(c.name);
        const bool is_sysint = c.name == "run_sysint" || sysint_allowed(sys_stem) ||
                               sysint_banned(sys_stem);

        if (c.name == "kill_process" || c.name == "force_terminate") {
            out << "kill_process denied: never. Use tasklist; kill is operator GO.\n";
            continue;
        }
        if (c.name == "interact_with_process" ||
            c.name == "read_process_output") {
            out << "interact_with_process denied: no interactive sessions. "
                   "Use run_pwsh / run_python / run_node (60s Job).\n";
            continue;
        }

        if (c.name == "list_local_dir" || c.name == "read_local_file" ||
            c.name == "write_local_file" || c.name == "run_strings" ||
            c.name == "run_sqlite3" || c.name == "search_local" ||
            c.name == "edit_local_file" || c.name == "create_local_dir" ||
            c.name == "move_local_file" || c.name == "get_file_info") {
            if (!path_is_granted(c.path, &err)) {
                out << c.name << " denied: " << err << "\n";
                continue;
            }
            const std::string full = canon_path(c.path);
            if (c.name == "list_local_dir") {
                int depth = arg_int(c.args, "depth", 0);
                if (depth <= 0) {
                    try {
                        if (!trim(c.args).empty()) depth = std::stoi(trim(c.args));
                    } catch (...) {
                        depth = 1;
                    }
                }
                if (depth <= 0) depth = 1;
                size_t seen = 0;
                size_t hits = 0;
                out << "list_local_dir " << full << " depth=" << depth << "\n";
                search_dir(full, "", 0, depth, false, seen, hits, out);
                if (hits >= 80) out << "... truncated\n";
            } else if (c.name == "read_local_file") {
                bool trunc = false;
                const std::string data = read_file_limited(full, kMaxReadBytes, &trunc);
                if (looks_binary(data)) {
                    out << "read_local_file: binary (use run_strings or run_python) "
                        << full << "\n";
                } else {
                    const int offset = arg_int(c.args, "offset", 0);
                    const int limit = arg_int(c.args, "limit", 0);
                    out << "read_local_file " << full
                        << " bytes=" << data.size()
                        << (trunc ? " [truncated 256KiB]" : "")
                        << ((offset || limit) ? " sliced" : "") << "\n";
                    if (offset || limit) out << slice_lines(data, offset, limit);
                    else out << data << "\n";
                }
            } else if (c.name == "write_local_file") {
                if (c.content.size() > kMaxWriteBytes) {
                    out << "write_local_file: body too large\n";
                    continue;
                }
                const size_t slash = full.find_last_of("\\/");
                if (slash != std::string::npos) ensure_dir(full.substr(0, slash));
                const bool append = contains_ci(c.args, "append");
                std::ofstream outf(
                    full, std::ios::binary |
                              (append ? std::ios::app : std::ios::trunc));
                if (!outf) {
                    out << "write_local_file: cannot write " << full << "\n";
                    continue;
                }
                outf.write(c.content.data(),
                           static_cast<std::streamsize>(c.content.size()));
                out << "write_local_file ok bytes=" << c.content.size() << " "
                    << (append ? "append " : "") << full << "\n";
            } else if (c.name == "run_strings") {
                std::string exe = find_exe("strings64");
                if (exe.empty()) exe = find_exe("strings");
                if (exe.empty()) {
                    out << "run_strings: strings64.exe not found\n";
                    continue;
                }
                const std::string args = "-accepteula -n 6 " + quote_path(full);
                out << "run_strings " << full << "\n"
                    << run_process(exe, args, kToolTimeoutMs) << "\n";
            } else if (c.name == "run_sqlite3") {
                if (c.sql.empty()) {
                    out << "run_sqlite3: sql required\n";
                    continue;
                }
                const std::string sql_l = ascii_lower(c.sql);
                if (sql_l.find("attach") != std::string::npos ||
                    sql_l.find(".shell") != std::string::npos ||
                    sql_l.find("load_extension") != std::string::npos) {
                    out << "run_sqlite3: sql not allowed\n";
                    continue;
                }
                const std::string exe = find_exe("sqlite3");
                if (exe.empty()) {
                    out << "run_sqlite3: sqlite3.exe not found\n";
                    continue;
                }
                const std::string args =
                    "-readonly " + quote_path(full) + " " + quote_path(c.sql);
                out << "run_sqlite3 " << full << "\n"
                    << run_process(exe, args, kToolTimeoutMs) << "\n";
            } else if (c.name == "search_local") {
                std::string needle = c.args;
                if (needle.empty()) needle = c.sql;
                if (needle.empty()) needle = c.content;
                bool content = contains_ci(needle, "content:");
                if (content) {
                    const size_t col = ascii_lower(needle).find("content:");
                    needle = trim(needle.substr(col + 8));
                }
                if (needle.empty()) {
                    out << "search_local: query required (args). Prefix content: "
                           "for in-file search.\n";
                    continue;
                }
                const int depth = (std::max)(1, arg_int(c.args, "depth", 6));
                size_t seen = 0;
                size_t hits = 0;
                out << "search_local " << full << (content ? " content" : " name")
                    << " q=" << needle << "\n";
                const std::string rg = content ? find_rg() : "";
                if (content && !rg.empty()) {
                    const std::string rargs =
                        "-n --max-count 20 --max-filesize 512K -g !.git " +
                        quote_path(needle) + " " + quote_path(full);
                    out << run_process(rg, rargs, kToolTimeoutMs) << "\n";
                } else {
                    search_dir(full, needle, 0, depth, content, seen, hits, out);
                    out << "hits=" << hits << " scanned=" << seen << "\n";
                }
            } else if (c.name == "create_local_dir") {
                ensure_dir(full);
                out << "create_local_dir ok " << full << "\n";
            } else if (c.name == "move_local_file") {
                std::string dest = c.dest;
                if (dest.empty()) dest = c.args;
                if (dest.empty()) {
                    out << "move_local_file: dest required\n";
                    continue;
                }
                if (!path_is_granted(dest, &err)) {
                    out << "move_local_file denied dest: " << err << "\n";
                    continue;
                }
                const std::string dst = canon_path(dest);
                const size_t slash = dst.find_last_of("\\/");
                if (slash != std::string::npos) ensure_dir(dst.substr(0, slash));
                if (!MoveFileA(full.c_str(), dst.c_str())) {
                    out << "move_local_file failed " << full << " -> " << dst
                        << " err=" << GetLastError() << "\n";
                    continue;
                }
                out << "move_local_file ok " << full << " -> " << dst << "\n";
            } else if (c.name == "get_file_info") {
                WIN32_FILE_ATTRIBUTE_DATA fad{};
                if (!GetFileAttributesExA(full.c_str(), GetFileExInfoStandard, &fad)) {
                    out << "get_file_info: missing " << full << "\n";
                    continue;
                }
                ULARGE_INTEGER sz;
                sz.LowPart = fad.nFileSizeLow;
                sz.HighPart = fad.nFileSizeHigh;
                FILETIME local = fad.ftLastWriteTime;
                SYSTEMTIME st{};
                FileTimeToSystemTime(&local, &st);
                char tbuf[40];
                sprintf_s(tbuf, "%04u-%02u-%02uT%02u:%02u:%02uZ", st.wYear, st.wMonth,
                          st.wDay, st.wHour, st.wMinute, st.wSecond);
                const bool isdir =
                    (fad.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                out << "get_file_info " << full << "\n"
                    << (isdir ? "dir" : "file") << " bytes=" << sz.QuadPart
                    << " mtime=" << tbuf << "\n";
            } else if (c.name == "edit_local_file") {
                std::string old_text = c.old_text;
                if (old_text.empty() && c.sql.size()) old_text = c.sql;
                if (old_text.empty() || c.content.empty()) {
                    out << "edit_local_file: old_text and content (new) required\n";
                    continue;
                }
                bool trunc = false;
                std::string data = read_file_limited(full, kMaxWriteBytes, &trunc);
                if (trunc) {
                    out << "edit_local_file: file too large\n";
                    continue;
                }
                const bool all = contains_ci(c.args, "replace_all");
                size_t at = data.find(old_text);
                if (at == std::string::npos) {
                    out << "edit_local_file: old_text not found in " << full << "\n";
                    continue;
                }
                int nrep = 0;
                while (at != std::string::npos) {
                    data.replace(at, old_text.size(), c.content);
                    ++nrep;
                    if (!all) break;
                    at = data.find(old_text, at + c.content.size());
                }
                std::ofstream outf(full, std::ios::binary | std::ios::trunc);
                if (!outf) {
                    out << "edit_local_file: cannot write " << full << "\n";
                    continue;
                }
                outf.write(data.data(), static_cast<std::streamsize>(data.size()));
                out << "edit_local_file ok replacements=" << nrep << " " << full
                    << "\n";
            }
            continue;
        }

        if (is_sysint) {
            if (sysint_banned(sys_stem)) {
                out << "run_sysint denied: " << sys_stem
                    << " is never allowed (kill/remote/GUI/crash/wipe).\n";
                continue;
            }
            if (!sysint_allowed(sys_stem)) {
                out << unknown_tool_msg(c.name);
                continue;
            }
            if (args_have_newline(c.args)) {
                out << "run_sysint denied: args must be one line\n";
                continue;
            }
            std::string args = c.args;
            if (sys_stem == "psservice") {
                const std::string w = first_word(args);
                const bool mutate =
                    w == "stop" || w == "start" || w == "restart" ||
                    w == "pause" || w == "cont" || w == "setconfig";
                if (mutate && yolo_required_msg(out, "psservice")) continue;
            }
            if (sys_stem == "streams" && contains_ci(args, "-d") &&
                yolo_required_msg(out, "streams -d")) {
                continue;
            }
            const std::string want = c.exe.empty() ? (c.name == "run_sysint" ? c.path : c.name)
                                                   : c.exe;
            const std::string exe = find_sysint(want.empty() ? sys_stem : want);
            if (exe.empty()) {
                out << "run_sysint: " << sys_stem << " not in " << kSysintDir << "\n";
                continue;
            }
            args = with_accepteula(args);
            out << "run_sysint " << sys_stem << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_reg") {
            if (args_have_newline(c.args)) {
                out << "run_reg denied: args must be one line\n";
                continue;
            }
            std::string args = c.args;
            if (args.empty() && !c.path.empty()) args = "query " + quote_path(c.path);
            const std::string w = first_word(args);
            if (w.empty()) {
                out << "run_reg: args required (query HKLM\\...)\n";
                continue;
            }
            const bool query =
                w == "query" || w == "compare" || w == "export" || w == "flags";
            const bool mutate = w == "add" || w == "delete" || w == "copy" ||
                                w == "import" || w == "restore" || w == "load" ||
                                w == "unload" || w == "save";
            if (w == "save" || w == "load" || w == "restore" || w == "unload") {
                out << "run_reg denied: hive save/load/restore/unload is operator GO.\n";
                continue;
            }
            if (contains_ci(args, "\\sam") || contains_ci(args, "\\security")) {
                out << "run_reg denied: SAM/SECURITY hives are operator GO.\n";
                continue;
            }
            if (!query && !mutate) {
                out << "run_reg denied: first word must be query/add/delete/...\n";
                continue;
            }
            if (mutate && yolo_required_msg(out, "run_reg " + w)) continue;
            const std::string exe = system32("reg.exe");
            out << "run_reg " << w << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_wevtutil") {
            if (args_have_newline(c.args)) {
                out << "run_wevtutil denied: args must be one line\n";
                continue;
            }
            std::string args = c.args;
            if (args.empty()) args = "gl System";
            const std::string w = first_word(args);
            const bool query = w == "qe" || w == "q" || w == "gl" || w == "el" ||
                               w == "gp" || w == "im" || w == "enum-logs" ||
                               w == "get-log" || w == "query-events";
            const bool mutate = w == "cl" || w == "sl" || w == "set-log" ||
                                w == "clear-log" || w == "epl" ||
                                w == "export-log";
            if (!query && !mutate) {
                out << "run_wevtutil denied: use qe/gl/el (query) or cl (YOLO).\n";
                continue;
            }
            if (mutate && yolo_required_msg(out, "run_wevtutil " + w)) continue;
            const std::string exe = system32("wevtutil.exe");
            out << "run_wevtutil " << w << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_logman") {
            if (args_have_newline(c.args)) {
                out << "run_logman denied: args must be one line\n";
                continue;
            }
            std::string args = c.args;
            if (args.empty()) args = "query";
            const std::string w = first_word(args);
            const bool query = w == "query" || w == "queryproviders" || w.empty();
            const bool mutate = w == "start" || w == "stop" || w == "delete" ||
                                w == "create" || w == "update";
            if (!query && !mutate) {
                out << "run_logman denied: query always; start/stop/create YOLO.\n";
                continue;
            }
            if (mutate && yolo_required_msg(out, "run_logman " + w)) continue;
            const std::string exe = system32("logman.exe");
            out << "run_logman " << w << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_schtasks") {
            if (args_have_newline(c.args)) {
                out << "run_schtasks denied: args must be one line\n";
                continue;
            }
            std::string args = c.args;
            if (args.empty()) args = "/Query /FO LIST";
            const std::string w = first_word(args);
            const bool query = w == "/query" || w == "query" || w.empty();
            if (!query && !schtasks_mutates(w)) {
                out << "run_schtasks denied: /Query always; /Create /Change /Delete /Run YOLO.\n";
                continue;
            }
            if (!query && yolo_required_msg(out, "run_schtasks " + w)) continue;
            if (schtasks_destroys(w) && mentions_godbrain_task(args)) {
                out << "run_schtasks denied: GodBrain* tasks are not deleted/disabled "
                       "from the mouth. Operator GO.\n";
                continue;
            }
            const std::string exe = system32("schtasks.exe");
            out << "run_schtasks " << w << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_host") {
            if (args_have_newline(c.args)) {
                out << "run_host denied: args must be one line\n";
                continue;
            }
            const std::string stem = strip_exe(c.exe.empty() ? c.path : c.exe);
            const std::string host = stem.empty() ? first_word(c.args) : stem;
            static const char* kHost[] = {
                "tasklist", "whoami", "hostname", "where", "systeminfo",
                "netstat", "fltmc", "driverquery", "ipconfig", "sc", nullptr};
            bool ok = false;
            for (int i = 0; kHost[i]; ++i) {
                if (host == kHost[i]) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                out << "run_host denied: " << host
                    << " (tasklist whoami hostname where systeminfo netstat "
                       "fltmc driverquery ipconfig sc-query).\n";
                continue;
            }
            std::string args = c.args;
            {
                const std::string w = first_word(args);
                if (w == host || w == host + ".exe") {
                    size_t i = 0;
                    while (i < args.size() &&
                           std::isspace(static_cast<unsigned char>(args[i]))) {
                        ++i;
                    }
                    while (i < args.size() &&
                           !std::isspace(static_cast<unsigned char>(args[i]))) {
                        ++i;
                    }
                    args = trim(args.substr(i));
                }
            }
            if (host == "ipconfig") {
                if (contains_ci(args, "/release") || contains_ci(args, "/renew")) {
                    out << "run_host denied: ipconfig /release /renew needs operator GO.\n";
                    continue;
                }
                if (contains_ci(args, "/flushdns") &&
                    yolo_required_msg(out, "ipconfig /flushdns")) {
                    continue;
                }
            }
            if (host == "sc") {
                const std::string w = first_word(args);
                const bool query = w == "query" || w == "qc" || w == "qdescription" ||
                                   w == "qfailure" || w == "enumdepend" ||
                                   w == "queryex" || w.empty();
                const bool mutate = w == "start" || w == "stop" || w == "config" ||
                                    w == "delete" || w == "create" || w == "pause" ||
                                    w == "continue";
                if (!query && !mutate) {
                    out << "run_host sc denied: query always; start/stop YOLO.\n";
                    continue;
                }
                if (mutate && yolo_required_msg(out, "sc " + w)) continue;
                if (mutate && protected_service(args)) {
                    out << "run_host denied: BFE/mpssvc/Dnscache/MongoDB/RPC stay up. "
                           "Operator GO.\n";
                    continue;
                }
            }
            const std::string exe = system32((host + ".exe").c_str());
            out << "run_host " << host << "\n"
                << run_process(exe, args, kToolTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_pwsh") {
            if (dangerous_script(c.content) || dangerous_script(c.args) ||
                dangerous_script(c.path)) {
                out << "run_pwsh denied: command hits a hard deny "
                       "(git push/reboot/DISM/pskill/format).\n";
                continue;
            }
            const std::string pwsh = find_pwsh();
            if (pwsh.empty()) {
                out << "run_pwsh: pwsh.exe not found\n";
                continue;
            }
            if (!c.path.empty()) {
                if (!path_is_granted(c.path, &err)) {
                    out << "run_pwsh denied: " << err << "\n";
                    continue;
                }
                const std::string full = canon_path(c.path);
                bool trunc = false;
                const std::string preview =
                    read_file_limited(full, kMaxPwshBytes, &trunc);
                if (dangerous_script(preview)) {
                    out << "run_pwsh denied: script hits a hard deny\n";
                    continue;
                }
                std::string args = "-NoProfile -NonInteractive -File " + quote_path(full);
                if (!c.args.empty()) {
                    if (args_have_newline(c.args)) {
                        out << "run_pwsh denied: args must be one line\n";
                        continue;
                    }
                    args += " " + c.args;
                }
                out << "run_pwsh -File " << full << "\n"
                    << run_process(pwsh, args, kPwshTimeoutMs) << "\n";
                continue;
            }
            if (c.content.empty() && !c.args.empty()) c.content = c.args;
            if (c.content.empty()) {
                out << "run_pwsh: path (.ps1 under granted roots) or command body required\n";
                continue;
            }
            if (c.content.size() > kMaxPwshBytes) {
                out << "run_pwsh: body too large\n";
                continue;
            }
            const std::string tmp = write_temp_ps1(c.content);
            if (tmp.empty()) {
                out << "run_pwsh: cannot write temp script\n";
                continue;
            }
            const std::string args =
                "-NoProfile -NonInteractive -File " + quote_path(tmp);
            out << "run_pwsh inline\n"
                << run_process(pwsh, args, kPwshTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_python" || c.name == "run_node") {
            if (c.content.empty() && !c.args.empty()) c.content = c.args;
            if (dangerous_script(c.content) || dangerous_script(c.path)) {
                out << c.name << " denied: hard deny (git push/reboot/DISM/kill/mongo).\n";
                continue;
            }
            const bool py = c.name == "run_python";
            std::string exe = py ? find_python() : find_on_path("node");
            if (exe.empty()) {
                out << c.name << ": interpreter not found\n";
                continue;
            }
            if (!c.path.empty()) {
                if (!path_is_granted(c.path, &err)) {
                    out << c.name << " denied: " << err << "\n";
                    continue;
                }
                const std::string full = canon_path(c.path);
                out << c.name << " " << full << "\n"
                    << run_process(exe, quote_path(full) +
                                            (c.args.empty() ? "" : " " + c.args),
                                   kPwshTimeoutMs)
                    << "\n";
                continue;
            }
            if (c.content.empty()) {
                out << c.name << ": path or body required\n";
                continue;
            }
            if (c.content.size() > kMaxPwshBytes) {
                out << c.name << ": body too large\n";
                continue;
            }
            const std::string tmp =
                write_temp_script(c.content, py ? ".py" : ".js");
            if (tmp.empty()) {
                out << c.name << ": cannot write temp script\n";
                continue;
            }
            out << c.name << " inline\n"
                << run_process(exe, quote_path(tmp), kPwshTimeoutMs) << "\n";
            continue;
        }

        if (c.name == "run_elevate") {
            if (yolo_required_msg(out, "run_elevate")) continue;
            if (c.content.empty() && c.args.empty() && c.path.empty()) {
                out << "run_elevate: command body or path required\n";
                continue;
            }
            std::string body = c.content;
            if (body.empty() && !c.path.empty()) {
                if (!path_is_granted(c.path, &err)) {
                    out << "run_elevate denied: " << err << "\n";
                    continue;
                }
                body = "& " + quote_path(canon_path(c.path));
            }
            if (body.empty()) body = c.args;
            if (dangerous_script(body) || elevate_flags_denied(body) ||
                elevate_flags_denied(c.args)) {
                out << "run_elevate denied: --ti/System/git push/reboot/DISM/kill "
                       "are operator GO.\n";
                continue;
            }
            if (body.size() > kMaxPwshBytes) {
                out << "run_elevate: body too large\n";
                continue;
            }
            const std::string tmp = write_temp_ps1(body);
            if (tmp.empty()) {
                out << "run_elevate: cannot write temp script\n";
                continue;
            }
            const std::string pwsh = find_pwsh();
            if (pwsh.empty()) {
                out << "run_elevate: pwsh.exe not found\n";
                continue;
            }
            std::string launcher;
            std::string args;
            if (file_exists(kMinSudo)) {
                launcher = kMinSudo;
                args = "--NoLogo " + quote_path(pwsh) +
                       " -NoProfile -NonInteractive -File " + quote_path(tmp);
            } else if (file_exists(kWsudo)) {
                launcher = kWsudo;
                args = "-A -w " + quote_path(pwsh) +
                       " -NoProfile -NonInteractive -File " + quote_path(tmp);
            } else {
                out << "run_elevate: MinSudo/wsudo not in C:\\Tools\\TeamM2\n";
                continue;
            }
            out << "run_elevate\n"
                << run_process(launcher, args, kPwshTimeoutMs) << "\n";
            continue;
        }

        out << unknown_tool_msg(c.name);
    }
    return out.str();
}

std::string run_tools_from_text(const std::string& model_text) {
    return execute_calls(parse_tool_blocks(model_text));
}

std::string tool_system_addendum() {
    std::string s =
        " You have built-in host tools (OpenAI tool_calls). The kernel executes; "
        "not MCP, not a plugin pile. You are not in a void. "
        "Granted roots: C:\\Users\\autismo and C:\\Temp\\GitHub. "
        "Always: list_local_dir (args depth=N), read_local_file (offset=/limit=, "
        "offset=-N tail), write_local_file (args append), create_local_dir, "
        "move_local_file, get_file_info, search_local (content:needle for "
        "in-file), edit_local_file (replace_all), run_strings, run_sqlite3, "
        "run_pwsh, run_python, run_node (60s Job; CSV/Excel/PDF via python "
        "libs if installed). Aliases: read_file/write_file/edit_block/"
        "start_search/execute_command/start_process/create_directory/move_file/"
        "get_metadata/list_processes. run_sysint; run_reg query; run_wevtutil; "
        "run_logman; run_schtasks /Query; run_host. "
        "YOLO only: run_elevate (MinSudo/wsudo -A, not --ti), reg add/delete, "
        "schtasks mutate, wevtutil cl, sc start/stop. Never pskill/kill_process/"
        "psexec/interactive SSH-DB/notmyfault/sysmon/MFIT/git push/DISM/reboot/"
        "Mongo/GodBrain* task delete/BFE-mpssvc-Dnscache stop. "
        "Calls append logs/tool-audit.jsonl (10MiB rotate). "
        "Call tools when the operator asks to inspect the host or a granted folder. "
        "Ordinary questions: no tools. Do not claim you lack a filesystem.";
    if (yolo_active()) {
        s += " YOLO session is ON: keep calling tools until the job is done "
             "(map, sort, patch). No ASCII art, no outline, no asking.";
    }
    return s;
}

static json tool_fn(const char* name, const char* desc, json props,
                    json required = json::array()) {
    json params = {{"type", "object"}, {"properties", std::move(props)}};
    if (!required.empty()) params["required"] = std::move(required);
    return json{
        {"type", "function"},
        {"function",
         {{"name", name},
          {"description", desc},
          {"parameters", std::move(params)}}},
    };
}

nlohmann::json openai_tool_defs() {
    const json path = {
        {"type", "string"},
        {"description",
         "Absolute path. File tools jail to C:\\Users\\autismo or C:\\Temp\\GitHub."}};
    const json args = {
        {"type", "string"},
        {"description", "One-line CLI arguments. No newlines."}};
    const json content = {
        {"type", "string"},
        {"description", "File body or inline pwsh script."}};
    json tools = json::array();
    tools.push_back(tool_fn(
        "list_local_dir",
        "List a granted directory. args depth=N (1=flat, max 8).",
        {{"path", path}, {"args", args}}, {"path"}));
    tools.push_back(tool_fn(
        "read_local_file",
        "Read a granted text file (256KiB). args offset=N limit=M; offset=-N is tail.",
        {{"path", path}, {"args", args}}, {"path"}));
    tools.push_back(tool_fn(
        "write_local_file",
        "Create/overwrite a file under granted roots. args=append to append.",
        {{"path", path}, {"content", content}, {"args", args}},
        {"path", "content"}));
    tools.push_back(tool_fn(
        "create_local_dir", "Create a directory under granted roots.",
        {{"path", path}}, {"path"}));
    tools.push_back(tool_fn(
        "move_local_file", "Move/rename a granted path to dest (also granted).",
        {{"path", path},
         {"dest", {{"type", "string"}, {"description", "Destination path."}}}},
        {"path", "dest"}));
    tools.push_back(tool_fn(
        "get_file_info", "Size, mtime, file vs dir for a granted path.",
        {{"path", path}}, {"path"}));
    tools.push_back(tool_fn(
        "run_strings", "strings64 on a granted file.", {{"path", path}}, {"path"}));
    tools.push_back(tool_fn(
        "run_sqlite3", "Read-only sqlite3 SELECT/PRAGMA on a granted db.",
        {{"path", path},
         {"sql", {{"type", "string"}, {"description", "SELECT or PRAGMA."}}}},
        {"path", "sql"}));
    tools.push_back(tool_fn(
        "run_sysint",
        "Console SysInternals *64 from C:\\Tools\\SysInternals. Not pskill/psexec.",
        {{"exe",
          {{"type", "string"},
           {"description", "Stem such as handle64, tcpvcon64, psping64."}}},
         {"args", args}},
        {"exe"}));
    tools.push_back(tool_fn(
        "run_reg", "reg.exe. query always; add/delete need YOLO. No SAM/SECURITY.",
        {{"args", args}}, {"args"}));
    tools.push_back(tool_fn(
        "run_wevtutil", "wevtutil. qe/gl always; cl needs YOLO.",
        {{"args", args}}));
    tools.push_back(tool_fn(
        "run_logman", "logman ETW. query always; start/stop need YOLO.",
        {{"args", args}}));
    tools.push_back(tool_fn(
        "run_schtasks",
        "schtasks. /Query always; mutate needs YOLO. Cannot delete GodBrain* tasks.",
        {{"args", args}}));
    tools.push_back(tool_fn(
        "run_host",
        "tasklist/whoami/hostname/where/systeminfo/netstat/fltmc/driverquery/"
        "ipconfig-show/sc query.",
        {{"exe", {{"type", "string"}, {"description", "Image stem, e.g. tasklist."}}},
         {"args", args}},
        {"exe"}));
    tools.push_back(tool_fn(
        "search_local",
        "Recursive search. args is a name substring, or content:needle for in-file. "
        "depth=N. Skips .git/node_modules/AppData. 80 hits.",
        {{"path", path},
         {"args", {{"type", "string"}, {"description", "Name or content:needle."}}}},
        {"path", "args"}));
    tools.push_back(tool_fn(
        "edit_local_file",
        "Replace old_text with content. args=replace_all for every occurrence.",
        {{"path", path},
         {"old_text", {{"type", "string"}, {"description", "Exact text to find."}}},
         {"content", content},
         {"args", args}},
        {"path", "old_text", "content"}));
    tools.push_back(tool_fn(
        "run_pwsh",
        "Run pwsh. path = granted .ps1, or content/args = inline command. 60s Job. "
        "Hard-deny git push/reboot/DISM/pskill/mongo.",
        {{"path", path}, {"content", content}, {"args", args}}));
    tools.push_back(tool_fn(
        "run_python",
        "Run host python on a granted .py or inline body (CSV/JSON/Excel via "
        "pandas/openpyxl if installed). 60s Job. Not Mongo.",
        {{"path", path}, {"content", content}, {"args", args}}));
    tools.push_back(tool_fn(
        "run_node",
        "Run host node on a granted .js or inline body. 60s Job.",
        {{"path", path}, {"content", content}, {"args", args}}));
    tools.push_back(tool_fn(
        "run_elevate",
        "YOLO only. MinSudo/wsudo -A, never --ti. Body is pwsh to run elevated.",
        {{"content", content}, {"path", path}}));
    return tools;
}

std::vector<Call> calls_from_openai(const nlohmann::json& tool_calls) {
    std::vector<Call> out;
    if (!tool_calls.is_array()) return out;
    for (const auto& tc : tool_calls) {
        Call c;
        json fn = json::object();
        if (tc.contains("function") && tc["function"].is_object()) {
            fn = tc["function"];
        }
        c.name = ascii_lower(fn.value("name", ""));
        json args = json::object();
        if (fn.contains("arguments")) {
            if (fn["arguments"].is_string()) {
                const std::string raw = fn["arguments"].get<std::string>();
                if (!raw.empty()) {
                    try {
                        args = json::parse(raw);
                    } catch (...) {
                        c.args = raw;
                    }
                }
            } else if (fn["arguments"].is_object()) {
                args = fn["arguments"];
            }
        }
        if (args.is_object()) {
            c.path = args.value("path", "");
            c.sql = args.value("sql", "");
            c.exe = args.value("exe", "");
            c.old_text = args.value("old_text", args.value("old", ""));
            c.dest = args.value("dest", "");
            if (args.contains("offset") || args.contains("limit") ||
                args.contains("depth") || args.contains("append") ||
                args.contains("replace_all") || args.contains("content_search")) {
                std::ostringstream extra;
                extra << c.args;
                if (args.contains("offset")) extra << " offset=" << args["offset"];
                if (args.contains("limit")) extra << " limit=" << args["limit"];
                if (args.contains("depth")) extra << " depth=" << args["depth"];
                if (args.value("append", false)) extra << " append";
                if (args.value("replace_all", false)) extra << " replace_all";
                if (args.value("content_search", false) &&
                    c.args.find("content:") == std::string::npos) {
                    extra.str("content:" + c.args);
                }
                c.args = trim(extra.str());
            }
            if (args.contains("content") && args["content"].is_string()) {
                c.content = args["content"].get<std::string>();
            } else if (args.contains("body") && args["body"].is_string()) {
                c.content = args["body"].get<std::string>();
            }
            if (args.contains("args")) {
                if (args["args"].is_string()) {
                    c.args = args["args"].get<std::string>();
                } else if (!args["args"].is_null()) {
                    c.args = args["args"].dump();
                }
            }
        }
        if (!c.name.empty()) out.push_back(c);
    }
    return out;
}

}  // namespace local_tools
