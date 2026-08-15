#include "telemetry.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <string>

#pragma comment(lib, "pdh.lib")

namespace telemetry {
    static PDH_HQUERY cpuQuery = nullptr;
    static PDH_HCOUNTER cpuTotal = nullptr;

    void init_cpu_monitoring() {
        if (!cpuQuery) {
            PdhOpenQuery(NULL, NULL, &cpuQuery);
            PdhAddEnglishCounter(cpuQuery, "\\Processor(_Total)\\% Processor Time", NULL, &cpuTotal);
            PdhCollectQueryData(cpuQuery);
        }
    }

    json get_current_state() {
        init_cpu_monitoring();
        
        // RAM
        MEMORYSTATUSEX memInfo;
        memInfo.dwLength = sizeof(MEMORYSTATUSEX);
        GlobalMemoryStatusEx(&memInfo);
        
        double ram_available_gb = (double)memInfo.ullAvailPhys / (1024.0 * 1024.0 * 1024.0);
        int mem_percent = memInfo.dwMemoryLoad;

        // CPU
        PdhCollectQueryData(cpuQuery);
        PDH_FMT_COUNTERVALUE counterVal;
        PdhGetFormattedCounterValue(cpuTotal, PDH_FMT_DOUBLE, NULL, &counterVal);
        double cpu_percent = counterVal.doubleValue;

        return {
            {"status", "Telemetry retrieved"},
            {"system_ram_percent", mem_percent},
            {"ram_available_gb", ram_available_gb},
            {"cpu_percent", cpu_percent}
        };
    }

    json get_host_inventory() {
        char name[MAX_COMPUTERNAME_LENGTH + 1] = {};
        DWORD name_size = MAX_COMPUTERNAME_LENGTH + 1;
        if (GetComputerNameA(name, &name_size) == 0) {
            name[0] = '?';
            name[1] = '\0';
        }

        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        GlobalMemoryStatusEx(&memory);
        const int total_ram_gb = static_cast<int>(
            memory.ullTotalPhys / (1024ull * 1024ull * 1024ull));

        SYSTEM_INFO system{};
        GetSystemInfo(&system);

        return {
            {"computer_name", std::string(name)},
            {"total_physical_ram_gb", total_ram_gb},
            {"logical_processors", static_cast<int>(system.dwNumberOfProcessors)},
        };
    }
}
