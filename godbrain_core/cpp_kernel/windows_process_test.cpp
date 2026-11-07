#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <atomic>
#include <iostream>
#include <thread>

static int fault = 0;
static std::atomic<int> starts{0}, resumes{0};
static HANDLE WINAPI checked_job(LPSECURITY_ATTRIBUTES attributes, LPCWSTR name) {
    if (fault == 1) { SetLastError(ERROR_ACCESS_DENIED); return nullptr; }
    return CreateJobObjectW(attributes, name);
}
static BOOL WINAPI checked_assign(HANDLE job, HANDLE process) {
    if (fault == 2) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    return AssignProcessToJobObject(job, process);
}
static DWORD WINAPI checked_resume(HANDLE thread) {
    ++resumes;
    if (fault == 3) { SetLastError(ERROR_ACCESS_DENIED); return static_cast<DWORD>(-1); }
    return ResumeThread(thread);
}
static DWORD WINAPI checked_wait(HANDLE handle, DWORD timeout) {
    if (fault == 4 && timeout <= 5) { SetLastError(ERROR_INVALID_HANDLE); return WAIT_FAILED; }
    return WaitForSingleObject(handle, timeout);
}
static BOOL WINAPI checked_start(LPCSTR application, LPSTR command, LPSECURITY_ATTRIBUTES process_attributes,
    LPSECURITY_ATTRIBUTES thread_attributes, BOOL inherit, DWORD flags, LPVOID environment,
    LPCSTR directory, LPSTARTUPINFOA startup, LPPROCESS_INFORMATION process) {
    ++starts;
    return CreateProcessA(application, command, process_attributes, thread_attributes, inherit,
                          flags, environment, directory, startup, process);
}
#define CreateJobObjectW checked_job
#define AssignProcessToJobObject checked_assign
#define ResumeThread checked_resume
#define WaitForSingleObject checked_wait
#define CreateProcessA checked_start
#include "../cpp_tools/windows_process.h"
#undef CreateJobObjectW
#undef AssignProcessToJobObject
#undef ResumeThread
#undef WaitForSingleObject
#undef CreateProcessA

static void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static std::string self() {
    char path[MAX_PATH]{};
    const auto count = GetModuleFileNameA(nullptr, path, MAX_PATH);
    check(count && count < MAX_PATH, "Cannot locate fixture");
    return std::string(path, count);
}

static void emit(HANDLE stream, const std::string& value) {
    size_t position = 0;
    while (position < value.size()) {
        DWORD written = 0;
        check(WriteFile(stream, value.data() + position,
                        static_cast<DWORD>(value.size() - position), &written, nullptr) && written,
              "Fixture write failed");
        position += written;
    }
}

static int fixture(int argc, char** argv) {
    const std::string mode = argv[2];
    if (mode == "sleep" || mode == "hold") { Sleep(5000); return 0; }
    if (mode == "early") { emit(GetStdHandle(STD_OUTPUT_HANDLE), "{}"); return 0; }
    if (mode == "inherited") {
        check(argc == 4, "Missing handle fixture");
        SetEvent(reinterpret_cast<HANDLE>(static_cast<uintptr_t>(std::stoull(argv[3]))));
        return 0;
    }
    if (mode == "descendant" || mode == "timeout-descendant") {
        STARTUPINFOA startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        auto command = godbrain_process::quoted(self()) + " --fixture hold";
        PROCESS_INFORMATION process{};
        check(CreateProcessA(nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                             nullptr, nullptr, &startup, &process) != FALSE, "Descendant create failed");
        emit(GetStdHandle(STD_OUTPUT_HANDLE), std::to_string(process.dwProcessId));
        CloseHandle(process.hThread); CloseHandle(process.hProcess);
        if (mode == "timeout-descendant") Sleep(5000);
        return 0;
    }
    if (mode == "ready") emit(GetStdHandle(STD_OUTPUT_HANDLE), "READY\n");
    std::string input;
    char buffer[4096];
    DWORD count = 0;
    while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer, sizeof(buffer), &count, nullptr) && count) {
        input.append(buffer, count);
    }
    if (mode == "flood") {
        emit(GetStdHandle(STD_OUTPUT_HANDLE), std::string(100000, 'o'));
        emit(GetStdHandle(STD_ERROR_HANDLE), std::string(100000, 'e'));
    } else emit(GetStdHandle(STD_OUTPUT_HANDLE), input);
    return 0;
}

int main(int argc, char** argv) {
    try {
        if (argc >= 3 && std::string(argv[1]) == "--fixture") return fixture(argc, argv);
        using godbrain_process::Options;
        const auto run = [](const std::string& mode, const std::string& body, const Options& options) {
            return godbrain_process::run(self(), {"--fixture", mode}, body, options);
        };
        Options options;
        options.timeout_ms = 2500;
        const std::string input(1024 * 1024, 'x');
        check(run("echo", input, options).output == input, "Complete stdin/stdout transfer failed");
        const auto rejects = [&](const std::string& mode, const std::string& body,
                                 const Options& config, const char* expected) {
            const auto begin = GetTickCount64();
            try { run(mode, body, config); }
            catch (const std::exception& error) {
                check(std::string(error.what()).find(expected) != std::string::npos, "Wrong supervision error");
                check(GetTickCount64() - begin < 4500, "Supervision exceeded bounded cleanup");
                return;
            }
            throw std::runtime_error("Invalid child reported success");
        };
        rejects("early", input, options, "stdin");
        options.stdout_limit = 65536;
        rejects("flood", "", options, "stdout exceeds limit");
        options.fail_on_stdout_limit = false;
        const auto clipped = run("flood", "", options);
        check(clipped.output.size() == 65536 && clipped.error_output.size() == 65536 &&
              clipped.output_truncated && clipped.error_truncated, "Concurrent bounded streams failed");
        const auto begin = GetTickCount64();
        const auto descendant = run("descendant", "", options);
        check(GetTickCount64() - begin < 1500, "Normal child exit waited on descendant pipes");
        godbrain_process::Handle held(OpenProcess(SYNCHRONIZE, FALSE, std::stoul(descendant.output)));
        check(!held.get() || WaitForSingleObject(held.get(), 1000) == WAIT_OBJECT_0, "Descendant survived normal job close");
        options.timeout_ms = 100;
        rejects("sleep", input, options, "timed out");
        rejects("timeout-descendant", "", options, "timed out");
        options.timeout_ms = 2500;
        options.ready_marker = "READY";
        check(run("ready", "payload", options).output == "READY\npayload", "READY protocol failed");
        options.ready_timeout_ms = 100;
        rejects("echo", "payload", options, "waiting for READY");
        options.ready_marker.clear();
        SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
        godbrain_process::Handle extra(CreateEventA(&attributes, TRUE, FALSE, nullptr));
        check(extra.get() != nullptr, "Event fixture failed");
        godbrain_process::run(self(), {"--fixture", "inherited",
            std::to_string(reinterpret_cast<uintptr_t>(extra.get()))}, "", options);
        check(WaitForSingleObject(extra.get(), 0) == WAIT_TIMEOUT, "Unlisted inheritable handle leaked to child");
        for (int failure = 1; failure <= 4; ++failure) {
            const int prior_starts = starts.load(), prior_resumes = resumes.load();
            fault = failure;
            rejects("sleep", "", options, failure == 1 ? "Create process Job" :
                failure == 2 ? "Assign child" : failure == 3 ? "Resume native" : "Wait for native");
            fault = 0;
            if (failure == 1) check(starts == prior_starts, "Child created without containment");
            if (failure == 2) check(resumes == prior_resumes, "Uncontained child resumed");
        }
        options.stdout_limit = 2 * 1024 * 1024;
        bool first = false, second = false;
        std::thread a([&] { first = run("echo", input, options).output == input; });
        std::thread b([&] { second = run("echo", input, options).output == input; });
        a.join(); b.join();
        check(first && second, "Concurrent process pipes interfered");
        std::cout << "windows_process_test ok: complete input, caps, deadlines, descendants, handle isolation, faults and concurrency\n";
        return 0;
    } catch (const std::exception& error) {
        fault = 0;
        std::cerr << error.what() << '\n';
        return 1;
    }
}
