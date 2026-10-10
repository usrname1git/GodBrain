#include "phone_desk.h"
#include "telemetry.h"
#include <windows.h>
#include <tlhelp32.h>
#include <iphlpapi.h>
#include <algorithm>
#include <cstddef>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace phone_desk {
namespace {
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
struct ServiceHandle {
    SC_HANDLE value = nullptr;
    ~ServiceHandle() { if (value) CloseServiceHandle(value); }
};
struct Reap {
    HANDLE process;
    HANDLE job;
    ~Reap() {
        if (WaitForSingleObject(process, 0) != WAIT_OBJECT_0) {
            if (job) TerminateJobObject(job, 1);
            TerminateProcess(process, 1);
            WaitForSingleObject(process, 3000);
        }
    }
};

std::runtime_error win_error(const char* operation) {
    return std::runtime_error(std::string(operation) + " (Windows error " +
                              std::to_string(GetLastError()) + ")");
}

std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, text.data(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (length <= 0) throw win_error("Text conversion failed");
    std::string result(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                       result.data(), length, nullptr, nullptr);
    return result;
}

std::wstring program_files() {
    wchar_t path[32768] = {};
    DWORD size = GetEnvironmentVariableW(L"ProgramFiles", path, 32768);
    if (!size || size >= 32768) throw win_error("Program Files path unavailable");
    return path;
}

json card(const std::string& name, const std::string& state,
          const std::string& detail) {
    return {{"name", name}, {"state", state}, {"detail", detail}};
}

json service(const wchar_t* name) {
    ServiceHandle manager{OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT)};
    if (!manager.value) throw win_error("Service manager query failed");
    ServiceHandle handle{OpenServiceW(manager.value, name, SERVICE_QUERY_STATUS)};
    if (!handle.value) {
        if (GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST)
            return {{"state", "missing"}, {"pid", 0}};
        throw win_error("Service query failed");
    }
    SERVICE_STATUS_PROCESS status{};
    DWORD bytes = 0;
    if (!QueryServiceStatusEx(handle.value, SC_STATUS_PROCESS_INFO,
        reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes))
        throw win_error("Service state query failed");
    const char* state = "unknown";
    switch (status.dwCurrentState) {
        case SERVICE_RUNNING: state = "running"; break;
        case SERVICE_STOPPED: state = "stopped"; break;
        case SERVICE_START_PENDING: state = "starting"; break;
        case SERVICE_STOP_PENDING: state = "stopping"; break;
        case SERVICE_PAUSED: state = "paused"; break;
        case SERVICE_PAUSE_PENDING: case SERVICE_CONTINUE_PENDING:
            state = "transitioning"; break;
    }
    return {{"state", state}, {"pid", status.dwProcessId}};
}

struct ServiceConfig {
    std::wstring binary_path;
    std::wstring account;
};

ServiceConfig service_config(SC_HANDLE handle) {
    DWORD bytes = 0;
    QueryServiceConfigW(handle, nullptr, 0, &bytes);
    if (bytes < sizeof(QUERY_SERVICE_CONFIGW) || bytes > 65536)
        throw std::runtime_error("Service configuration size is invalid");
    std::vector<unsigned char> data(bytes);
    auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(data.data());
    if (!QueryServiceConfigW(handle, config, bytes, &bytes))
        throw win_error("Service configuration query failed");
    return {config->lpBinaryPathName ? config->lpBinaryPathName : L"",
            config->lpServiceStartName ? config->lpServiceStartName : L""};
}

std::wstring image_path(HANDLE process) {
    wchar_t path[32768] = {};
    DWORD size = 32768;
    if (!QueryFullProcessImageNameW(process, 0, path, &size))
        throw win_error("Backend executable query failed");
    return std::wstring(path, size);
}

std::wstring command_line(HANDLE process) {
    using Query = LONG (WINAPI*)(HANDLE, ULONG, void*, ULONG, ULONG*);
    auto query = reinterpret_cast<Query>(GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess"));
    if (!query) throw std::runtime_error("Backend command query unavailable");
    ULONG needed = 0;
    query(process, 60, nullptr, 0, &needed);
    if (needed < sizeof(USHORT) * 2 + sizeof(void*) || needed > 65536)
        throw std::runtime_error("Backend command size is invalid");
    std::vector<unsigned char> data(needed);
    if (query(process, 60, data.data(), needed, &needed) < 0)
        throw std::runtime_error("Backend command query denied");
    struct UnicodeString { USHORT length, maximum; wchar_t* buffer; };
    const auto* text = reinterpret_cast<const UnicodeString*>(data.data());
    const auto first = reinterpret_cast<uintptr_t>(data.data());
    const auto pointer = reinterpret_cast<uintptr_t>(text->buffer);
    if ((text->length % sizeof(wchar_t)) || pointer < first ||
        pointer > first + data.size() || text->length > first + data.size() - pointer)
        throw std::runtime_error("Backend command response is invalid");
    return std::wstring(text->buffer, text->length / sizeof(wchar_t));
}

bool system_owned(HANDLE process) {
    Handle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token.value))
        throw win_error("Backend owner query failed");
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size || size > 16384) throw std::runtime_error("Backend owner response is invalid");
    std::vector<unsigned char> data(size);
    if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size))
        throw win_error("Backend owner query failed");
    return IsWellKnownSid(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,
                          WinLocalSystemSid) != FALSE;
}

bool rustdesk_backend(DWORD parent) {
    ServiceHandle manager{OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT)};
    if (!manager.value) throw win_error("RustDesk service manager query failed");
    ServiceHandle service_handle{OpenServiceW(manager.value, L"RustDesk",
        SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG)};
    if (!service_handle.value) throw win_error("RustDesk service query failed");
    const std::wstring expected = program_files() + L"\\RustDesk\\rustdesk.exe";
    const ServiceConfig config = service_config(service_handle.value);
    const std::wstring expected_command = L"\"" + expected + L"\" --service";
    if (_wcsicmp(config.account.c_str(), L"LocalSystem") ||
        _wcsicmp(config.binary_path.c_str(), expected_command.c_str())) return false;
    Handle parent_process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, parent)};
    if (!parent_process.value) throw win_error("RustDesk service process query failed");
    if (_wcsicmp(image_path(parent_process.value).c_str(), expected.c_str()) ||
        WaitForSingleObject(parent_process.value, 0) != WAIT_TIMEOUT) return false;
    FILETIME parent_created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(parent_process.value, &parent_created, &exited, &kernel, &user))
        throw win_error("RustDesk service lifetime query failed");
    Handle list{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
    if (list.value == INVALID_HANDLE_VALUE) throw win_error("Process snapshot failed");
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(list.value, &entry)) throw win_error("Process snapshot is unreadable");
    do {
        if (entry.th32ParentProcessID != parent ||
            _wcsicmp(entry.szExeFile, L"rustdesk.exe")) continue;
        Handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, entry.th32ProcessID)};
        if (!process.value) throw win_error("Backend process query failed");
        if (_wcsicmp(image_path(process.value).c_str(), expected.c_str())) continue;
        const std::wstring command = command_line(process.value);
        const auto at = command.find(L" --server");
        if (at == std::wstring::npos) continue;
        const auto end = at + 9;
        if (end < command.size() && command[end] != L' ' && command[end] != L'\t') continue;
        FILETIME created{};
        if (!GetProcessTimes(process.value, &created, &exited, &kernel, &user))
            throw win_error("RustDesk server lifetime query failed");
        if (CompareFileTime(&created, &parent_created) < 0 ||
            WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) continue;
        SERVICE_STATUS_PROCESS current{};
        DWORD bytes = 0;
        if (!QueryServiceStatusEx(service_handle.value, SC_STATUS_PROCESS_INFO,
            reinterpret_cast<BYTE*>(&current), sizeof(current), &bytes))
            throw win_error("RustDesk service recheck failed");
        return current.dwCurrentState == SERVICE_RUNNING && current.dwProcessId == parent;
    } while (Process32NextW(list.value, &entry));
    return false;
}

std::string read_probe() {
    const std::wstring executable = program_files() + L"\\Tailscale\\tailscale.exe";
    std::wstring command = L"\"" + executable + L"\" status --json";
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    Handle reader, writer;
    if (!CreatePipe(&reader.value, &writer.value, &attributes, 0))
        throw win_error("Tailscale status pipe failed");
    if (!SetHandleInformation(reader.value, HANDLE_FLAG_INHERIT, 0))
        throw win_error("Tailscale status pipe inheritance failed");
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
    std::vector<unsigned char> storage(size);
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdOutput = writer.value;
    startup.StartupInfo.hStdError = writer.value;
    startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &size))
        throw win_error("Tailscale status handle list failed");
    const bool updated = UpdateProcThreadAttribute(startup.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &writer.value, sizeof(HANDLE), nullptr, nullptr) != FALSE;
    PROCESS_INFORMATION info{};
    BOOL started = FALSE;
    if (updated) started = CreateProcessW(executable.c_str(), command.data(),
        nullptr, nullptr, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, nullptr, &startup.StartupInfo, &info);
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    if (!started) throw win_error("Tailscale status process failed");
    Handle process{info.hProcess}, thread{info.hThread}, job{CreateJobObjectW(nullptr, nullptr)};
    Reap reap{process.value, job.value};
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job.value || !SetInformationJobObject(job.value, JobObjectExtendedLimitInformation,
        &limits, sizeof(limits)) || !AssignProcessToJobObject(job.value, process.value)) {
        TerminateProcess(process.value, 1);
        WaitForSingleObject(process.value, 3000);
        throw win_error("Tailscale status process containment failed");
    }
    CloseHandle(writer.value);
    writer.value = nullptr;
    if (ResumeThread(thread.value) == static_cast<DWORD>(-1))
        throw win_error("Tailscale status process resume failed");
    const ULONGLONG deadline = GetTickCount64() + 2500;
    std::string output;
    bool exited = false;
    do {
        DWORD available = 0;
        if (PeekNamedPipe(reader.value, nullptr, 0, nullptr, &available, nullptr) && available) {
            char buffer[4096];
            DWORD bytes = 0;
            if (!ReadFile(reader.value, buffer, (std::min)(available, DWORD(sizeof(buffer))), &bytes, nullptr))
                throw win_error("Tailscale status read failed");
            output.append(buffer, bytes);
            if (output.size() > 1024 * 1024)
                throw std::runtime_error("Tailscale status exceeds its size limit");
        } else {
            if (exited) break;
            Sleep(10);
        }
        exited = WaitForSingleObject(process.value, 0) == WAIT_OBJECT_0;
        if (GetTickCount64() >= deadline)
            throw std::runtime_error("Tailscale status query timed out");
    } while (true);
    DWORD code = 1;
    if (!GetExitCodeProcess(process.value, &code) || code != 0)
        throw std::runtime_error("Tailscale status query failed");
    return output;
}

json read_tailscale() {
    const json parsed = json::parse(read_probe(), nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object())
        throw std::runtime_error("Tailscale status response is invalid");
    return parsed;
}

json get_json(int port, const char* path) {
    httplib::Client client("127.0.0.1", port);
    client.set_connection_timeout(0, 250000);
    client.set_read_timeout(1, 0);
    client.set_write_timeout(1, 0);
    std::string body;
    const auto response = client.Get(path, [&](const char* data, size_t length) {
        if (body.size() + length > 65536) return false;
        body.append(data, length);
        return true;
    });
    if (!response) throw std::runtime_error("Endpoint unavailable or timed out");
    if (response->status != 200)
        throw std::runtime_error("Endpoint returned HTTP " + std::to_string(response->status));
    const json parsed = json::parse(body, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object())
        throw std::runtime_error("Endpoint returned invalid JSON");
    return parsed;
}

json gpu_usage() {
    json result = {{"state", "unknown"}, {"used_mib", nullptr}, {"total_mib", nullptr}};
    HMODULE library = LoadLibraryExW(L"nvml.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library) {
        result["detail"] = "GPU memory sensor unavailable";
        return result;
    }
    using Init = int (__cdecl*)();
    using Device = int (__cdecl*)(unsigned, void**);
    struct Memory { unsigned long long total, free, used; };
    using Read = int (__cdecl*)(void*, Memory*);
    auto init = reinterpret_cast<Init>(GetProcAddress(library, "nvmlInit_v2"));
    auto shutdown = reinterpret_cast<Init>(GetProcAddress(library, "nvmlShutdown"));
    auto device = reinterpret_cast<Device>(GetProcAddress(library, "nvmlDeviceGetHandleByIndex_v2"));
    auto read = reinterpret_cast<Read>(GetProcAddress(library, "nvmlDeviceGetMemoryInfo"));
    if (init && shutdown && device && read && init() == 0) {
        void* handle = nullptr;
        Memory memory{};
        if (device(0, &handle) == 0 && read(handle, &memory) == 0) {
            result["state"] = "ready";
            result["used_mib"] = memory.used / (1024 * 1024);
            result["total_mib"] = memory.total / (1024 * 1024);
        }
        shutdown();
    }
    FreeLibrary(library);
    if (result["state"] != "ready") result["detail"] = "GPU memory query failed";
    return result;
}

json service_card(const wchar_t* name, const std::string& title) {
    try {
        const json status = service(name);
        return card(title, status["state"], "Windows service");
    } catch (const std::runtime_error& error) {
        return card(title, "unknown", error.what());
    }
}

json collect() {
    json models = json::array();
    for (int port : {8888, 8871, 8000}) {
        if (!telemetry::tcp_loopback_open(port, 150)) {
            json down = card("Model", "stopped", "No loopback listener");
            down["port"] = port;
            models.push_back(down);
            continue;
        }
        try {
            json health = json::object();
            if (port == 8871) {
                health = get_json(port, "/health");
                models.push_back(model_status(port, json::object(), health));
            } else {
                const json model = get_json(port, "/v1/models");
                try { health = get_json(port, "/health"); }
                catch (const std::runtime_error& error) { health["probe_error"] = error.what(); }
                models.push_back(model_status(port, model, health));
            }
        } catch (const std::runtime_error& error) {
            json unknown = card("Model", "unknown", error.what());
            unknown["port"] = port;
            models.push_back(unknown);
        }
    }
    const json rust = read_rustdesk_status();
    json tail;
    try { tail = tailscale_status(read_tailscale()); }
    catch (const std::runtime_error& error) { tail = card("Tailscale", "unknown", error.what()); }
    json ssh = service_card(L"sshd", "SSH");
    if (ssh["state"] == "running") {
        const bool open = telemetry::tcp_loopback_open(2222, 150);
        ssh["state"] = open ? "ready" : "unready";
        ssh["detail"] = open ? "Windows service + port 2222" : "Service running; port 2222 unavailable";
    }
    json rag;
    try {
        const json health = get_json(8084, "/health");
        if (!health.contains("ready") || !health["ready"].is_boolean())
            throw std::runtime_error("RAG readiness response is invalid");
        rag = card("Alexandria / RAG", health["ready"].get<bool>() ? "ready" : "unready",
                   "Canonical retrieval service");
    } catch (const std::runtime_error& error) { rag = card("Alexandria / RAG", "unknown", error.what()); }
    json mongo = service_card(L"MongoDB", "MongoDB");
    if (mongo["state"] == "running") {
        const bool open = telemetry::tcp_loopback_open(27017, 150);
        mongo["detail"] = open ? "Service + port 27017; no database commands run" : "Service running; port 27017 unavailable";
        if (!open) mongo["state"] = "unready";
    }
    json speech;
    if (!telemetry::tcp_loopback_open(8001, 150)) {
        speech = json::array({card("STT", "stopped", "Speech helper :8001 is stopped"),
                             card("TTS", "stopped", "Speech helper :8001 is stopped"),
                             card("CPU OCR", "stopped", "Speech helper :8001 is stopped")});
    } else {
        try { speech = speech_status(get_json(8001, "/health")); }
        catch (const std::runtime_error& error) {
            speech = json::array({card("STT", "unknown", error.what()),
                                 card("TTS", "unknown", error.what()),
                                 card("CPU OCR", "unknown", error.what())});
        }
    }
    SYSTEMTIME time{};
    GetSystemTime(&time);
    char timestamp[40];
    std::snprintf(timestamp, sizeof(timestamp), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
        static_cast<unsigned>(time.wYear), static_cast<unsigned>(time.wMonth),
        static_cast<unsigned>(time.wDay), static_cast<unsigned>(time.wHour),
        static_cast<unsigned>(time.wMinute), static_cast<unsigned>(time.wSecond),
        static_cast<unsigned>(time.wMilliseconds));
    return {{"schema_version", 1}, {"read_only", true}, {"sampled_at", timestamp},
            {"models", models}, {"gpu", gpu_usage()},
            {"services", json::array({rust, tail, ssh})},
            {"speech", speech},
            {"core", json::array({card("Kernel", "ready", "Phone Desk responds; no command dispatch"), rag, mongo})}};
}
}

bool authorized(const httplib::Request& request, const std::string& token,
                const std::string& login, bool trusted_proxy) {
    if (token.find_first_not_of(" \t\r\n") == std::string::npos ||
        request.remote_addr != "127.0.0.1" || !request.body.empty() ||
        !request.params.empty() || (request.method != "GET" && request.method != "HEAD") ||
        request.has_header("Content-Length") || request.has_header("Transfer-Encoding")) return false;
    const std::string header = request.get_header_value("Authorization");
    if (header.size() == token.size() + 7 && _strnicmp(header.c_str(), "Bearer ", 7) == 0) {
        unsigned char difference = 0;
        for (size_t i = 0; i < token.size(); ++i)
            difference |= static_cast<unsigned char>(header[i + 7] ^ token[i]);
        if (difference == 0) return true;
    }
    return trusted_proxy && !login.empty() && request.get_header_value("Tailscale-User-Login") == login;
}

bool trusted_serve_peer(const httplib::Request& request) {
    if (request.remote_addr != "127.0.0.1" || request.local_addr != "127.0.0.1" ||
        request.remote_port < 1 || request.remote_port > 65535 ||
        request.local_port < 1 || request.local_port > 65535) return false;
    try {
        ServiceHandle manager{OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT)};
        if (!manager.value) throw win_error("Proxy service manager query failed");
        ServiceHandle handle{OpenServiceW(manager.value, L"Tailscale", SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG)};
        if (!handle.value) throw win_error("Proxy service query failed");
        SERVICE_STATUS_PROCESS status{};
        DWORD bytes = 0;
        if (!QueryServiceStatusEx(handle.value, SC_STATUS_PROCESS_INFO,
            reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes))
            throw win_error("Proxy service status query failed");
        if (status.dwCurrentState != SERVICE_RUNNING || !status.dwProcessId) return false;
        const DWORD pid = status.dwProcessId;
        const ServiceConfig config = service_config(handle.value);
        const std::wstring expected = program_files() + L"\\Tailscale\\tailscaled.exe";
        const std::wstring prefix = L"\"" + expected + L"\"";
        const std::wstring& path = config.binary_path;
        if (_wcsicmp(config.account.c_str(), L"LocalSystem") ||
            path.size() < prefix.size() || _wcsnicmp(path.c_str(), prefix.c_str(), prefix.size()) ||
            (path.size() != prefix.size() && path[prefix.size()] != L' ')) return false;
        // Pin the live process while resolving the exact client-side TCP tuple.
        Handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid)};
        if (!process.value) throw win_error("Proxy process query failed");
        if (_wcsicmp(image_path(process.value).c_str(), expected.c_str()) ||
            WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) return false;
        bytes = 0;
        if (GetExtendedTcpTable(nullptr, &bytes, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) != ERROR_INSUFFICIENT_BUFFER ||
            bytes < sizeof(MIB_TCPTABLE_OWNER_PID) || bytes > 4 * 1024 * 1024)
            throw std::runtime_error("Proxy connection table size is invalid");
        std::vector<unsigned char> data(bytes);
        if (GetExtendedTcpTable(data.data(), &bytes, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR)
            throw std::runtime_error("Proxy connection ownership query failed");
        const auto* table = reinterpret_cast<const MIB_TCPTABLE_OWNER_PID*>(data.data());
        if (table->dwNumEntries > (bytes - offsetof(MIB_TCPTABLE_OWNER_PID, table)) / sizeof(MIB_TCPROW_OWNER_PID))
            throw std::runtime_error("Proxy connection table is invalid");
        DWORD peer_pid = 0;
        for (DWORD i = 0; i < table->dwNumEntries; ++i) {
            const auto& row = table->table[i];
            if (row.dwState == MIB_TCP_STATE_ESTAB &&
                row.dwLocalAddr == htonl(INADDR_LOOPBACK) && row.dwRemoteAddr == htonl(INADDR_LOOPBACK) &&
                row.dwLocalPort == htons(static_cast<u_short>(request.remote_port)) &&
                row.dwRemotePort == htons(static_cast<u_short>(request.local_port))) {
                if (peer_pid && peer_pid != row.dwOwningPid) return false;
                peer_pid = row.dwOwningPid;
            }
        }
        if (!peer_pid || WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) return false;
        Handle peer{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, peer_pid)};
        if (!peer.value) throw win_error("Proxy peer process query failed");
        if (_wcsicmp(image_path(peer.value).c_str(), expected.c_str()) || !system_owned(peer.value)) return false;
        if (peer_pid != pid) {
            // Tailscale's Windows service runs Serve in an immediate SYSTEM worker.
            Handle list{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
            if (list.value == INVALID_HANDLE_VALUE) throw win_error("Proxy worker snapshot failed");
            PROCESSENTRY32W entry{};
            entry.dwSize = sizeof(entry);
            if (!Process32FirstW(list.value, &entry)) throw win_error("Proxy worker snapshot unreadable");
            bool child = false;
            do {
                if (entry.th32ProcessID == peer_pid && entry.th32ParentProcessID == pid) child = true;
            } while (Process32NextW(list.value, &entry));
            FILETIME parent_created{}, peer_created{}, exited{}, kernel{}, user{};
            if (!GetProcessTimes(process.value, &parent_created, &exited, &kernel, &user) ||
                !GetProcessTimes(peer.value, &peer_created, &exited, &kernel, &user))
                throw win_error("Proxy worker lifetime query failed");
            if (!child || CompareFileTime(&peer_created, &parent_created) < 0) return false;
        }
        if (WaitForSingleObject(peer.value, 0) != WAIT_TIMEOUT) return false;
        if (!QueryServiceStatusEx(handle.value, SC_STATUS_PROCESS_INFO,
            reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes))
            throw win_error("Proxy service recheck failed");
        return status.dwCurrentState == SERVICE_RUNNING && status.dwProcessId == pid;
    } catch (const std::runtime_error& error) {
        std::cerr << "[PHONE] Proxy channel denied: " << error.what() << '\n';
        return false;
    }
}

std::string owner_login(const json& status) {
    if (!status.contains("Self") || !status["Self"].is_object() ||
        !status["Self"].contains("UserID") || !status["Self"]["UserID"].is_number_unsigned() ||
        !status.contains("User") || !status["User"].is_object()) return {};
    const std::string id = std::to_string(status["Self"]["UserID"].get<unsigned long long>());
    if (!status["User"].contains(id) || !status["User"][id].is_object()) return {};
    const json& user = status["User"][id];
    if (!user.contains("LoginName") || !user["LoginName"].is_string()) return {};
    return user["LoginName"].get<std::string>();
}

json rustdesk_status(const std::string& service_state, bool server_observed,
                    const std::string& probe_error) {
    if (service_state != "running")
        return card("RustDesk", service_state, "Windows service; GUI alone is not readiness");
    if (!probe_error.empty())
        return card("RustDesk", "running", "Service running; server observation unavailable: " + probe_error);
    return card("RustDesk", server_observed ? "ready" : "unready",
                server_observed ? "Installed Windows service + observed server; remote connectivity not tested"
                                : "Service running; installed server not observed");
}

json read_rustdesk_status() {
    try {
        const json status = service(L"RustDesk");
        const std::string state = status["state"];
        if (state != "running") return rustdesk_status(state, false);
        try {
            return rustdesk_status(state, rustdesk_backend(status["pid"].get<DWORD>()));
        } catch (const std::runtime_error& error) {
            return rustdesk_status(state, false, error.what());
        }
    } catch (const std::runtime_error& error) {
        return card("RustDesk", "unknown", error.what());
    }
}

json tailscale_status(const json& status) {
    if (!status.contains("BackendState") || !status["BackendState"].is_string())
        return card("Tailscale", "unknown", "Invalid daemon state");
    const std::string state = status["BackendState"];
    json result = card("Tailscale", state == "Running" ? "ready" : "unready", state);
    if (state == "Running" && (!status.contains("Self") || !status["Self"].is_object() ||
        !status["Self"].contains("Online") || !status["Self"]["Online"].is_boolean()))
        return card("Tailscale", "unknown", "Daemon omitted live connection state");
    if (status.contains("Self") && status["Self"].is_object()) {
        const json& self = status["Self"];
        if (self.contains("Online") && self["Online"].is_boolean() && !self["Online"].get<bool>() &&
            state == "Running") result["state"] = "unready";
        if (self.contains("TailscaleIPs") && self["TailscaleIPs"].is_array()) {
            for (const auto& ip : self["TailscaleIPs"])
                if (ip.is_string() && ip.get<std::string>().find(':') == std::string::npos) {
                    result["detail"] = state + " / " + ip.get<std::string>();
                    break;
                }
        }
    }
    return result;
}

json speech_status(const json& health) {
    json result = json::array();
    const bool valid = health.is_object() && health.value("service", json()) == "voice" &&
        health.value("device", json()) == "cpu" && health.value("ok", json()) == true &&
        health.contains("components") && health["components"].is_object();
    for (const auto& component : {std::pair<const char*, const char*>{"stt", "STT"},
                                 {"tts", "TTS"}, {"ocr_cpu", "CPU OCR"}}) {
        json row = card(component.second, "unknown", "Speech helper omitted valid component health");
        if (valid && health["components"].contains(component.first)) {
            const json& value = health["components"][component.first];
            if (value.is_object() && value.contains("state") && value["state"].is_string() &&
                value.contains("detail") && value["detail"].is_string() &&
                value["detail"].get_ref<const std::string&>().size() <= 400) {
                const std::string state = value["state"];
                if (state == "available" || state == "ready" || state == "unready" || state == "unknown")
                    row = card(component.second, state, value["detail"]);
            }
        }
        result.push_back(row);
    }
    return result;
}

json model_status(int port, const json& models, const json& health) {
    std::string name;
    if (port == 8871) {
        if (!health.contains("model") || !health["model"].is_string())
            return {{"name", "Model"}, {"state", "unknown"}, {"port", port},
                    {"detail", "Image endpoint lacks model identity"}};
        name = health["model"];
    } else {
        if (!models.contains("data") || !models["data"].is_array() || models["data"].empty() ||
            !models["data"][0].is_object() || !models["data"][0].contains("id") ||
            !models["data"][0]["id"].is_string())
            return {{"name", "Model"}, {"state", "unknown"}, {"port", port},
                    {"detail", "Model endpoint lacks model identity"}};
        name = models["data"][0]["id"];
    }
    const auto slash = name.find_last_of("\\/");
    if (slash != std::string::npos) name = name.substr(slash + 1);
    if (name.empty() || name.size() > 160)
        return {{"name", "Model"}, {"state", "unknown"}, {"port", port},
                {"detail", "Model identity is invalid"}};
    std::string detail = ":" + std::to_string(port);
    const bool ok = (health.contains("ok") && health["ok"].is_boolean() && health["ok"].get<bool>()) ||
        (port == 8000 && health.contains("status") && health["status"] == "ok");
    std::string state = ok ? "ready" : "unknown";
    if (health.contains("ok") && health["ok"].is_boolean() && !health["ok"].get<bool>()) state = "unready";
    if (health.contains("ready") && health["ready"].is_boolean() && !health["ready"].get<bool>()) state = "unready";
    if (state == "ready" && health.contains("busy") && health["busy"].is_boolean() && health["busy"].get<bool>()) state = "busy";
    for (const char* flag : {"ok", "ready", "busy", "loaded"})
        if (health.contains(flag) && !health[flag].is_boolean()) state = "unknown";
    if (port == 8871 && health.contains("loaded") && health["loaded"].is_boolean())
        detail += health["loaded"].get<bool>() ? " / weights loaded" : " / API ready; weights unloaded";
    if (health.contains("context_length") && health["context_length"].is_number_integer())
        detail += " / context " + std::to_string(health["context_length"].get<int>());
    if (health.contains("cache_quant") && health["cache_quant"].is_string())
        detail += " / KV " + health["cache_quant"].get<std::string>();
    if (health.contains("drafting") && health["drafting"].is_object() &&
        health["drafting"].contains("mode") && health["drafting"]["mode"].is_string()) {
        detail += " / " + health["drafting"]["mode"].get<std::string>();
        if (health["drafting"].contains("num_draft_tokens") && health["drafting"]["num_draft_tokens"].is_number_integer())
            detail += " " + std::to_string(health["drafting"]["num_draft_tokens"].get<int>());
    }
    if (state == "unknown") detail += " / readiness or activity probe unavailable";
    return {{"name", name}, {"state", state}, {"port", port}, {"detail", detail}};
}

Server::Server(std::string token, const std::string& path) : token_(std::move(token)) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Phone Desk HTML is missing");
    html_ = std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    if (html_.empty() || html_.size() > 131072) throw std::runtime_error("Phone Desk HTML size is invalid");
    try {
        owner_login_ = owner_login(read_tailscale());
        if (owner_login_.empty()) throw std::runtime_error("Tailscale device owner is absent");
    }
    catch (const std::runtime_error& error) {
        std::cerr << "[PHONE] Owner identity unavailable: " << error.what() << '\n';
    }
    server_.set_payload_max_length(1024);
    server_.set_read_timeout(3, 0);
    server_.set_write_timeout(3, 0);
    server_.set_default_headers({
        {"Cache-Control", "no-store"}, {"X-Content-Type-Options", "nosniff"},
        {"Referrer-Policy", "no-referrer"},
        {"Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"}});
    auto gate = [this](const httplib::Request& request, httplib::Response& response) {
        if (authorized(request, token_, owner_login_)) return true;
        if (!owner_login_.empty() && request.get_header_value("Tailscale-User-Login") == owner_login_ &&
            trusted_serve_peer(request) && authorized(request, token_, owner_login_, true)) return true;
        response.status = 403;
        response.set_content(R"({"error":"Open Phone Desk through private Tailscale Serve as the device owner."})", "application/json");
        return false;
    };
    server_.Get("/", [this, gate](const httplib::Request& request, httplib::Response& response) {
        if (gate(request, response)) response.set_content(html_, "text/html; charset=utf-8");
    });
    server_.Get("/api/phone/status", [this, gate](const httplib::Request& request, httplib::Response& response) {
        if (!gate(request, response)) return;
        try { response.set_content(snapshot().dump(), "application/json"); }
        catch (const std::exception& error) {
            response.status = 503;
            response.set_content(json({{"error", std::string("Status unavailable: ") + error.what()}}).dump(), "application/json");
        }
    });
}

Server::~Server() { stop(); }
bool Server::start() {
    if (token_.find_first_not_of(" \t\r\n") == std::string::npos) {
        std::cerr << "[PHONE] API token missing; listener stays closed\n";
        return false;
    }
    if (!server_.bind_to_port("127.0.0.1", 8085)) {
        std::cerr << "[PHONE] Could not bind read-only listener on 127.0.0.1:8085\n";
        return false;
    }
    thread_ = std::thread([this]() { server_.listen_after_bind(); });
    return true;
}
void Server::stop() {
    server_.stop();
    if (thread_.joinable()) thread_.join();
}
json Server::snapshot() {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto now = std::chrono::steady_clock::now();
    if (cached_.empty() || now - sampled_ >= std::chrono::seconds(5)) {
        cached_ = collect();
        sampled_ = std::chrono::steady_clock::now();
    }
    return cached_;
}
}
