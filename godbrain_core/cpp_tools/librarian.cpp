#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <chrono>

// Include JSON support
#include "../cpp_kernel/json.hpp"
using json = nlohmann::json;

std::string get_iso_timestamp() {
    auto now = std::chrono::system_clock::now();
    std::time_t now_c = std::chrono::system_clock::to_time_t(now);
    struct tm parts;
    gmtime_s(&parts, &now_c);
    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &parts);
    return std::string(buf);
}

// Emulates the Python distillation by returning structured JSON
json distill_session(const std::string& raw_transcript) {
    std::cout << "[LIBRARIAN] Waking up native C++ distillation logic..." << std::endl;
    // In a real scenario, this would pipe to the Colibri Win32 process
    // just like our sre_surgeon does.

    return {
        {"timestamp", get_iso_timestamp()},
        {"core_concepts", {"C++ Architecture", "Bare Metal Performance", "Zero Python Policy"}},
        {"opsec_rules", {"Native Win32 Only", "No interpretters"}},
        {"summary", "Transferred Python librarian logic directly into optimized C++ binary."}
    };
}

void commit_to_brain(const std::string& session_id, const std::string& raw_transcript) {
    std::cout << "[LIBRARIAN] Archiving session " << session_id << "..." << std::endl;
    std::cout << "[LIBRARIAN] Raw transcript saved to TTL storage (Stubbed)." << std::endl;

    json golden_record = distill_session(raw_transcript);
    golden_record["session_id"] = session_id;

    // Send to Go Memory Engine via stdin
    std::string go_engine_path = "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\godbrain_core\\memory_engine\\memory_engine.exe";

    std::cout << "[LIBRARIAN] Sending payload to Go Memory Engine..." << std::endl;
    
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;

    if (!CreatePipe(&hOutRd, &hOutWr, &saAttr, 0)) return;
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    
    if (!CreatePipe(&hInRd, &hInWr, &saAttr, 0)) return;
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

    BOOL success = CreateProcessA(NULL, (LPSTR)go_engine_path.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInRd);

    if (success) {
        std::string payload = golden_record.dump();
        DWORD written;
        WriteFile(hInWr, payload.c_str(), payload.length(), &written, NULL);
        CloseHandle(hInWr); // Send EOF

        std::string output = "";
        DWORD read; 
        CHAR buf[4096]; 
        while(ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
            buf[read] = '\0';
            output.append(buf, read);
        }

        WaitForSingleObject(pi.hProcess, INFINITE);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        
        std::cout << "[LIBRARIAN] Go Engine output:\n" << output << std::endl;
    } else {
        CloseHandle(hInWr);
        std::cout << "[LIBRARIAN WARN] Go engine not found or failed to start. Skipping Aura upload." << std::endl;
    }
    CloseHandle(hOutRd);
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        // Fallback test mode
        commit_to_brain("session_cpp_123", "User: We need a C++ Librarian. AI: Executing native protocol.");
    } else {
        commit_to_brain(argv[1], argv[2]);
    }
    return 0;
}