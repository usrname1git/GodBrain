#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>

void print_header() {
    std::cout << "========================================================\n";
    std::cout << " [ GODBRAIN POLYGON (ERIGON) NODE COMMANDER ]\n";
    std::cout << "========================================================\n";
}

int main() {
    print_header();
    
    std::cout << "[*] Assessing hardware for Polygon Mainnet sync...\n";
    
    // Check Disk Space (Polygon Erigon Archive needs ~2.5TB+ NVMe)
    ULARGE_INTEGER freeBytesAvailable, totalNumberOfBytes, totalNumberOfFreeBytes;
    GetDiskFreeSpaceExA("C:\\", &freeBytesAvailable, &totalNumberOfBytes, &totalNumberOfFreeBytes);
    double free_tb = (double)freeBytesAvailable.QuadPart / (1024ULL * 1024 * 1024 * 1024);
    
    std::cout << "[*] Free NVMe Space on C:\\ -> " << free_tb << " TB\n";
    
    if (free_tb < 1.5) {
        std::cout << "[!] WARNING: Polygon Erigon requires at least 1.5TB - 2.5TB of fast NVMe storage.\n";
        std::cout << "[!] Syncing to a mechanical HDD or low-space drive will result in database corruption.\n";
    }

    std::cout << "[*] Target Architecture: Erigon (Execution Client) + Heimdall/Bor (Consensus)\n";
    std::cout << "[*] IPC Connection: Named Pipes (\\\\.\\pipe\\erigon.ipc) to bypass TCP/HTTP overhead (saves ~1-2ms).\n\n";

    std::cout << "[+] Node Commander Compiled. To deploy, GodBrain requires authorization to:\n";
    std::cout << "    1. Allocate 2TB of disk space.\n";
    std::cout << "    2. Download Erigon/Polygon binaries.\n";
    std::cout << "    3. Open port 30303 (P2P) in Windows Firewall.\n";
    
    return 0;
}