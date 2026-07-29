#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>

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

    std::string cmd = "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\LLM\\colibri_LLM\\c\\colibri.exe 64 8 8";
    
    SetEnvironmentVariableA("SNAP", "C:\\nvme\\glm52");
    SetEnvironmentVariableA("NGEN", "2048");
    SetEnvironmentVariableA("COLI_RAM_OVERCOMMIT", "1");
    SetEnvironmentVariableA("COLI_CUDA", "1");
    SetEnvironmentVariableA("CUDA_EXPERT_GB", "12");
    SetEnvironmentVariableA("COLI_API", "1");
    SetEnvironmentVariableA("COLI_PROMPT", prompt.c_str());

    BOOL success = CreateProcessA(NULL, (LPSTR)cmd.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInWr); // Send EOF to Colibri's stdin immediately
    CloseHandle(hInRd);

    if (!success) return "Error: Failed to spawn Colibri C-Engine natively.";

    std::string output = "";
    DWORD read; 
    CHAR buf[4096]; 
    DWORD totalBytesAvail = 0;
    
    // Read loop with timeout
    int timeouts = 0;
    while(timeouts < 600) { // 60 seconds
        PeekNamedPipe(hOutRd, NULL, 0, NULL, &totalBytesAvail, NULL);
        if (totalBytesAvail > 0) {
            if (ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
                buf[read] = '\0';
                output.append(buf, read);
                std::cout << buf; // echo output for debugging
                if (output.find("PROFILO") != std::string::npos || output.find("PROFILE:") != std::string::npos) {
                    break;
                }
            }
        } else {
            Sleep(100);
            timeouts++;
        }
        
        DWORD exitCode;
        if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != STILL_ACTIVE) {
            break; // Process died
        }
    }

    TerminateProcess(pi.hProcess, 0); // COLI_API=1 might loop, so we kill it
    WaitForSingleObject(pi.hProcess, 1000); 
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

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
