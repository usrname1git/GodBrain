#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")

#include <algorithm>
#include <array>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace godbrain_process {

struct Options {
    DWORD timeout_ms = 35000;
    size_t stdout_limit = 8 * 1024 * 1024;
    size_t stderr_limit = 65536;
    bool fail_on_stdout_limit = true;
    bool merge_stderr = false;
    std::string raw_arguments;
    std::string ready_marker;
    DWORD ready_timeout_ms = 30000;
    const void* environment = nullptr;
};

struct Result {
    DWORD exit_code = 1;
    std::string output;
    std::string error_output;
    bool output_truncated = false;
    bool error_truncated = false;
};

struct TimeoutError : std::runtime_error {
    Result captured;
    TimeoutError(const char* message, Result result)
        : std::runtime_error(message), captured(std::move(result)) {}
};

class Handle {
    HANDLE value_ = nullptr;
public:
    Handle() = default;
    explicit Handle(HANDLE value) : value_(value) {}
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    ~Handle() { reset(); }
    HANDLE get() const { return value_; }
    void reset(HANDLE value = nullptr) {
        if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
        value_ = value;
    }
};

[[noreturn]] inline void fail(const char* operation, DWORD error = GetLastError()) {
    throw std::runtime_error(std::string(operation) + " failed (Win32 " + std::to_string(error) + ")");
}

inline std::string quoted(const std::string& value) {
    std::string result = "\"";
    size_t slashes = 0;
    for (char ch : value) {
        if (ch == '\\') { ++slashes; continue; }
        result.append(slashes * (ch == '"' ? 2 : 1), '\\');
        if (ch == '"') result.push_back('\\');
        result.push_back(ch);
        slashes = 0;
    }
    result.append(slashes * 2, '\\');
    return result + "\"";
}

inline std::string executable_path(const std::string& executable) {
    if (executable.find_first_of("\\/") != std::string::npos) return executable;
    std::array<char, 32768> path{}, environment{};
    const DWORD count = GetEnvironmentVariableA("PATH", environment.data(), static_cast<DWORD>(environment.size()));
    if (!count || count >= environment.size()) fail("Read executable PATH");
    const DWORD found = SearchPathA(environment.data(), executable.c_str(), nullptr,
                                   static_cast<DWORD>(path.size()), path.data(), nullptr);
    if (!found || found >= path.size()) fail("Resolve executable");
    return std::string(path.data(), found);
}

struct Pipe {
    Handle parent;
    Handle child;
    bool ended = false;

    explicit Pipe(bool input) {
        std::array<unsigned char, 16> random{};
        if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()),
                            BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
            throw std::runtime_error("Generate private pipe name failed");
        }
        const char* hex = "0123456789abcdef";
        std::string name = "\\\\.\\pipe\\GodBrain-";
        for (auto byte : random) { name.push_back(hex[byte >> 4]); name.push_back(hex[byte & 15]); }
        parent.reset(CreateNamedPipeA(name.c_str(),
            (input ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1, 4096, 4096, 0, nullptr));
        if (parent.get() == INVALID_HANDLE_VALUE) fail("Create private process pipe");
        SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        child.reset(CreateFileA(name.c_str(), input ? GENERIC_READ : GENERIC_WRITE,
                                0, &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (child.get() == INVALID_HANDLE_VALUE) fail("Open private process pipe");
        if (!ConnectNamedPipe(parent.get(), nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) {
            fail("Connect private process pipe");
        }
    }

    bool read(std::string& output, size_t limit, bool& truncated) {
        if (ended) return false;
        std::array<char, 4096> buffer{};
        DWORD count = 0;
        if (!ReadFile(parent.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) {
            const DWORD error = GetLastError();
            if (error == ERROR_NO_DATA) return false;
            if (error != ERROR_BROKEN_PIPE && error != ERROR_PIPE_NOT_CONNECTED) fail("Read child output", error);
            ended = true;
            return false;
        }
        if (!count) return false;
        const auto take = (std::min)(static_cast<size_t>(count), limit - output.size());
        output.append(buffer.data(), take);
        truncated = truncated || take != count;
        return true;
    }
};

struct Child {
    Handle job;
    Handle process;
    Handle thread;
    ~Child() {
        job.reset();
        if (process.get()) {
            const DWORD wait = WaitForSingleObject(process.get(), 2000);
            if (wait != WAIT_OBJECT_0) {
                const BOOL terminated = TerminateProcess(process.get(), 1);
                const DWORD error = terminated ? ERROR_SUCCESS : GetLastError();
                const DWORD reaped = WaitForSingleObject(process.get(), 2000);
                if (reaped != WAIT_OBJECT_0) {
                    std::fprintf(stderr, "[PROCESS] exact child cleanup failed (terminate=%lu, wait=%lu)\n",
                                 static_cast<unsigned long>(error), static_cast<unsigned long>(reaped));
                }
            }
        }
    }
};

inline Result run(const std::string& executable, const std::vector<std::string>& arguments,
                  const std::string& input, const Options& options = {}) {
    if (!options.timeout_ms || !options.stdout_limit || !options.stderr_limit ||
        input.size() > 15 * 1024 * 1024 ||
        executable.empty() || executable.find('\0') != std::string::npos ||
        options.raw_arguments.find('\0') != std::string::npos ||
        (!options.raw_arguments.empty() && !arguments.empty()) ||
        std::any_of(arguments.begin(), arguments.end(), [](const std::string& arg) {
            return arg.find('\0') != std::string::npos;
        })) {
        throw std::invalid_argument("Invalid bounded native process request");
    }
    const auto path = executable_path(executable);
    const auto started = GetTickCount64();
    Pipe in(true), out(false), err(false);
    Child child;
    child.job.reset(CreateJobObjectW(nullptr, nullptr));
    if (!child.job.get()) fail("Create process Job Object");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(child.job.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        fail("Set process Job Object limits");
    }
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    if (!bytes) fail("Size process handle list");
    std::vector<unsigned char> storage(bytes);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &bytes)) fail("Initialize process handle list");
    struct AttributeGuard {
        LPPROC_THREAD_ATTRIBUTE_LIST value;
        ~AttributeGuard() { DeleteProcThreadAttributeList(value); }
    } attribute_guard{attributes};
    HANDLE inherited[] = {in.child.get(), out.child.get(), err.child.get()};
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited, options.merge_stderr ? 2 * sizeof(HANDLE) : sizeof(inherited), nullptr, nullptr)) {
        fail("Restrict inherited process handles");
    }
    STARTUPINFOEXA startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = in.child.get();
    startup.StartupInfo.hStdOutput = out.child.get();
    startup.StartupInfo.hStdError = options.merge_stderr ? out.child.get() : err.child.get();
    startup.lpAttributeList = attributes;
    std::string command = quoted(path);
    for (const auto& arg : arguments) command += " " + quoted(arg);
    if (!options.raw_arguments.empty()) command += " " + options.raw_arguments;
    std::vector<char> mutable_command(command.begin(), command.end());
    mutable_command.push_back('\0');
    PROCESS_INFORMATION process{};
    if (!CreateProcessA(path.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
                        const_cast<void*>(options.environment), nullptr, &startup.StartupInfo, &process)) {
        fail("Create native child");
    }
    child.process.reset(process.hProcess);
    child.thread.reset(process.hThread);
    in.child.reset(); out.child.reset(); err.child.reset();
    if (!AssignProcessToJobObject(child.job.get(), child.process.get())) fail("Assign child to Job Object");
    if (ResumeThread(child.thread.get()) == static_cast<DWORD>(-1)) fail("Resume native child");
    Result result;
    size_t written = 0;
    bool exited = false;
    bool ready = options.ready_marker.empty();
    for (;;) {
        const auto elapsed = GetTickCount64() - started;
        if (elapsed >= options.timeout_ms) throw TimeoutError("native process timed out", std::move(result));
        if (!ready && elapsed >= options.ready_timeout_ms) {
            throw TimeoutError("native process timed out waiting for READY", std::move(result));
        }
        bool progress = out.read(result.output, options.stdout_limit, result.output_truncated);
        progress = err.read(result.error_output, options.stderr_limit, result.error_truncated) || progress;
        if (result.output_truncated && options.fail_on_stdout_limit) {
            throw std::runtime_error("native process stdout exceeds limit");
        }
        if (!ready && result.output.find(options.ready_marker) != std::string::npos) ready = true;
        if (!in.ended && ready) {
            if (written == input.size()) {
                in.parent.reset();
                in.ended = true;
            } else {
                DWORD count = 0;
                const auto remaining = (std::min)(input.size() - written, size_t{4096});
                if (!WriteFile(in.parent.get(), input.data() + written, static_cast<DWORD>(remaining), &count, nullptr)) {
                    fail("Write complete child stdin");
                }
                written += count;
                progress = progress || count != 0;
            }
        }
        if (!exited) {
            const DWORD wait = WaitForSingleObject(child.process.get(), progress ? 0 : 5);
            if (wait == WAIT_OBJECT_0) {
                if (!GetExitCodeProcess(child.process.get(), &result.exit_code)) fail("Read completed child exit code");
                if (result.exit_code == STILL_ACTIVE) fail("Read completed child exit code", ERROR_INVALID_DATA);
                exited = true;
                // Release descendants before draining EOF; inherited output must not extend the deadline.
                child.job.reset();
                if (written != input.size()) throw std::runtime_error("native child exited before complete stdin delivery");
                if (!ready) throw std::runtime_error("native child exited before READY");
            } else if (wait != WAIT_TIMEOUT) {
                fail("Wait for native child", wait == WAIT_FAILED ? GetLastError() : ERROR_INVALID_DATA);
            }
        }
        if (exited && out.ended && err.ended) return result;
        if (exited && !progress) Sleep(1);
    }
}

} // namespace godbrain_process
