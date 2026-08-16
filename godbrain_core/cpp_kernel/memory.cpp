#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "memory.h"
#include "rag_client.h"
#include "telemetry.h"
#include "../cpp_tools/keccak256.hpp"

#include <windows.h>
#include <winhttp.h>
#include <winsvc.h>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "advapi32.lib")

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace memory {
namespace {

std::string trim_copy(std::string value);

constexpr size_t kMaxThoughtBytes = 32 * 1024;
constexpr size_t kMaxSessionThoughts = 3;
constexpr size_t kMaxSessionSnippetBytes = 240;
constexpr DWORD kStoreTimeoutMs = 35000;

struct SessionThought {
    std::string source_hash;
    std::string stable_id;
    std::string content;
    std::string status;
};

std::mutex g_session_mutex;
std::vector<SessionThought> g_session_thoughts;

std::string collapse_fields(std::string value, bool lower) {
    std::string out;
    bool in_token = false;
    for (unsigned char character : value) {
        if (std::isspace(character) != 0) {
            in_token = false;
            continue;
        }
        if (!out.empty() && !in_token) out.push_back(' ');
        out.push_back(static_cast<char>(
            lower ? std::tolower(character) : character));
        in_token = true;
    }
    return out;
}

std::string claim_stable_id(const std::string& type, const std::string& content) {
    return keccak256(
        std::string("claim") + '\0' + collapse_fields(type, true) + '\0' +
        collapse_fields(content, false));
}

void remember_session(
    const std::string& source_hash,
    const std::string& stable_id,
    const std::string& content,
    const std::string& status = "candidate") {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    g_session_thoughts.erase(
        std::remove_if(
            g_session_thoughts.begin(),
            g_session_thoughts.end(),
            [&](const SessionThought& thought) {
                return thought.source_hash == source_hash ||
                       thought.stable_id == stable_id;
            }),
        g_session_thoughts.end());
    const std::string trust =
        (status == "verified" || status == "rejected") ? status : "candidate";
    std::string snippet = content;
    if (snippet.size() > kMaxSessionSnippetBytes) {
        snippet.resize(kMaxSessionSnippetBytes);
    }
    g_session_thoughts.push_back({source_hash, stable_id, snippet, trust});
    if (g_session_thoughts.size() > kMaxSessionThoughts) {
        g_session_thoughts.erase(
            g_session_thoughts.begin(),
            g_session_thoughts.begin() +
                static_cast<std::ptrdiff_t>(
                    g_session_thoughts.size() - kMaxSessionThoughts));
    }
}

std::vector<SessionThought> copy_session(int limit) {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    if (limit <= 0 || static_cast<size_t>(limit) >= g_session_thoughts.size()) {
        return g_session_thoughts;
    }
    return std::vector<SessionThought>(
        g_session_thoughts.end() - limit, g_session_thoughts.end());
}

std::string read_env(const char* name) {
    char* value = nullptr;
    size_t length = 0;
    if (_dupenv_s(&value, &length, name) != 0 || value == nullptr) return "";
    std::string result(value);
    std::free(value);
    return result;
}

std::string exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(nullptr, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    const size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

bool file_exists(const std::string& path) {
    const DWORD attrs = GetFileAttributesA(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES &&
           (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::string pin_file_path() {
    const std::string dir = exe_dir();
    return dir.empty() ? "windows-pin.txt" : dir + "\\windows-pin.txt";
}

std::string read_pin_file() {
    std::ifstream in(pin_file_path());
    if (!in) return "";
    std::string line;
    std::getline(in, line);
    return trim_copy(line);
}

void write_pin_file(const std::string& pin) {
    std::ofstream out(pin_file_path(), std::ios::trunc);
    if (out) out << pin << '\n';
}

bool valid_os_pin(const std::string& pin) {
    if (pin.empty() || pin.size() > 80) return false;
    for (unsigned char ch : pin) {
        if (!std::isalnum(ch) && ch != '.' && ch != '/' && ch != '_' &&
            ch != '-') {
            return false;
        }
    }
    return true;
}

std::string ascii_lower(std::string value) {
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string collapse_ws(const std::string& raw) {
    std::string out;
    bool space = false;
    for (unsigned char ch : raw) {
        if (ch <= 32) {
            space = true;
            continue;
        }
        if (space && !out.empty()) out.push_back(' ');
        space = false;
        out.push_back(static_cast<char>(ch));
    }
    return out;
}

std::string strip_html(const std::string& html) {
    std::string out;
    bool tag = false;
    for (char ch : html) {
        if (ch == '<') {
            tag = true;
            out.push_back(' ');
            continue;
        }
        if (ch == '>') {
            tag = false;
            continue;
        }
        if (!tag) out.push_back(ch);
    }
    return collapse_ws(out);
}

bool host_allowed(const std::string& host) {
    const std::string lower = ascii_lower(host);
    return lower == "learn.microsoft.com" || lower == "support.microsoft.com";
}

bool fetch_ms_doc(const std::string& url, std::string& body, std::string& error) {
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    wchar_t host[256]{};
    wchar_t path[2048]{};
    parts.lpszHostName = host;
    parts.dwHostNameLength = 256;
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = 2048;
    std::wstring wide(url.begin(), url.end());
    if (url.size() < 12 || ascii_lower(url.substr(0, 8)) != "https://") {
        error = "learn/support URL must be https";
        return false;
    }
    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &parts)) {
        error = "could not parse URL";
        return false;
    }
    char host_a[256]{};
    WideCharToMultiByte(CP_UTF8, 0, host, -1, host_a, 256, nullptr, nullptr);
    if (!host_allowed(host_a)) {
        error = "only learn.microsoft.com and support.microsoft.com";
        return false;
    }
    HINTERNET session = WinHttpOpen(
        L"GodBrain-Truth/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        error = "WinHttpOpen failed";
        return false;
    }
    HINTERNET connect = WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!connect) {
        WinHttpCloseHandle(session);
        error = "WinHttpConnect failed";
        return false;
    }
    HINTERNET request = WinHttpOpenRequest(
        connect, L"GET", path, nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!request) {
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        error = "WinHttpOpenRequest failed";
        return false;
    }
    BOOL sent = WinHttpSendRequest(
        request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (!sent || !WinHttpReceiveResponse(request, nullptr)) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        error = "Learn/support fetch failed";
        return false;
    }
    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    if (!WinHttpQueryHeaders(
            request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX,
            &statusCode,
            &statusSize,
            WINHTTP_NO_HEADER_INDEX) ||
        statusCode < 200 || statusCode > 299) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        error = "Learn/support HTTP " + std::to_string(statusCode);
        return false;
    }
    constexpr size_t kMax = 1500 * 1024;
    std::string raw;
    raw.reserve(64 * 1024);
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail)) break;
        if (avail == 0) break;
        if (raw.size() + avail > kMax) {
            WinHttpCloseHandle(request);
            WinHttpCloseHandle(connect);
            WinHttpCloseHandle(session);
            error = "document too large";
            return false;
        }
        std::string chunk(avail, '\0');
        DWORD got = 0;
        if (!WinHttpReadData(request, chunk.data(), avail, &got)) break;
        chunk.resize(got);
        raw.append(chunk);
    }
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    body = strip_html(raw);
    return true;
}

bool path_under_allowlist(const std::string& path) {
    const std::string lower = ascii_lower(path);
    static const char* prefixes[] = {
        "c:\\windows\\system32\\",
        "c:\\windows\\systemapps\\",
        "c:\\programdata\\microsoft\\windows\\",
        "c:\\nvme\\glm52-uncensored\\",
        "c:\\nvme\\stt\\",
        "c:\\nvme\\piper-voices\\",
        "c:\\nvme\\faster-whisper-large-v3\\",
    };
    for (const char* prefix : prefixes) {
        if (lower.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

bool registry_path_ok(const std::string& path) {
    if (path.empty() || path.size() > 256) return false;
    if (path.find("..") != std::string::npos) return false;
    for (unsigned char ch : path) {
        if (ch < 32 || ch == '*' || ch == '?' || ch == '/') return false;
    }
    return true;
}

bool probe_registry_key(const std::string& path) {
    if (!registry_path_ok(path)) return false;
    std::wstring wide(path.begin(), path.end());
    HKEY key = nullptr;
    const LONG rc = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE, wide.c_str(), 0, KEY_READ | KEY_WOW64_64KEY, &key);
    if (rc != ERROR_SUCCESS) return false;
    RegCloseKey(key);
    return true;
}

bool probe_registry_value(
    const std::string& path, const std::string& name, const std::string& expect,
    std::string& got) {
    if (!registry_path_ok(path) || name.empty() || name.size() > 128) return false;
    std::wstring wpath(path.begin(), path.end());
    std::wstring wname(name.begin(), name.end());
    wchar_t buffer[512];
    DWORD bytes = sizeof(buffer);
    DWORD type = 0;
    LONG rc = RegGetValueW(
        HKEY_LOCAL_MACHINE, wpath.c_str(), wname.c_str(),
        RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_SUBKEY_WOW6464KEY,
        &type, buffer, &bytes);
    if (rc == ERROR_SUCCESS) {
        const size_t chars = bytes / sizeof(wchar_t);
        std::wstring raw(buffer, chars > 0 ? chars - 1 : 0);
        got.clear();
        for (wchar_t ch : raw) {
            if (ch < 128) got.push_back(static_cast<char>(ch));
        }
        return expect.empty() || ascii_lower(got).find(ascii_lower(expect)) != std::string::npos;
    }
    DWORD dword = 0;
    bytes = sizeof(dword);
    rc = RegGetValueW(
        HKEY_LOCAL_MACHINE, wpath.c_str(), wname.c_str(),
        RRF_RT_REG_DWORD | RRF_SUBKEY_WOW6464KEY, &type, &dword, &bytes);
    if (rc != ERROR_SUCCESS) return false;
    char num[32];
    std::snprintf(num, sizeof(num), "%lu", static_cast<unsigned long>(dword));
    got = num;
    return expect.empty() || got == expect;
}

bool probe_appx(const std::string& name) {
    if (name.empty() || name.size() > 128) return false;
    const wchar_t* roots[] = {
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications",
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Applications",
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Deprovisioned",
    };
    for (const wchar_t* root : roots) {
        HKEY key = nullptr;
        if (RegOpenKeyExW(
                HKEY_LOCAL_MACHINE, root, 0, KEY_READ | KEY_WOW64_64KEY, &key) !=
            ERROR_SUCCESS) {
            continue;
        }
        wchar_t child[512];
        for (DWORD i = 0;; ++i) {
            DWORD len = 512;
            if (RegEnumKeyExW(key, i, child, &len, nullptr, nullptr, nullptr, nullptr) !=
                ERROR_SUCCESS) {
                break;
            }
            std::string utf8;
            utf8.reserve(len);
            for (DWORD n = 0; n < len; ++n) {
                if (child[n] < 128) utf8.push_back(static_cast<char>(child[n]));
            }
            if (ascii_lower(utf8).find(ascii_lower(name)) != std::string::npos) {
                RegCloseKey(key);
                return true;
            }
        }
        RegCloseKey(key);
    }
    return false;
}

bool probe_service(const std::string& name, std::string& state) {
    if (name.empty() || name.size() > 64) return false;
    std::wstring wide(name.begin(), name.end());
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm) return false;
    SC_HANDLE svc = OpenServiceW(scm, wide.c_str(), SERVICE_QUERY_STATUS);
    if (!svc) {
        CloseServiceHandle(scm);
        return false;
    }
    SERVICE_STATUS_PROCESS ssp{};
    DWORD needed = 0;
    const BOOL ok = QueryServiceStatusEx(
        svc, SC_STATUS_PROCESS_INFO, reinterpret_cast<LPBYTE>(&ssp),
        sizeof(ssp), &needed);
    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    if (!ok) return false;
    state = (ssp.dwCurrentState == SERVICE_RUNNING) ? "running" : "stopped";
    return true;
}

bool probe_file(const std::string& path) {
    return path_under_allowlist(path) && file_exists(path);
}

std::string resolve_memory_store();

bool rag_projection_ready() {
    httplib::Client client("127.0.0.1", 8084);
    client.set_connection_timeout(0, 200000);
    client.set_read_timeout(2, 0);
    const auto response = client.Get("/health");
    if (!response || response->body.empty()) return false;
    try {
        return json::parse(response->body).value("ready", false);
    } catch (const json::exception&) {
        return false;
    }
}

void ensure_rag_ready() {
    if (rag_projection_ready()) return;
    std::string rebuild = resolve_memory_store();
    const auto slash = rebuild.find_last_of("\\/");
    if (slash == std::string::npos) return;
    rebuild = rebuild.substr(0, slash + 1) + "rag-rebuild.exe";
    if (!file_exists(rebuild)) {
        std::cout << "[MEMORY] rag-rebuild.exe not found; projection may stay unready"
                  << std::endl;
        return;
    }
    if (read_env("MONGODB_URI").empty()) {
        SetEnvironmentVariableA("MONGODB_URI", "mongodb://127.0.0.1:27017");
    }
    std::cout << "[MEMORY] RAG projection unready; running rag-rebuild.exe" << std::endl;
    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    std::string command = "\"" + rebuild + "\"";
    std::vector<char> cmdline(command.begin(), command.end());
    cmdline.push_back('\0');
    if (CreateProcessA(
            nullptr,
            cmdline.data(),
            nullptr,
            nullptr,
            FALSE,
            CREATE_NO_WINDOW,
            nullptr,
            nullptr,
            &startup,
            &process) == 0) {
        std::cout << "[MEMORY] failed to start rag-rebuild.exe" << std::endl;
        return;
    }
    WaitForSingleObject(process.hProcess, 60000);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    if (rag_projection_ready()) {
        std::cout << "[MEMORY] RAG projection is ready again" << std::endl;
    } else {
        std::cout << "[MEMORY] RAG projection still unready after rebuild" << std::endl;
    }
}

std::string resolve_memory_store() {
    const std::string override_path = read_env("MONGO_STORE_PATH");
    if (!override_path.empty()) return override_path;
    const std::string dir = exe_dir();
    const std::string candidates[] = {
        dir + "\\memory-store.exe",
        dir + "\\..\\memory_store\\memory-store.exe",
        dir + "\\..\\..\\godbrain_core\\memory_store\\memory-store.exe",
    };
    for (const auto& candidate : candidates) {
        if (file_exists(candidate)) return candidate;
    }
    return dir + "\\..\\memory_store\\memory-store.exe";
}

std::string trim_copy(std::string value) {
    const auto not_space = [](unsigned char character) {
        return std::isspace(character) == 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
    return value;
}

bool looks_like_secret(const std::string& text) {
    return text.find("otpauth://") != std::string::npos ||
           text.find("otpauth-migration://") != std::string::npos ||
           (text.find("BEGIN ") != std::string::npos &&
            text.find("PRIVATE KEY") != std::string::npos);
}

json run_memory_store(const json& payload) {
    const std::string exe = resolve_memory_store();
    if (!file_exists(exe)) {
        throw std::runtime_error(
            "memory-store.exe not found; set MONGO_STORE_PATH");
    }

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;

    HANDLE out_read = nullptr;
    HANDLE out_write = nullptr;
    HANDLE in_read = nullptr;
    HANDLE in_write = nullptr;
    if (!CreatePipe(&out_read, &out_write, &attributes, 0)) {
        throw std::runtime_error("failed to create memory-store stdout pipe");
    }
    SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
    if (!CreatePipe(&in_read, &in_write, &attributes, 0)) {
        CloseHandle(out_read);
        CloseHandle(out_write);
        throw std::runtime_error("failed to create memory-store stdin pipe");
    }
    SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    startup.hStdOutput = out_write;
    startup.hStdInput = in_read;
    startup.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION process{};
    std::string command = "\"" + exe + "\"";
    std::vector<char> cmdline(command.begin(), command.end());
    cmdline.push_back('\0');
    const BOOL started = CreateProcessA(
        nullptr,
        cmdline.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr,
        nullptr,
        &startup,
        &process);
    CloseHandle(out_write);
    CloseHandle(in_read);
    if (started == 0) {
        CloseHandle(in_write);
        CloseHandle(out_read);
        throw std::runtime_error("failed to start memory-store.exe");
    }

    const std::string body = payload.dump();
    std::string output;
    std::thread reader([&]() {
        char buffer[4096];
        DWORD read = 0;
        while (ReadFile(out_read, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
            output.append(buffer, read);
        }
    });
    std::thread writer([&]() {
        DWORD written_total = 0;
        while (written_total < body.size()) {
            DWORD written = 0;
            if (!WriteFile(
                    in_write,
                    body.data() + written_total,
                    static_cast<DWORD>(body.size() - written_total),
                    &written,
                    nullptr)) {
                break;
            }
            written_total += written;
        }
        CloseHandle(in_write);
    });

    const DWORD wait = WaitForSingleObject(process.hProcess, kStoreTimeoutMs);
    if (wait == WAIT_TIMEOUT) {
        TerminateProcess(process.hProcess, 1);
        if (reader.joinable()) reader.join();
        if (writer.joinable()) writer.join();
        CloseHandle(process.hProcess);
        CloseHandle(process.hThread);
        CloseHandle(out_read);
        throw std::runtime_error("memory-store.exe timed out");
    }
    if (reader.joinable()) reader.join();
    if (writer.joinable()) writer.join();

    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    CloseHandle(out_read);
    if (exit_code != 0) {
        throw std::runtime_error(
            "memory-store.exe failed: " + output);
    }
    try {
        return json::parse(output);
    } catch (const json::exception&) {
        throw std::runtime_error("memory-store.exe returned malformed JSON");
    }
}

}  // namespace

json save_thought(const json& payload) {
    const std::string content = trim_copy(payload.value("content", ""));
    if (content.empty() || content.size() > kMaxThoughtBytes ||
        content.find('\0') != std::string::npos) {
        throw std::runtime_error("thought content is empty, oversized, or invalid");
    }
    if (looks_like_secret(content)) {
        throw std::runtime_error("thought looks like a secret and was rejected");
    }

    const std::string source_hash = keccak256(content);
    const std::string sector = trim_copy(payload.value("sector", "operator"));
    const std::string claim_type = sector.empty() ? "operator" : sector;
    json document = {
        {"extractor_id", "Kernel-Thought-CPP"},
        {"extractor_version", "1.0.0"},
        {"schema_version", "1.0"},
        {"degraded", false},
        {"raw_transcript", content},
        {"payload",
         {{"trust_tier", "candidate"},
          {"provenance",
           {{"source_id", "thought:" + source_hash.substr(0, 16)},
            {"source_type", "operator_thought"},
            {"source_hash", source_hash},
            {"language", "mixed"},
            {"prompt_hash", "N/A"},
            {"model_id", "operator"},
            {"model_hash", "N/A"},
            {"llm_temperature", 0.0}}},
          {"claims",
           json::array(
               {json{
                   {"claim_id", "claim:" + source_hash.substr(0, 16)},
                   {"type", claim_type},
                   {"content", content},
                   {"confidence", 1.0},
                   {"evidence_spans",
                    json::array({"[0:" + std::to_string(content.size()) + "]"})}}})},
          {"core_concepts", json::array()},
          {"opsec_candidates", json::array()}}},
    };

    std::cout << "[MEMORY] Committing operator thought via memory-store ("
              << content.size() << " bytes)" << std::endl;
    const json receipt = run_memory_store(document);
    const std::string status = receipt.value("status", "");
    if (status != "committed" && status != "idempotent_noop") {
        throw std::runtime_error(
            "memory-store rejected thought: " + receipt.dump());
    }
    const std::string stable_id = claim_stable_id(claim_type, content);
    remember_session(source_hash, stable_id, content);
    ensure_rag_ready();
    return {
        {"status", "success"},
        {"run_id", receipt.value("run_id", "")},
        {"record_id", receipt.value("record_id", "")},
        {"store_status", status},
        {"source_hash", source_hash},
        {"stable_id", stable_id},
    };
}

json observe_host() {
    const json inventory = telemetry::get_host_inventory();
    const json live = telemetry::get_current_state();
    const std::string pin = inventory.value("os_pin", "");
    std::ostringstream body;
    body << "Windows host inventory\n"
         << "claim_class=host_fact\n"
         << "os_pin=" << pin << '\n'
         << "computer_name="
         << inventory.at("computer_name").get<std::string>() << '\n'
         << "edition_id=" << inventory.value("edition_id", "") << '\n'
         << "product_name=" << inventory.value("product_name", "") << '\n'
         << "display_version=" << inventory.value("display_version", "") << '\n'
         << "current_build=" << inventory.value("current_build", "") << '\n'
         << "ubr=" << inventory.value("ubr", 0) << '\n'
         << "total_physical_ram_gb="
         << inventory.at("total_physical_ram_gb").get<int>() << '\n'
         << "logical_processors="
         << inventory.at("logical_processors").get<int>() << '\n';
    const json volumes = inventory.value("volumes", json::array());
    for (const auto& volume : volumes) {
        body << "volume=" << volume.value("letter", "?")
             << " type=" << volume.value("type", "fixed")
             << " label=" << volume.value("label", "")
             << " total_gb=" << volume.value("total_gb", 0) << '\n';
    }
    json stored = save_thought({
        {"content", body.str()},
        {"sector", "windows-sre"},
    });
    if (!pin.empty() && !stored.value("stable_id", "").empty()) {
        try {
            json judged = set_status({
                {"id", stored.value("stable_id", "")},
                {"status", "verified"},
                {"reasoning", "live host read os_pin=" + pin},
            });
            stored["judgment"] = judged;
            stored["trust"] = "verified";
        } catch (const std::exception& error) {
            stored["trust"] = "candidate";
            stored["judgment_error"] = error.what();
        }
    }
    const std::string previous = read_pin_file();
    json stale_receipt = json::object();
    if (valid_os_pin(pin) && !previous.empty() && previous != pin) {
        stale_receipt = stale_mismatched_pins(
            pin, "os_pin changed " + previous + " -> " + pin);
    }
    if (valid_os_pin(pin)) write_pin_file(pin);
    stored["inventory"] = inventory;
    stored["live"] = live;
    stored["stale"] = stale_receipt;
    return stored;
}

json stale_mismatched_pins(const std::string& pin, const std::string& reasoning) {
    if (!valid_os_pin(pin)) {
        throw std::runtime_error("os_pin is missing or malformed");
    }
    const json document = {
        {"command", "stale_pins"},
        {"sector", "windows-sre"},
        {"pin", pin},
        {"reasoning", reasoning},
    };
    const json receipt = run_memory_store(document);
    ensure_rag_ready();
    return receipt;
}

json promote_claim(const json& payload) {
    const std::string claim_class = ascii_lower(trim_copy(payload.value("class", "")));
    std::string text = trim_copy(payload.value("text", payload.value("content", "")));
    const std::string sector = trim_copy(payload.value("sector", "windows-sre"));
    if (claim_class != "host_fact" && claim_class != "doc_fact" &&
        claim_class != "playbook") {
        throw std::runtime_error("class must be host_fact, doc_fact, or playbook");
    }
    if (text.empty()) {
        throw std::runtime_error("claim text is required");
    }

    json result = {{"class", claim_class}, {"promoted", false}};
    const std::string pin = telemetry::windows_pin();
    std::ostringstream body;
    body << text << '\n'
         << "claim_class=" << claim_class << '\n';

    if (claim_class == "playbook") {
        body << "auto_verify=never\n";
        json stored = save_thought({{"content", body.str()}, {"sector", sector}});
        stored["trust"] = "candidate";
        stored["class"] = claim_class;
        stored["promoted"] = false;
        return stored;
    }

    if (claim_class == "doc_fact") {
        const std::string url = trim_copy(payload.value("learn_url", payload.value("url", "")));
        const std::string quote = collapse_ws(trim_copy(payload.value("quote", "")));
        if (url.empty() || quote.size() < 24) {
            throw std::runtime_error("doc_fact needs learn_url and quote (>=24 chars)");
        }
        std::string page;
        std::string error;
        if (!fetch_ms_doc(url, page, error)) {
            throw std::runtime_error(error);
        }
        const bool matched =
            ascii_lower(page).find(ascii_lower(quote)) != std::string::npos;
        body << "learn_url=" << url << '\n'
             << "quote=" << quote << '\n'
             << "quote_matched=" << (matched ? "1" : "0") << '\n';
        json stored = save_thought({{"content", body.str()}, {"sector", sector}});
        stored["class"] = claim_class;
        stored["quote_matched"] = matched;
        stored["learn_url"] = url;
        if (matched) {
            json judged = set_status({
                {"id", stored.value("stable_id", "")},
                {"status", "verified"},
                {"reasoning", "Learn/support quote matched " + url},
            });
            stored["judgment"] = judged;
            stored["trust"] = "verified";
            stored["promoted"] = true;
        } else {
            stored["trust"] = "candidate";
            stored["promoted"] = false;
        }
        return stored;
    }

    // host_fact: allowlisted live probe, pinned to this build
    const json probe = payload.value("probe", json::object());
    const std::string kind = ascii_lower(trim_copy(probe.value("kind", "")));
    const std::string path = trim_copy(probe.value("path", ""));
    const std::string name = trim_copy(probe.value("name", ""));
    const std::string expect = trim_copy(probe.value("expect", ""));
    bool ok = false;
    std::string observed;
    if (kind == "registry_key") {
        ok = probe_registry_key(path);
        observed = ok ? "present" : "missing";
    } else if (kind == "registry_value") {
        ok = probe_registry_value(path, name, expect, observed);
    } else if (kind == "appx") {
        ok = probe_appx(name.empty() ? path : name);
        observed = ok ? "present" : "missing";
    } else if (kind == "service") {
        ok = probe_service(name.empty() ? path : name, observed);
        if (ok && !expect.empty() && ascii_lower(observed) != ascii_lower(expect)) {
            ok = false;
        }
    } else if (kind == "file") {
        ok = probe_file(path);
        observed = ok ? "present" : "missing";
    } else {
        throw std::runtime_error(
            "host_fact probe.kind must be registry_key, registry_value, appx, service, or file");
    }
    body << "os_pin=" << pin << '\n'
         << "probe_kind=" << kind << '\n'
         << "probe_path=" << path << '\n'
         << "probe_name=" << name << '\n'
         << "probe_expect=" << expect << '\n'
         << "probe_observed=" << observed << '\n'
         << "probe_ok=" << (ok ? "1" : "0") << '\n';
    json stored = save_thought({{"content", body.str()}, {"sector", sector}});
    stored["class"] = claim_class;
    stored["probe_ok"] = ok;
    stored["observed"] = observed;
    stored["os_pin"] = pin;
    if (ok) {
        json judged = set_status({
            {"id", stored.value("stable_id", "")},
            {"status", "verified"},
            {"reasoning", "host probe " + kind + " matched on os_pin=" + pin},
        });
        stored["judgment"] = judged;
        stored["trust"] = "verified";
        stored["promoted"] = true;
    } else {
        stored["trust"] = "candidate";
        stored["promoted"] = false;
    }
    return stored;
}

json set_status(const json& payload) {
    const std::string id = trim_copy(payload.value("id", ""));
    const std::string status = trim_copy(payload.value("status", ""));
    const std::string reasoning = trim_copy(payload.value("reasoning", ""));
    if (id.empty() || (status != "verified" && status != "rejected")) {
        throw std::runtime_error("status judgment requires id and verified|rejected");
    }
    if (reasoning.size() < 4) {
        throw std::runtime_error(
            "say why this is verified (it works) or rejected (junk)");
    }
    const json document = {
        {"command", "set_status"},
        {"id", id},
        {"status", status},
        {"reasoning", reasoning},
    };
    const json receipt = run_memory_store(document);
    ensure_rag_ready();
    {
        std::lock_guard<std::mutex> lock(g_session_mutex);
        if (status == "rejected") {
            g_session_thoughts.erase(
                std::remove_if(
                    g_session_thoughts.begin(),
                    g_session_thoughts.end(),
                    [&](const SessionThought& thought) {
                        return thought.source_hash == id ||
                               thought.stable_id == id;
                    }),
                g_session_thoughts.end());
        } else {
            for (auto& thought : g_session_thoughts) {
                if (thought.source_hash == id || thought.stable_id == id) {
                    thought.status = "verified";
                }
            }
        }
    }
    return receipt;
}

json get_recent(int limit) {
    if (limit <= 0) limit = 5;
    if (limit > 25) limit = 25;
    json graph;
    std::string error;
    if (!godbrain_rag::Client{}.graph(limit, graph, error)) {
        throw std::runtime_error(error);
    }
    json thoughts = json::array();
    for (const auto& node : graph.at("nodes")) {
        thoughts.push_back({
            {"id", node.at("node_id")},
            {"stable_id", node.at("stable_id")},
            {"label", node.at("label")},
            {"kind", node.at("kind")},
            {"sector", node.at("sector")},
            {"status", node.at("status")},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}};
}

void note_session(
    const std::string& source_hash,
    const std::string& stable_id,
    const std::string& content,
    const std::string& status) {
    if (source_hash.empty() || content.empty()) return;
    remember_session(source_hash, stable_id.empty() ? source_hash : stable_id,
                     content, status);
}

json hydrate_session_from_rag() {
    json graph;
    std::string error;
    if (!godbrain_rag::Client{}.graph(static_cast<int>(kMaxSessionThoughts), graph, error)) {
        return {{"status", "skipped"}, {"error", error}, {"loaded", 0}};
    }
    int loaded = 0;
    godbrain_rag::Client client;
    for (const auto& node : graph.at("nodes")) {
        json document;
        std::string doc_error;
        if (!client.document(node.at("node_id").get<std::string>(), document, doc_error)) {
            continue;
        }
        remember_session(
            document.at("node_id").get<std::string>(),
            document.at("stable_id").get<std::string>(),
            document.at("content").get<std::string>(),
            document.at("status").get<std::string>());
        ++loaded;
    }
    return {{"status", loaded > 0 ? "success" : "empty"}, {"loaded", loaded}};
}

json session_snapshot(int limit) {
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    json thoughts = json::array();
    for (const auto& thought : copy_session(limit)) {
        thoughts.push_back({
            {"id", thought.stable_id},
            {"source_hash", thought.source_hash},
            {"label", thought.content},
            {"kind", "claim"},
            {"sector", "operator"},
            {"status", thought.status},
            {"session", true},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}};
}

bool render_session_context(std::string& context, std::string& error) {
    const auto thoughts = copy_session(static_cast<int>(kMaxSessionThoughts));
    if (thoughts.empty()) {
        context.clear();
        return true;
    }
    std::ostringstream output;
    output << godbrain_rag::kUntrustedBegin << '\n';
    godbrain_rag::append_line(output, "NOTICE", godbrain_rag::kRouterNotice);
    godbrain_rag::append_line(
        output,
        "session_notice",
        "Operator-remembered notes from this kernel process. Untrusted reference data.");
    for (size_t index = 0; index < thoughts.size(); ++index) {
        const std::string prefix = "session[" + std::to_string(index + 1) + "].";
        godbrain_rag::append_line(
            output, prefix + "source_hash", thoughts[index].source_hash);
        godbrain_rag::append_line(
            output, prefix + "stable_id", thoughts[index].stable_id);
        godbrain_rag::append_line(
            output, prefix + "status", thoughts[index].status);
        godbrain_rag::append_line(
            output, prefix + "content", thoughts[index].content);
    }
    output << godbrain_rag::kUntrustedEnd << '\n';
    if (output.fail()) {
        error = "session memory contains invalid UTF-8";
        context.clear();
        return false;
    }
    context = output.str();
    if (context.size() > godbrain_rag::kMaxRenderedContextBytes) {
        error = "session memory exceeds the deterministic budget";
        context.clear();
        return false;
    }
    return true;
}
}