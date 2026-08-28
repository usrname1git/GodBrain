#include "surgery.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace surgery {
namespace {

constexpr DWORD kTimeoutMs = 60000;
constexpr size_t kMaxCaptureBytes = 65536;

void close_handle(HANDLE& handle) {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        handle = nullptr;
    }
}

void drain_pipe(HANDLE pipe, std::mutex& mu, std::string& dest, bool& truncated) {
    char buf[4096];
    DWORD read = 0;
    while (ReadFile(pipe, buf, sizeof(buf), &read, nullptr) && read > 0) {
        std::lock_guard<std::mutex> lock(mu);
        if (dest.size() >= kMaxCaptureBytes) {
            truncated = true;
            continue;
        }
        const size_t room = kMaxCaptureBytes - dest.size();
        const size_t take = (std::min)(room, static_cast<size_t>(read));
        dest.append(buf, take);
        if (take < static_cast<size_t>(read)) {
            truncated = true;
        }
    }
}

void trim_newlines(std::string& text) {
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
    }
}

bool is_blank(const std::string& text) {
    return text.find_first_not_of(" \t\r\n") == std::string::npos;
}

}  // namespace

std::string execute_self_command(const std::string& command) {
    if (is_blank(command)) {
        return "CRITICAL FAILURE: surgery command is empty.";
    }
    std::cout << "[SURGERY] Executing self-command bytes=" << command.size() << std::endl;

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE out_rd = nullptr;
    HANDLE out_wr = nullptr;
    HANDLE err_rd = nullptr;
    HANDLE err_wr = nullptr;
    HANDLE in_rd = nullptr;
    HANDLE in_wr = nullptr;
    if (!CreatePipe(&out_rd, &out_wr, &sa, 0) ||
        !CreatePipe(&err_rd, &err_wr, &sa, 0) ||
        !CreatePipe(&in_rd, &in_wr, &sa, 0)) {
        close_handle(out_rd);
        close_handle(out_wr);
        close_handle(err_rd);
        close_handle(err_wr);
        close_handle(in_rd);
        close_handle(in_wr);
        return "Error: Failed to create surgery pipes.";
    }
    SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(err_rd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.hStdInput = in_rd;
    si.hStdOutput = out_wr;
    si.hStdError = err_wr;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi{};
    std::string cmdline_str = "pwsh.exe -NoProfile -NonInteractive -Command -";
    std::vector<char> cmdline(cmdline_str.begin(), cmdline_str.end());
    cmdline.push_back('\0');

    HANDLE job = CreateJobObjectA(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    }

    const BOOL started = CreateProcessA(
        nullptr,
        cmdline.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED,
        nullptr,
        nullptr,
        &si,
        &pi);
    close_handle(out_wr);
    close_handle(err_wr);
    close_handle(in_rd);
    if (!started) {
        close_handle(out_rd);
        close_handle(err_rd);
        close_handle(in_wr);
        close_handle(job);
        return "CRITICAL FAILURE executing command: CreateProcess failed.";
    }
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 5000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        close_handle(out_rd);
        close_handle(err_rd);
        close_handle(in_wr);
        close_handle(job);
        return "CRITICAL FAILURE executing command: Job Object assign failed.";
    }
    ResumeThread(pi.hThread);

    std::mutex mu;
    std::string out_msg;
    std::string err_msg;
    bool out_truncated = false;
    bool err_truncated = false;
    std::thread out_reader([&]() { drain_pipe(out_rd, mu, out_msg, out_truncated); });
    std::thread err_reader([&]() { drain_pipe(err_rd, mu, err_msg, err_truncated); });
    std::thread writer([&]() {
        std::string body = command;
        if (body.empty() || (body.back() != '\n' && body.back() != '\r')) {
            body.push_back('\n');
        }
        DWORD written_total = 0;
        while (written_total < body.size()) {
            DWORD written = 0;
            if (!WriteFile(
                    in_wr,
                    body.data() + written_total,
                    static_cast<DWORD>(body.size() - written_total),
                    &written,
                    nullptr)) {
                break;
            }
            written_total += written;
        }
        close_handle(in_wr);
    });

    const DWORD wait = WaitForSingleObject(pi.hProcess, kTimeoutMs);
    if (wait == WAIT_TIMEOUT) {
        if (job) {
            CloseHandle(job);
            job = nullptr;
        } else {
            TerminateProcess(pi.hProcess, 1);
        }
        WaitForSingleObject(pi.hProcess, 5000);
        if (out_reader.joinable()) out_reader.join();
        if (err_reader.joinable()) err_reader.join();
        if (writer.joinable()) writer.join();
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        close_handle(out_rd);
        close_handle(err_rd);
        close_handle(in_wr);
        return "CRITICAL FAILURE: surgery timed out (60s).";
    }

    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    if (out_reader.joinable()) out_reader.join();
    if (err_reader.joinable()) err_reader.join();
    if (writer.joinable()) writer.join();
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    close_handle(out_rd);
    close_handle(err_rd);
    close_handle(in_wr);
    close_handle(job);

    trim_newlines(out_msg);
    trim_newlines(err_msg);

    std::ostringstream response;
    response << "--- SELF-COMMAND EXIT CODE " << exit_code << " ---\n";
    if (!out_msg.empty()) {
        response << "STDOUT:\n" << out_msg << "\n";
        if (out_truncated) {
            response << "(stdout truncated at " << kMaxCaptureBytes << " bytes)\n";
        }
    }
    if (!err_msg.empty()) {
        response << "STDERR:\n" << err_msg << "\n";
        if (err_truncated) {
            response << "(stderr truncated at " << kMaxCaptureBytes << " bytes)\n";
        }
    }
    if (out_msg.empty() && err_msg.empty()) {
        response << "(Command executed silently with no output)";
    }
    return response.str();
}

}  // namespace surgery
