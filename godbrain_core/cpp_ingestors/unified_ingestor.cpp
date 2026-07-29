#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <filesystem>
#include "../cpp_kernel/json.hpp"

using json = nlohmann::json;
namespace fs = std::filesystem;

void run_mongo_insert(const std::string& title, const std::string& content, const std::string& type, const std::vector<std::string>& tags) {
    // Generate JS string to execute in mongosh
    json doc = {
        {"title", title},
        {"content", content},
        {"type", type},
        {"tags", tags}
    };
    
    // Create a temporary file with the JS to avoid command line limits
    std::string js_script = "db.nodes.updateOne({title: " + json(title).dump() + "}, {$set: " + doc.dump() + "}, {upsert: true});";
    
    std::string temp_file = "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\godbrain_core\\cpp_ingestors\\temp_mongo.js";
    std::ofstream out(temp_file);
    out << js_script;
    out.close();

    std::string cmd = "mongosh godbrain --quiet " + temp_file;
    
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    CreatePipe(&hOutRd, &hOutWr, &saAttr, 0);
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si); 
    si.hStdError = hOutWr;
    si.hStdOutput = hOutWr;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    std::string full_cmd = "cmd.exe /c " + cmd;
    CreateProcessA(NULL, (LPSTR)full_cmd.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    WaitForSingleObject(pi.hProcess, 10000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    DeleteFileA(temp_file.c_str());
}

void ingest_cpp_expert() {
    std::cout << "[*] Ingesting C++ Expert Knowledge...\n";

    run_mongo_insert("C++ Core Guidelines (Stroustrup & Sutter)",
        "Use RAII (Resource Acquisition Is Initialization) to prevent leaks; never use naked new/delete. Prefer std::unique_ptr for exclusive ownership and std::shared_ptr for shared. Use const and constexpr everywhere possible to ensure immutability. Avoid raw arrays, prefer std::vector, std::array, or std::span for views. Minimize pointer arithmetic.",
        "C++ Architecture", {"C++", "modern-c++", "memory-management"});

    run_mongo_insert("John Carmack Optimization Philosophy",
        "Data-Oriented Design (DOD) over Object-Oriented Programming (OOP). Prefer Struct of Arrays (SoA) over Array of Structs (AoS) for cache locality and SIMD vectorization. Inline functions heavily to reduce call overhead and increase compiler visibility. Avoid hidden control flow like exceptions or deep inheritance trees. Write pure, deterministic functions.",
        "C++ SRE / Optimization", {"C++", "carmack", "performance", "data-oriented-design"});

    run_mongo_insert("Low-Level Memory & Cache Alignment",
        "Cache misses are the primary bottleneck in modern CPUs. Pad and align data structures to 64-byte cache lines to prevent false sharing in multithreaded contexts. Pack variables in structs tightly (largest to smallest) to minimize padding waste. Use custom arena or pool allocators instead of global malloc/new for high-frequency allocations to avoid heap fragmentation and lock contention.",
        "C++ SRE / Optimization", {"C++", "memory", "cache-locality", "allocators"});

    run_mongo_insert("Lock-Free Multithreading (std::atomic)",
        "Avoid std::mutex in hot loops. Use std::atomic with explicit memory orders (std::memory_order_relaxed, std::memory_order_acquire, std::memory_order_release) for lock-free synchronization. Understand the ABA problem in lock-free data structures. Prefer message passing and thread-local storage over shared mutable state.",
        "C++ Architecture", {"C++", "multithreading", "lock-free", "concurrency"});

    run_mongo_insert("Win32 API & C++ System Integration",
        "When interacting with Windows natively, bypass C-runtime wrappers. Use raw Win32 APIs (CreateProcess, CreateThread, WaitForSingleObject, CreateFileMapping) for maximum control over security attributes, inherited handles, and creation flags (e.g., CREATE_NO_WINDOW). Always clean up HANDLEs using CloseHandle to avoid kernel resource leaks.",
        "Windows SRE / Optimization", {"C++", "win32", "windows", "system-calls"});
        
    std::cout << "[+] High-Performance C++ Architecture & Optimization nodes ingested into GodBrain.\n";
}

void ingest_terminology() {
    std::cout << "[*] Ingesting Core Terminology...\n";
    
    run_mongo_insert("[GODBRAIN CORE TERMINOLOGY: C++ SUPREMACY]",
        "SOURCE: Father Autismo\nTOPIC: Absolute Mandate for C++\n\nCORE DEFINITION:\n1. We do not just refactor code. We militarize the architecture.\n2. GodBrain strictly enforces Native C++ over Python, Rust, and JavaScript for kernel, router, and systems integration.\n3. Python scripts and wrappers are entirely banned from core systems.",
        "Terminology", {"c++", "terminology", "militarized-architecture", "zero-python"});
        
    std::cout << "[+] Hard-coded terminology into GodBrain.\n";
}

int main(int argc, char* argv[]) {
    std::cout << "[SYSTEM] Initializing C++ Native Data Ingestor...\n";
    ingest_cpp_expert();
    ingest_terminology();
    
    std::cout << "[+] Migration of script knowledge complete.\n";
    return 0;
}