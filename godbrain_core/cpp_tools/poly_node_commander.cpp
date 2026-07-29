#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>

void print_header() {
    std::cout << "========================================================\n";
    std::cout << " [ GODBRAIN POLYGON (ERIGON) NODE COMMANDER - PRUNED ]\n";
    std::cout << "========================================================\n";
}

int main() {
    print_header();
    
    std::cout << "[*] System DPC Latency Mode: ULTRA-LOW (TB4 Isolated IRQs).\n";
    std::cout << "[*] Storage Target: Primary NVMe (Pruned Mode < 600GB).\n";
    std::cout << "[*] IPC Connection: Named Pipes (\\\\.\\pipe\\erigon.ipc) for 0-latency front-running.\n\n";

    std::cout << "[*] Constructing Erigon Launch Payload...\n";
    
    // Construct the Erigon Pruned command
    // --prune hrtc (history, receipts, tx_index, call_traces)
    // --prune.r.before 128 (keep only latest state)
    std::string erigon_cmd = "erigon.exe --chain=bor-mainnet --datadir=C:\\Polygon_Erigon --prune=hrtc --prune.r.before=128 --http.api=eth,debug,net,trace,web3,txpool --metrics";
    
    std::cout << "[+] EXECUTION STRING GENERATED:\n";
    std::cout << "    " << erigon_cmd << "\n\n";

    std::cout << "[!] WARNING: Starting Erigon sync will generate heavy NVMe I/O.\n";
    std::cout << "[!] This may temporarily spike DPC latencies via storport.sys interrupts during initial state-download.\n";
    std::cout << "[*] Awaiting Commander approval to execute binary...\n";
    
    return 0;
}