#include "telemetry.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pdh.h>
#include <pdhmsg.h>

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
}
