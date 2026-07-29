#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <chrono>

int main(int argc, char* argv[]) {
    LPCSTR pipeName = "\\\\.\\pipe\\GodBrainMempoolPipe";
    
    std::cout << "[IPC CLIENT] Connecting to " << pipeName << "...\n";
    
    HANDLE hPipe;
    while (true) {
        hPipe = CreateFileA(
            pipeName,
            GENERIC_READ | GENERIC_WRITE,
            0,
            NULL,
            OPEN_EXISTING,
            0,
            NULL
        );
        
        if (hPipe != INVALID_HANDLE_VALUE) break;
        if (GetLastError() != ERROR_PIPE_BUSY) {
            std::cout << "[-] Could not open pipe. Error: " << GetLastError() << "\n";
            return 1;
        }
        
        if (!WaitNamedPipeA(pipeName, 2000)) {
            std::cout << "[-] Pipe timeout.\n";
            return 1;
        }
    }

    DWORD dwMode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(hPipe, &dwMode, NULL, NULL);

    std::string payload = "{\"tx\": \"0xPOLYMARKET_SNIPE\", \"contract\": \"SBUX_EARNINGS\", \"amount\": 2500}";
    if (argc > 1) {
        payload = argv[1];
    }
    
    std::cout << "[IPC CLIENT] Blasting payload: " << payload << "\n";
    
    auto start = std::chrono::high_resolution_resolution_clock::now();
    
    DWORD bytesWritten;
    BOOL success = WriteFile(hPipe, payload.c_str(), payload.length(), &bytesWritten, NULL);
    
    if (success) {
        char buffer[1024];
        DWORD bytesRead;
        if (ReadFile(hPipe, buffer, sizeof(buffer) - 1, &bytesRead, NULL)) {
            buffer[bytesRead] = '\0';
            auto end = std::chrono::high_resolution_resolution_clock::now();
            auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
            
            std::cout << "[IPC CLIENT] Reply: " << buffer << "\n";
            std::cout << "[IPC CLIENT] Round-trip latency: " << duration.count() << " microseconds.\n";
        }
    }

    CloseHandle(hPipe);
    return 0;
}