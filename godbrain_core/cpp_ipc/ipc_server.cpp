#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>

int main() {
    std::cout << "[IPC SERVER] Initializing GodBrain Neural Link (Named Pipe Server)...\n";
    
    LPCSTR pipeName = "\\\\.\\pipe\\GodBrainMempoolPipe";
    
    HANDLE hPipe = CreateNamedPipeA(
        pipeName,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        1, // Max instances
        4096, // Out buffer
        4096, // In buffer
        0, // Default timeout
        NULL // Default security
    );

    if (hPipe == INVALID_HANDLE_VALUE) {
        std::cout << "[-] Failed to create pipe. Error: " << GetLastError() << "\n";
        return 1;
    }

    std::cout << "[IPC SERVER] Listening for high-speed Oracle connections on " << pipeName << "\n";

    BOOL connected = ConnectNamedPipe(hPipe, NULL) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);

    if (connected) {
        std::cout << "[IPC SERVER] Client Connected. Awaiting payload...\n";
        
        char buffer[1024];
        DWORD bytesRead;
        
        // Read from pipe
        while (ReadFile(hPipe, buffer, sizeof(buffer) - 1, &bytesRead, NULL) && bytesRead != 0) {
            buffer[bytesRead] = '\0';
            std::cout << "[SERVER RCV] " << buffer << "\n";
            
            // Send ACK back
            std::string ack = "ACK: TX Received in 0.1ms";
            DWORD bytesWritten;
            WriteFile(hPipe, ack.c_str(), ack.length(), &bytesWritten, NULL);
        }
    }

    CloseHandle(hPipe);
    std::cout << "[IPC SERVER] Connection closed.\n";
    return 0;
}