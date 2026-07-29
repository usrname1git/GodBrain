#include "surgery.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <sstream>
#include <vector>

namespace surgery {
    std::string execute_self_command(const std::string& command) {
        std::cout << "[SURGERY] Executing self-command: " << command << std::endl;
        
        SECURITY_ATTRIBUTES saAttr; 
        saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
        saAttr.bInheritHandle = TRUE; 
        saAttr.lpSecurityDescriptor = NULL; 

        HANDLE hOutRd = NULL, hOutWr = NULL;
        HANDLE hErrRd = NULL, hErrWr = NULL;
        
        if (!CreatePipe(&hOutRd, &hOutWr, &saAttr, 0)) return "Error: Failed to create stdout pipe.";
        if (!CreatePipe(&hErrRd, &hErrWr, &saAttr, 0)) return "Error: Failed to create stderr pipe.";
        
        SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(hErrRd, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOA si;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si); 
        si.hStdError = hErrWr;
        si.hStdOutput = hOutWr;
        si.dwFlags |= STARTF_USESTDHANDLES;

        PROCESS_INFORMATION pi;
        ZeroMemory(&pi, sizeof(pi));

        // Use pwsh to mimic the python surgery behavior
        std::string full_cmd = "pwsh.exe -NoProfile -NonInteractive -Command \"" + command + "\"";

        BOOL success = CreateProcessA(NULL, (LPSTR)full_cmd.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

        CloseHandle(hOutWr);
        CloseHandle(hErrWr);

        if (!success) {
            CloseHandle(hOutRd);
            CloseHandle(hErrRd);
            return "CRITICAL FAILURE executing command: CreateProcess failed.";
        }

        std::string out_msg = "";
        std::string err_msg = "";
        DWORD read; 
        CHAR buf[4096]; 

        while (ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
            buf[read] = '\0';
            out_msg.append(buf, read);
        }
        
        while (ReadFile(hErrRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
            buf[read] = '\0';
            err_msg.append(buf, read);
        }

        DWORD exit_code = 0;
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &exit_code);

        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        CloseHandle(hOutRd);
        CloseHandle(hErrRd);

        std::ostringstream response;
        response << "--- SELF-COMMAND EXIT CODE " << exit_code << " ---\n";
        
        // Strip trailing newlines
        if (!out_msg.empty()) {
            while (!out_msg.empty() && (out_msg.back() == '\n' || out_msg.back() == '\r')) out_msg.pop_back();
        }
        if (!err_msg.empty()) {
            while (!err_msg.empty() && (err_msg.back() == '\n' || err_msg.back() == '\r')) err_msg.pop_back();
        }

        if (!out_msg.empty()) response << "STDOUT:\n" << out_msg << "\n";
        if (!err_msg.empty()) response << "STDERR:\n" << err_msg << "\n";
        
        if (out_msg.empty() && err_msg.empty()) {
            response << "(Command executed silently with no output)";
        }

        return response.str();
    }
}