#include "surgery.h"
#include "../cpp_tools/windows_process.h"
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

void trim_newlines(std::string& text) {
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
    }
}

bool is_blank(const std::string& text) {
    return text.find_first_not_of(" \t\r\n") == std::string::npos;
}

Outcome failed(const std::string& text) {
    Outcome out;
    out.ok = false;
    out.exit_code = -1;
    out.text = text;
    return out;
}

}  // namespace

Outcome execute_self_command(const std::string& command) {
    if (is_blank(command)) {
        return failed("CRITICAL FAILURE: surgery command is empty.");
    }
    std::cout << "[SURGERY] Executing self-command bytes=" << command.size() << std::endl;

    godbrain_process::Result captured;
    try {
        std::string body = command;
        if (body.back() != '\n' && body.back() != '\r') body.push_back('\n');
        godbrain_process::Options options;
        options.timeout_ms = kTimeoutMs;
        options.stdout_limit = kMaxCaptureBytes;
        options.fail_on_stdout_limit = false;
        captured = godbrain_process::run("pwsh.exe", {"-NoProfile", "-NonInteractive", "-Command", "-"}, body, options);
    } catch (const std::exception& error) {
        return failed(std::string("CRITICAL FAILURE executing command: ") + error.what());
    }
    auto& out_msg = captured.output;
    auto& err_msg = captured.error_output;
    const auto exit_code = captured.exit_code;

    trim_newlines(out_msg);
    trim_newlines(err_msg);

    std::ostringstream response;
    response << "--- SELF-COMMAND EXIT CODE " << exit_code << " ---\n";
    if (!out_msg.empty()) {
        response << "STDOUT:\n" << out_msg << "\n";
        if (captured.output_truncated) {
            response << "(stdout truncated at " << kMaxCaptureBytes << " bytes)\n";
        }
    }
    if (!err_msg.empty()) {
        response << "STDERR:\n" << err_msg << "\n";
        if (captured.error_truncated) {
            response << "(stderr truncated at " << kMaxCaptureBytes << " bytes)\n";
        }
    }
    if (out_msg.empty() && err_msg.empty()) {
        response << "(Command executed silently with no output)";
    }
    Outcome out;
    out.exit_code = static_cast<int>(exit_code);
    out.ok = exit_code == 0;
    out.text = response.str();
    return out;
}

}  // namespace surgery
