#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <cstdlib>
#include <thread>
#include <mutex>

// Ceiling on a single Colibri invocation, matching the C++ kernel router's
// timeout so both native launch sites behave the same way.
static const DWORD COLIBRI_TIMEOUT_MS = 180000;

static std::string get_exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

static bool path_exists(const std::string& p) {
    if (p.empty()) return false;
    return GetFileAttributesA(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// Resolves colibri.exe the same portable way as the C++ kernel router:
// GODBRAIN_COLIBRI_PATH wins outright; otherwise try repo-relative locations
// from both the running executable's directory and the current working
// directory, so no single user's absolute path is ever baked in.
static std::string resolve_colibri_path() {
    const char* env = std::getenv("GODBRAIN_COLIBRI_PATH");
    if (env && *env) return std::string(env);

    static const char* candidates[] = {
        "\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\..\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\LLM\\colibri_LLM\\c\\colibri.exe",
    };
    std::string exe_dir = get_exe_dir();
    for (const char* rel : candidates) {
        if (!exe_dir.empty()) {
            std::string cand = exe_dir + rel;
            if (path_exists(cand)) return cand;
        }
    }
    std::string fallback = "..\\..\\LLM\\colibri_LLM\\c\\colibri.exe";
    if (path_exists(fallback)) return fallback;
    std::cerr << "[SRE] WARNING: could not locate colibri.exe via GODBRAIN_COLIBRI_PATH or repo-relative defaults; "
                 "using best-effort path '" << fallback << "'." << std::endl;
    return fallback;
}

// Fast, low-level command execution to grab system telemetry
std::string exec_cmd(const std::string& cmd) {
    char buffer[512];
    std::string result = "";
    FILE* pipe = _popen(cmd.c_str(), "r");
    if (!pipe) return "[Telemetry Error]";
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        result += buffer;
    }
    _pclose(pipe);
    return result;
}

// Bare-metal Win32 Process creation for Colibri
std::string run_colibri_sre(const std::string& prompt) {
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;
    CreatePipe(&hOutRd, &hOutWr, &saAttr, 0);
    CreatePipe(&hInRd, &hInWr, &saAttr, 0);
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si); 
    si.hStdError = hOutWr;
    si.hStdOutput = hOutWr;
    si.hStdInput = hInRd;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    // Quote the resolved path: it may contain spaces, and an unquoted path
    // lets CreateProcess misinterpret the first space as the end of the
    // executable name and the rest as arguments.
    std::string cmd = "\"" + resolve_colibri_path() + "\" 64 8 8";
    
    const char* snap_env = std::getenv("GODBRAIN_SNAPSHOT_PATH");
    SetEnvironmentVariableA("SNAP", (snap_env && *snap_env) ? snap_env : "C:\\nvme\\glm52");
    SetEnvironmentVariableA("NGEN", "2048");
    SetEnvironmentVariableA("COLI_RAM_OVERCOMMIT", "1");
    SetEnvironmentVariableA("COLI_CUDA", "1");
    SetEnvironmentVariableA("CUDA_EXPERT_GB", "12");
    SetEnvironmentVariableA("COLI_API", "1");
    SetEnvironmentVariableA("COLI_PROMPT", prompt.c_str());

    // CreateProcessA can rewrite characters inside lpCommandLine while
    // parsing argv[0], so it must never be handed a pointer into a
    // std::string's internal buffer via a cast-away-const c_str() (that's
    // UB). Use a private, mutable buffer instead.
    std::vector<char> cmd_buf(cmd.begin(), cmd.end());
    cmd_buf.push_back('\0');

    BOOL success = CreateProcessA(NULL, cmd_buf.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInWr); // Send EOF to Colibri's stdin immediately
    CloseHandle(hInRd);

    if (!success) {
        CloseHandle(hOutRd);
        return "Error: Failed to spawn Colibri C-Engine natively.";
    }

    // Read stdout on a background thread instead of interleaving ReadFile
    // with the marker/timeout poll below on the main thread: a hung child
    // that keeps the pipe open can no longer stall the polling loop, which
    // now only ever inspects the shared buffer (behind a mutex) or sleeps.
    std::string output;
    std::mutex output_mutex;
    std::thread reader([&]() {
        DWORD read;
        CHAR buf[4096];
        while (ReadFile(hOutRd, buf, sizeof(buf) - 1, &read, NULL) && read > 0) {
            buf[read] = '\0';
            std::cout << buf; // echo output for debugging
            std::lock_guard<std::mutex> lock(output_mutex);
            output.append(buf, read);
        }
    });

    bool timed_out = false;
    bool marker_found = false;
    const DWORD poll_interval_ms = 100;
    DWORD waited_ms = 0;
    for (;;) {
        {
            std::lock_guard<std::mutex> lock(output_mutex);
            if (output.find("PROFILO") != std::string::npos || output.find("PROFILE:") != std::string::npos) {
                marker_found = true;
            }
        }
        if (marker_found) break;

        DWORD exitCode;
        if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != STILL_ACTIVE) {
            break; // Process died on its own
        }

        if (waited_ms >= COLIBRI_TIMEOUT_MS) {
            timed_out = true;
            break;
        }
        Sleep(poll_interval_ms);
        waited_ms += poll_interval_ms;
    }

    // Terminate only the exact child process we spawned (by handle, never by
    // image name — a taskkill /IM would kill every colibri.exe on the
    // machine): COLI_API=1 mode may keep looping even after printing the
    // marker, so we always stop it here rather than trust it to exit itself.
    TerminateProcess(pi.hProcess, 0);
    WaitForSingleObject(pi.hProcess, 5000); // reap the terminated/exited process

    // The reader thread's ReadFile loop only returns once every write handle
    // to the pipe is closed, which happens once the child (the pipe's sole
    // writer) exits or is terminated above — so this join can no longer
    // block indefinitely.
    reader.join();

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    if (timed_out) {
        return "Error: Colibri C-Engine timed out after 180s and was terminated.";
    }

    // Clean up output (strip profiling data)
    std::string final_answer = output;
    size_t ans_idx = output.rfind("Answer:");
    if (ans_idx != std::string::npos) {
        final_answer = output.substr(ans_idx + 7);
        size_t end_idx = final_answer.find("PROFILE");
        if (end_idx == std::string::npos) end_idx = final_answer.find("PROFILO");
        if (end_idx != std::string::npos) {
            final_answer = final_answer.substr(0, end_idx);
        }
    } else {
        size_t prof_idx = output.rfind("PROFILO");
        if (prof_idx != std::string::npos) {
            size_t start = output.rfind('\n', prof_idx);
            if (start != std::string::npos) {
                size_t prev = output.rfind('\n', start - 1);
                if (prev != std::string::npos) {
                    final_answer = output.substr(prev + 1, start - prev - 1);
                }
            }
        }
    }

    final_answer.erase(0, final_answer.find_first_not_of(" \n\r\t"));
    final_answer.erase(final_answer.find_last_not_of(" \n\r\t") + 1);
    
    return final_answer;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cout << "[ERR] Usage: sre_surgeon.exe \"<Describe the Windows problem>\"" << std::endl;
        return 1;
    }
    
    std::string issue = argv[1];
    
    std::cout << "\n[SRE] Initializing GodBrain C++ Windows SRE Agent..." << std::endl;
    std::cout << "[SRE] Target Issue: " << issue << std::endl;
    
    std::cout << "[SRE] Pulling native kernel & system event telemetry..." << std::endl;
    // Wevtutil is the fastest way to get real kernel/system errors natively without wrapping heavy C# scripts
    std::string sys_logs = exec_cmd("wevtutil qe System /c:3 /rd:true /f:text /q:\"*[System[(Level=2 or Level=3)]]\"");
    if (sys_logs.length() > 1000) sys_logs = sys_logs.substr(0, 1000); // Cap context
    
    std::cout << "[SRE] Compiling state vector & invoking Colibri over Win32 Pipes..." << std::endl;
    
    std::string prompt = "You are GodBrain, the elite Windows SRE Surgeon. "
                         "You write pure, hyper-optimized Win32 / CLI fixes. "
                         "User reports this problem: " + issue + "\n\n"
                         "Recent System Event Log Errors:\n" + sys_logs + "\n\n"
                         "Provide a diagnosis and the EXACT CMD/PowerShell commands to fix it. "
                         "Answer:";

    std::string resolution = run_colibri_sre(prompt);
    
    std::cout << "\n================ [ SRE DIAGNOSIS & RESOLUTION ] ================\n";
    std::cout << resolution << "\n";
    std::cout << "===============================================================\n\n";

    return 0;
}
