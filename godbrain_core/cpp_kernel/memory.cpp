#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "memory.h"
#include "rag_client.h"
#include "telemetry.h"
#include "host_observation.h"
#include "session_context.h"
#include "truth_assertion.h"
#include "evidence_maintenance.h"
#include "research_curation.h"

#include <windows.h>
#include <winhttp.h>
#include <winsvc.h>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "advapi32.lib")

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <ctime>
#include <initializer_list>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

namespace memory {
namespace {

std::string trim_copy(std::string value);
json set_status_impl(const json& payload, bool repair_projection);

constexpr size_t kMaxThoughtBytes = 32 * 1024;
constexpr size_t kMaxSessionThoughts = godbrain_session::kMaxThoughts;
constexpr DWORD kStoreTimeoutMs = 35000;

using SessionThought = godbrain_session::Thought;

std::mutex g_session_mutex;
std::vector<SessionThought> g_session_thoughts;
std::mutex g_observe_mutex;

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

void remember_session(SessionThought incoming) {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    g_session_thoughts.erase(
        std::remove_if(
            g_session_thoughts.begin(),
            g_session_thoughts.end(),
            [&](const SessionThought& thought) {
                return thought.source_hash == incoming.source_hash ||
                       thought.stable_id == incoming.stable_id;
            }),
        g_session_thoughts.end());
    g_session_thoughts.push_back(std::move(incoming));
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

godbrain_session::Resolution resolve_session(int limit, const godbrain_rag::Client& client) {
    const auto resolved = godbrain_session::resolve(
        copy_session(limit), client, telemetry::windows_pin);
    {
        std::lock_guard<std::mutex> lock(g_session_mutex);
        for (auto& cached : g_session_thoughts) {
            for (const auto& current : resolved.thoughts) {
                godbrain_session::bind_origin(cached, current);
            }
        }
    }
    for (const auto& omitted : resolved.omitted) {
        std::cerr << "[MEMORY] Withheld session origin "
                  << omitted.at("stable_id").get<std::string>() << ": "
                  << omitted.at("reason").get<std::string>() << std::endl;
    }
    return resolved;
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
    if (!out || !(out << pin << '\n').flush()) {
        throw std::runtime_error("Failed to write Windows pin checkpoint");
    }
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

[[noreturn]] void windows_error(const char* operation, DWORD code = GetLastError()) {
    throw std::runtime_error(std::string(operation) + " failed (Win32 " + std::to_string(code) + ")");
}

std::wstring utf8_to_wide(const std::string& text) {
    if (text.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (count == 0) windows_error("UTF-8 conversion");
    std::wstring wide(static_cast<size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
            static_cast<int>(text.size()), wide.data(), count) != count) {
        windows_error("UTF-8 conversion");
    }
    return wide;
}

std::string wide_to_utf8(const std::wstring& wide) {
    if (wide.empty()) return {};
    if (wide.find(L'\0') != std::wstring::npos) throw std::runtime_error("Embedded NUL in Windows observation");
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
        static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (count == 0) windows_error("Windows string conversion");
    std::string text(static_cast<size_t>(count), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
            static_cast<int>(wide.size()), text.data(), count, nullptr, nullptr) != count) {
        windows_error("Windows string conversion");
    }
    return text;
}

godbrain_truth::Document fetch_ms_doc(const std::string& requested_url) {
    const auto url = godbrain_truth::document_url(requested_url);
    const auto wide = utf8_to_wide(url);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &parts)) windows_error("Documentation URL parse");
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (parts.dwExtraInfoLength) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

    using HttpHandle = std::unique_ptr<void, decltype(&WinHttpCloseHandle)>;
    HttpHandle session(WinHttpOpen(L"GodBrain-Truth/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0), WinHttpCloseHandle);
    if (!session) windows_error("Documentation WinHttpOpen");
    if (!WinHttpSetTimeouts(session.get(), 5000, 5000, 10000, 10000)) windows_error("Documentation timeouts");
    HttpHandle connect(WinHttpConnect(session.get(), host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0),
        WinHttpCloseHandle);
    if (!connect) windows_error("Documentation WinHttpConnect");
    HttpHandle request(WinHttpOpenRequest(connect.get(), L"GET", path.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE), WinHttpCloseHandle);
    if (!request) windows_error("Documentation WinHttpOpenRequest");
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects))) {
        windows_error("Documentation redirect policy");
    }
    const ULONGLONG started = GetTickCount64();
    if (!WinHttpSendRequest(request.get(), WINHTTP_NO_ADDITIONAL_HEADERS, 0,
            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request.get(), nullptr)) windows_error("Documentation fetch");
    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusSize, WINHTTP_NO_HEADER_INDEX)) {
        windows_error("Documentation status");
    }
    // A 206 or redirect is not a complete snapshot of the requested document.
    if (statusCode != 200) throw std::runtime_error("Documentation HTTP " + std::to_string(statusCode));
    DWORD length = 0;
    DWORD lengthSize = sizeof(length);
    std::optional<size_t> expected;
    if (WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &length, &lengthSize, WINHTTP_NO_HEADER_INDEX)) {
        expected = length;
    } else if (GetLastError() != ERROR_WINHTTP_HEADER_NOT_FOUND) {
        windows_error("Documentation Content-Length");
    }
    std::array<wchar_t, 512> type{};
    DWORD typeSize = static_cast<DWORD>(sizeof(type));
    if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX,
            type.data(), &typeSize, WINHTTP_NO_HEADER_INDEX)) windows_error("Documentation Content-Type");
    std::wstring contentType(type.data(), typeSize / sizeof(wchar_t));
    while (!contentType.empty() && contentType.back() == L'\0') contentType.pop_back();
    const auto raw = godbrain_truth::read_document([&]() -> std::optional<std::string> {
        if (GetTickCount64() - started >= 30000) throw std::runtime_error("Documentation fetch deadline exceeded");
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request.get(), &avail)) windows_error("Documentation data query");
        if (avail == 0) return std::nullopt;
        const DWORD count = (std::min)(avail, DWORD{64 * 1024});
        std::string chunk(count, '\0');
        DWORD got = 0;
        if (!WinHttpReadData(request.get(), chunk.data(), count, &got)) windows_error("Documentation body read");
        if (got == 0) throw std::runtime_error("Documentation read ended before EOF");
        chunk.resize(got);
        return chunk;
    }, expected);
    return {raw, wide_to_utf8(contentType), true};
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
        "c:\\nvme\\gemma4-12b-hauhau\\",
        "c:\\nvme\\llama-cpp\\",
    };
    for (const char* prefix : prefixes) {
        if (lower.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

godbrain_truth::Observation probe_registry_key(const std::string& path) {
    const auto wide = utf8_to_wide(path);
    HKEY key = nullptr;
    const LONG rc = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE, wide.c_str(), 0, KEY_READ | KEY_WOW64_64KEY, &key);
    if (rc != ERROR_SUCCESS) windows_error("HKLM key observation", static_cast<DWORD>(rc));
    RegCloseKey(key);
    return {true, "present", {{"hive", "HKLM"}, {"view", "64-bit"}}};
}

godbrain_truth::Observation probe_registry_value(const std::string& path, const std::string& name) {
    const auto wpath = utf8_to_wide(path);
    const auto wname = utf8_to_wide(name);
    std::array<wchar_t, 1024> buffer{};
    DWORD bytes = static_cast<DWORD>(sizeof(buffer));
    DWORD type = 0;
    const LONG rc = RegGetValueW(
        HKEY_LOCAL_MACHINE, wpath.c_str(), wname.c_str(),
        RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_RT_REG_DWORD |
            RRF_NOEXPAND | RRF_SUBKEY_WOW6464KEY, &type, buffer.data(), &bytes);
    if (rc != ERROR_SUCCESS) windows_error("HKLM value observation", static_cast<DWORD>(rc));
    std::string value;
    std::string typeName;
    if (type == REG_DWORD && bytes == sizeof(DWORD)) {
        DWORD number = 0;
        std::memcpy(&number, buffer.data(), sizeof(number));
        value = std::to_string(number);
        typeName = "REG_DWORD";
    } else if ((type == REG_SZ || type == REG_EXPAND_SZ) &&
               bytes >= sizeof(wchar_t) && bytes % sizeof(wchar_t) == 0 &&
               buffer[bytes / sizeof(wchar_t) - 1] == L'\0') {
        value = wide_to_utf8(std::wstring(buffer.data(), bytes / sizeof(wchar_t) - 1));
        typeName = type == REG_SZ ? "REG_SZ" : "REG_EXPAND_SZ";
    } else {
        throw std::runtime_error("Unsupported or malformed registry value");
    }
    return {true, value, {{"hive", "HKLM"}, {"view", "64-bit"},
        {"value_type", typeName}, {"expansion", "none"}, {"comparison", "exact"}}};
}

godbrain_truth::Observation probe_appx(const std::string& name) {
    const wchar_t* roots[] = {
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications",
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Applications",
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Deprovisioned",
    };
    for (const wchar_t* root : roots) {
        HKEY key = nullptr;
        const LONG opened = RegOpenKeyExW(
            HKEY_LOCAL_MACHINE, root, 0, KEY_READ | KEY_WOW64_64KEY, &key);
        if (opened == ERROR_FILE_NOT_FOUND) continue;
        if (opened != ERROR_SUCCESS) windows_error("AppX registry observation", static_cast<DWORD>(opened));
        const std::unique_ptr<std::remove_pointer_t<HKEY>, decltype(&RegCloseKey)> handle(key, RegCloseKey);
        for (DWORD i = 0; i < 4096; ++i) {
            wchar_t child[512]{};
            DWORD len = 512;
            const LONG rc = RegEnumKeyExW(handle.get(), i, child, &len, nullptr, nullptr, nullptr, nullptr);
            if (rc == ERROR_NO_MORE_ITEMS) break;
            if (rc != ERROR_SUCCESS) windows_error("AppX registry enumeration", static_cast<DWORD>(rc));
            const auto entry = wide_to_utf8(std::wstring(child, len));
            if (ascii_lower(entry).find(ascii_lower(name)) != std::string::npos) {
                return {true, "present", {
                    {"hive", "HKLM"}, {"view", "64-bit"}, {"registry_path", wide_to_utf8(root)},
                    {"matching_subkey", entry}, {"match", "ASCII-case-insensitive substring"},
                    {"meaning", "registry entry only; not installed-package state"}
                }};
            }
            if (i == 4095) throw std::runtime_error("AppX registry enumeration exceeds bound");
        }
    }
    throw std::runtime_error("No matching AppX registry entry was established");
}

godbrain_truth::Observation probe_service(const std::string& name) {
    const auto wide = utf8_to_wide(name);
    using ServiceHandle = std::unique_ptr<std::remove_pointer_t<SC_HANDLE>, decltype(&CloseServiceHandle)>;
    ServiceHandle scm(OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT), CloseServiceHandle);
    if (!scm) windows_error("SCM observation");
    ServiceHandle svc(OpenServiceW(scm.get(), wide.c_str(), SERVICE_QUERY_STATUS), CloseServiceHandle);
    if (!svc) windows_error("Service observation");
    SERVICE_STATUS_PROCESS ssp{};
    DWORD needed = 0;
    const BOOL ok = QueryServiceStatusEx(
        svc.get(), SC_STATUS_PROCESS_INFO, reinterpret_cast<LPBYTE>(&ssp),
        sizeof(ssp), &needed);
    if (!ok) windows_error("Service state observation");
    std::string state;
    switch (ssp.dwCurrentState) {
        case SERVICE_STOPPED: state = "stopped"; break;
        case SERVICE_START_PENDING: state = "start_pending"; break;
        case SERVICE_STOP_PENDING: state = "stop_pending"; break;
        case SERVICE_RUNNING: state = "running"; break;
        case SERVICE_CONTINUE_PENDING: state = "continue_pending"; break;
        case SERVICE_PAUSE_PENDING: state = "pause_pending"; break;
        case SERVICE_PAUSED: state = "paused"; break;
        default: throw std::runtime_error("Unrecognized SCM service state");
    }
    return {true, state, {{"service_state", ssp.dwCurrentState}}};
}

godbrain_truth::Observation probe_file(const std::string& path) {
    if (path.size() < 3 || path[1] != ':' || path[2] != '\\' ||
        path.find_first_of("*?") != std::string::npos || path.find(':', 2) != std::string::npos) {
        throw std::runtime_error("File observation needs an absolute allowlisted path");
    }
    const auto wide = utf8_to_wide(path);
    std::array<wchar_t, 32768> full{};
    const DWORD length = GetFullPathNameW(wide.c_str(), static_cast<DWORD>(full.size()), full.data(), nullptr);
    if (length == 0) windows_error("File path observation");
    if (length >= full.size()) throw std::runtime_error("File path exceeds bound");
    if (!path_under_allowlist(wide_to_utf8(std::wstring(full.data(), length)))) {
        throw std::runtime_error("File observation path is not allowlisted");
    }
    const HANDLE opened = CreateFileW(full.data(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (opened == INVALID_HANDLE_VALUE) windows_error("File metadata observation");
    const std::unique_ptr<void, decltype(&CloseHandle)> file(opened, CloseHandle);
    std::array<wchar_t, 32768> finalPath{};
    const DWORD finalLength = GetFinalPathNameByHandleW(file.get(), finalPath.data(),
        static_cast<DWORD>(finalPath.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (finalLength == 0) windows_error("File final-path observation");
    if (finalLength >= finalPath.size()) throw std::runtime_error("File final path exceeds bound");
    std::string final = wide_to_utf8(std::wstring(finalPath.data(), finalLength));
    if (final.rfind("\\\\?\\", 0) == 0) final.erase(0, 4);
    if (!path_under_allowlist(final)) throw std::runtime_error("File target escapes observation allowlist");
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(file.get(), &info)) windows_error("File attributes observation");
    const DWORD attributes = info.dwFileAttributes;
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) throw std::runtime_error("File observation target is a directory");
    return {true, "present", {{"full_path", wide_to_utf8(std::wstring(full.data(), length))},
        {"final_path", final}, {"attributes", attributes},
        {"meaning", "non-directory entry; contents not checked"}}};
}

godbrain_truth::Observation read_host_probe(const godbrain_truth::Probe& probe) {
    if (probe.kind == "registry_key") return probe_registry_key(probe.path);
    if (probe.kind == "registry_value") return probe_registry_value(probe.path, probe.name);
    if (probe.kind == "appx") return probe_appx(probe.name);
    if (probe.kind == "service") return probe_service(probe.name);
    if (probe.kind == "file") return probe_file(probe.path);
    throw std::runtime_error("Unsupported host observation");
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
        dir + "\\..\\..\\build\\cpp_memory_store\\Release\\memory-store.exe",
        dir + "\\..\\cpp_memory_store\\memory-store.exe",
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

json commit_candidate(const json& document, bool repair_projection = true) {
    const auto& claim = document.at("payload").at("claims").at(0);
    const std::string content = claim.at("content").get<std::string>();
    const std::string sector = claim.at("type").get<std::string>();
    const std::string raw = document.at("raw_transcript").get<std::string>();
    if (looks_like_secret(content) || looks_like_secret(raw)) {
        throw std::runtime_error("candidate evidence looks like a secret and was rejected");
    }
    if (document.dump().size() > godbrain_truth::kMaxWireBytes) {
        throw std::runtime_error("candidate exceeds memory-store input limit");
    }
    std::cout << "[MEMORY] Committing candidate via memory-store ("
              << content.size() << " content bytes, " << raw.size() << " source bytes)" << std::endl;
    const json receipt = run_memory_store(document);
    const std::string status = receipt.value("status", "");
    if (status != "committed" && status != "idempotent_noop") {
        throw std::runtime_error("memory-store rejected candidate: " + receipt.dump());
    }
    const auto source_hash = document.at("payload").at("provenance").at("source_hash").get<std::string>();
    const auto stable_id = claim_stable_id(sector, content);
    remember_session(godbrain_session::local_note(source_hash, stable_id, content, "candidate", sector));
    if (repair_projection) ensure_rag_ready();
    return {
        {"status", "success"}, {"run_id", receipt.value("run_id", "")},
        {"record_id", receipt.value("record_id", "")}, {"store_status", status},
        {"source_hash", source_hash}, {"stable_id", stable_id},
    };
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
    std::string source_type =
        trim_copy(payload.value("source_type", "operator_thought"));
    if (source_type.empty()) source_type = "operator_thought";
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
            {"source_type", source_type},
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

    return commit_candidate(document);
}

json observe_host() {
    std::lock_guard<std::mutex> lock(g_observe_mutex);
    const json inventory = telemetry::get_host_inventory();
    const json live = telemetry::get_current_state();
    return godbrain_host::observe(
        inventory, live, read_pin_file(), save_thought, set_status,
        stale_mismatched_pins, write_pin_file);
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
    return godbrain_truth::promote(payload, fetch_ms_doc, read_host_probe,
        telemetry::windows_pin, save_thought,
        [](const json& document) { return commit_candidate(document); }, set_status);
}

json evidence_status() {
    return run_memory_store({{"command", "evidence"}, {"action", "status"}});
}

json maintain_evidence() {
    static std::mutex maintenance_mutex;
    std::unique_lock<std::mutex> lock(maintenance_mutex, std::try_to_lock);
    if (!lock.owns_lock()) return {{"status", "busy"}, {"checks", json::array()}};
    const auto start = GetTickCount64();
    json results = json::array();
    for (int count = 0; count < 4 && GetTickCount64() - start < 45000; ++count) {
        const auto leased = run_memory_store({{"command", "evidence"}, {"action", "next"}});
        if (leased.value("status", "") == "idle") break;
        if (leased.value("status", "") != "leased")
            throw std::runtime_error("invalid evidence lease receipt");
        const auto& job = leased.at("job");
        json completion;
        try {
            completion = godbrain_evidence::check(
                job, fetch_ms_doc, read_host_probe, telemetry::windows_pin,
                telemetry::get_host_inventory,
                [](const json& document) {
                    return godbrain_truth::publish_assertion(document,
                        [](const json& candidate) { return commit_candidate(candidate, false); },
                        [](const json& judgment) { return set_status_impl(judgment, false); });
                });
        } catch (const std::exception& error) {
            std::cerr << "[MEMORY] Evidence check " << job.at("_id") << ": " << error.what() << '\n';
            completion = godbrain_evidence::result(job, "unavailable", "check_failed");
        }
        results.push_back(run_memory_store(completion));
    }
    return {{"status", "ok"}, {"checks", results}, {"summary", evidence_status()}};
}

namespace {
std::string research_path() {
    const auto dir = exe_dir();
    if (dir.empty()) throw std::runtime_error("cannot locate research frontier");
    return dir + "\\research-frontier.json";
}

json read_research() {
    const auto path = research_path();
    const DWORD attributes = GetFileAttributesA(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        const DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) return godbrain_research::initial_state();
        windows_error("Research frontier attributes", error);
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot read research frontier");
    std::string body;
    std::array<char, 8192> buffer{};
    while (in) {
        in.read(buffer.data(), buffer.size());
        body.append(buffer.data(), static_cast<size_t>(in.gcount()));
        if (body.size() > godbrain_research::kMaxStateBytes)
            throw std::runtime_error("research frontier exceeds size limit");
    }
    if (in.bad()) throw std::runtime_error("research frontier read failed");
    auto state = godbrain_research::strict_json(body, godbrain_research::kMaxStateBytes);
    godbrain_research::validate_state(state);
    return state;
}

void write_research(const json& state) {
    godbrain_research::validate_state(state);
    const auto body = state.dump();
    if (body.size() > godbrain_research::kMaxStateBytes)
        throw std::runtime_error("research frontier exceeds size limit");
    const auto path = research_path();
    const auto temporary = path + ".tmp";
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out || !(out << body).flush())
            throw std::runtime_error("research frontier write failed");
    }
    if (!MoveFileExA(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        windows_error("Research frontier atomic replacement");
}

json research_references(const std::string& query) {
    if (!rag_projection_ready())
        throw std::runtime_error("canonical research RAG is not ready");
    godbrain_rag::Client client;
    json found;
    std::string error;
    if (!client.search(query, 5, found, error)) {
        if (error.find("no usable context") != std::string::npos && found.is_object() &&
            found.contains("results") && found.at("results").is_array() &&
            found.at("results").empty())
            return json::array();
        throw std::runtime_error(error);
    }
    json references = json::array();
    for (const auto& hit : found.at("results")) {
        if (hit.at("sector") != "windows-sre") continue;
        json document;
        if (!client.document(hit.at("node_id").get<std::string>(), document, error))
            throw std::runtime_error(error);
        if (document.at("status") != "verified" || document.at("sector") != "windows-sre" ||
            document.at("stable_id") != hit.at("stable_id") ||
            document.at("node_version") != hit.at("node_version"))
            throw std::runtime_error("canonical research reference changed or lost authority");
        references.push_back({{"id", document.at("stable_id")},
                              {"content", document.at("content")}});
    }
    return references;
}
} // namespace

json research_status() {
    return godbrain_research::summary(read_research());
}

json research_tick(const std::function<std::string(const json&)>& infer,
                   const std::string& model_id) {
    static std::mutex research_mutex;
    std::unique_lock<std::mutex> lock(research_mutex, std::try_to_lock);
    if (!lock.owns_lock()) return {{"status", "busy"}};
    auto state = read_research();
    godbrain_research::Operations operations;
    operations.persist = write_research;
    operations.discover = [](const std::string& url) {
        const auto document = fetch_ms_doc(url);
        if (!document.complete || document.mime() != "application/json")
            throw std::runtime_error("Learn discovery did not return complete JSON");
        return godbrain_research::strict_json(document.body, godbrain_truth::kMaxDocumentBytes);
    };
    operations.fetch = fetch_ms_doc;
    operations.references = research_references;
    operations.infer = infer;
    operations.publish = [&](const json& input, const godbrain_truth::Document& source,
                             const json& result) {
        return godbrain_research::publish_selection(
            input, source, result, model_id,
            [](const json& candidate) { return commit_candidate(candidate, false); },
            [](const json& judgment) { return set_status_impl(judgment, false); });
    };
    const auto now = static_cast<int64_t>(std::time(nullptr));
    auto receipt = godbrain_research::tick(state, now, operations);
    receipt["summary"] = godbrain_research::summary(state);
    if (receipt.contains("error"))
        std::cerr << "[MEMORY] Research retry: " << receipt.dump() << '\n';
    return receipt;
}

namespace {
json set_status_impl(const json& payload, bool repair_projection) {
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
    {
        std::lock_guard<std::mutex> lock(g_session_mutex);
        if (status == "rejected") {
            g_session_thoughts.erase(
                std::remove_if(
                    g_session_thoughts.begin(),
                    g_session_thoughts.end(),
                    [&](const SessionThought& thought) {
                        return godbrain_session::matches(thought, id);
                    }),
                g_session_thoughts.end());
        } else {
            for (auto& thought : g_session_thoughts) {
                if (godbrain_session::matches(thought, id)) {
                    godbrain_session::require_origin(thought);
                }
            }
        }
    }
    if (repair_projection) ensure_rag_ready();
    return receipt;
}
} // namespace

json set_status(const json& payload) {
    return set_status_impl(payload, true);
}

json copy_store_fields(const json& payload, const char* command,
                       std::initializer_list<const char*> keys) {
    json document = {{"command", command}};
    for (const char* key : keys) {
        if (payload.contains(key)) {
            document[key] = payload[key];
        }
    }
    return document;
}

json record_skill_run(const json& payload) {
    return run_memory_store(copy_store_fields(
        payload, "record_skill_run",
        {"skill_name", "origin_node_id", "fixture_id", "suite_id",
         "verification_profile", "verification_version", "environment_hash",
         "result", "checks", "artifact_hash", "log_excerpt", "reasoning"}));
}

json promote_skill(const json& payload) {
    const std::string reasoning = trim_copy(payload.value("reasoning", ""));
    if (reasoning.size() < 4) {
        throw std::runtime_error("promote_skill requires a why (harness passed / look is right)");
    }
    json document = copy_store_fields(
        payload, "promote_skill",
        {"name", "content", "origin_node_id", "origin_version", "origin_hash",
         "schema_version", "verification_profile"});
    document["reasoning"] = reasoning;
    return run_memory_store(document);
}

json query_skills(const json& payload) {
    json document = {
        {"command", "query_skills"},
        {"query", payload.value("query", "")},
        {"limit", payload.value("limit", 5)},
    };
    return run_memory_store(document);
}

json search_verified(const std::string& query, int limit) {
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    json response;
    std::string error;
    if (!godbrain_rag::Client{}.search(query, limit, response, error)) {
        if (error.find("no usable context") != std::string::npos) {
            return {{"status", "success"},
                    {"thoughts", json::array()},
                    {"query", query}};
        }
        throw std::runtime_error(error);
    }
    json thoughts = json::array();
    for (const auto& hit : response.at("results")) {
        thoughts.push_back({
            {"id", hit.value("stable_id", hit.value("node_id", ""))},
            {"stable_id", hit.value("stable_id", "")},
            {"label", hit.value("snippet", "")},
            {"kind", hit.value("kind", "claim")},
            {"sector", hit.value("sector", "")},
            {"status", hit.value("status", "verified")},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}, {"query", query}};
}

json search_verified(const std::string& query, int limit, const std::string& sector) {
    json found = search_verified(query, 25);
    if (sector.empty()) return found;
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    json kept = json::array();
    for (const auto& thought : found.value("thoughts", json::array())) {
        if (thought.value("sector", "") != sector) continue;
        kept.push_back(thought);
        if (static_cast<int>(kept.size()) >= limit) break;
    }
    found["thoughts"] = std::move(kept);
    return found;
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

json get_recent_personal(int limit) {
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    const json recent = get_recent(25);
    json thoughts = json::array();
    for (const auto& thought : recent.value("thoughts", json::array())) {
        if (thought.value("sector", "") != "personal") continue;
        thoughts.push_back(thought);
        if (static_cast<int>(thoughts.size()) >= limit) break;
    }
    return {{"status", "success"}, {"thoughts", thoughts}};
}

void note_session(
    const std::string& source_hash,
    const std::string& stable_id,
    const std::string& content,
    const std::string& status) {
    if (source_hash.empty() || content.empty()) return;
    remember_session(godbrain_session::local_note(
        source_hash, stable_id.empty() ? source_hash : stable_id, content, status));
}

json hydrate_session_from_rag() {
    return hydrate_session_from_rag(godbrain_rag::Client{});
}

json hydrate_session_from_rag(const godbrain_rag::Client& client) {
    json graph;
    std::string error;
    if (!client.graph(static_cast<int>(kMaxSessionThoughts), graph, error)) {
        return {{"status", "skipped"}, {"error", error}, {"loaded", 0}};
    }
    int loaded = 0;
    json omitted = json::array();
    for (const auto& node : graph.at("nodes")) {
        if (node.at("status") != "verified" || node.at("sector") == "personal") continue;
        json document;
        std::string doc_error;
        if (!client.document(node.at("node_id").get<std::string>(), document, doc_error)) {
            omitted.push_back({{"stable_id", node.at("stable_id")}, {"reason", doc_error}});
            std::cerr << "[MEMORY] Session hydrate withheld origin: " << doc_error << std::endl;
            continue;
        }
        if (document.at("node_id") != node.at("node_id") ||
            document.at("stable_id") != node.at("stable_id") ||
            document.at("status") != "verified" || document.at("sector") == "personal") {
            const std::string reason = "origin identity or technical eligibility changed";
            omitted.push_back({{"stable_id", node.at("stable_id")}, {"reason", reason}});
            std::cerr << "[MEMORY] Session hydrate withheld origin: " << reason << std::endl;
            continue;
        }
        remember_session(godbrain_session::rag_note(document));
        ++loaded;
    }
    return {{"status", loaded > 0 ? "success" : "empty"}, {"loaded", loaded},
            {"omitted", omitted}};
}

json session_snapshot(int limit) {
    return session_snapshot(limit, godbrain_rag::Client{});
}

json session_snapshot(int limit, const godbrain_rag::Client& client) {
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    json thoughts = json::array();
    const auto resolved = resolve_session(limit, client);
    for (const auto& thought : resolved.thoughts) {
        thoughts.push_back({
            {"id", thought.stable_id},
            {"source_hash", thought.source_hash},
            {"label", thought.content},
            {"kind", thought.kind},
            {"sector", thought.sector},
            {"status", thought.status},
            {"origin", thought.origin == godbrain_session::Origin::Rag ? "rag" : "local"},
            {"session", true},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}, {"omitted", resolved.omitted}};
}

bool render_session_context(std::string& context, std::string& error) {
    return render_session_context(context, error, godbrain_rag::Client{});
}

bool render_session_context(
    std::string& context, std::string& error, const godbrain_rag::Client& client) {
    return godbrain_session::render(
        resolve_session(static_cast<int>(kMaxSessionThoughts), client), context, error);
}
}