#include "telemetry.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "pdh.lib")

namespace telemetry {
    static PDH_HQUERY cpuQuery = nullptr;
    static PDH_HCOUNTER cpuTotal = nullptr;

    constexpr size_t kMaxFixedVolumes = 16;

    std::string sanitize_volume_label(const char* raw) {
        std::string label;
        for (const char* cursor = raw; *cursor != '\0' && label.size() < 32; ++cursor) {
            const unsigned char character = static_cast<unsigned char>(*cursor);
            if (character >= 32 && character != '=' && character != '\n' &&
                character != '\r') {
                label.push_back(static_cast<char>(character));
            }
        }
        return label;
    }

    void scan_fixed_volumes(json& inventory, json& live) {
        inventory = json::array();
        live = json::array();
        char drives[512] = {};
        const DWORD written = GetLogicalDriveStringsA(sizeof(drives) - 1, drives);
        if (written == 0 || written >= sizeof(drives)) return;

        std::vector<std::string> roots;
        for (char* cursor = drives; *cursor != '\0'; cursor += std::strlen(cursor) + 1) {
            roots.emplace_back(cursor);
        }
        std::sort(roots.begin(), roots.end());

        for (const auto& root : roots) {
            if (inventory.size() >= kMaxFixedVolumes) break;
            if (GetDriveTypeA(root.c_str()) != DRIVE_FIXED) continue;

            ULARGE_INTEGER free_bytes{};
            ULARGE_INTEGER total_bytes{};
            if (GetDiskFreeSpaceExA(root.c_str(), &free_bytes, &total_bytes, nullptr) == 0) {
                continue;
            }

            char label[MAX_PATH] = {};
            GetVolumeInformationA(
                root.c_str(), label, MAX_PATH, nullptr, nullptr, nullptr, nullptr, 0);

            const char letter = root.empty() ? '?' : root[0];
            const int total_gb = static_cast<int>(
                total_bytes.QuadPart / (1024ull * 1024ull * 1024ull));
            const double free_gb =
                static_cast<double>(free_bytes.QuadPart) / (1024.0 * 1024.0 * 1024.0);

            inventory.push_back({
                {"letter", std::string(1, letter)},
                {"type", "fixed"},
                {"label", sanitize_volume_label(label)},
                {"total_gb", total_gb},
            });
            live.push_back({
                {"letter", std::string(1, letter)},
                {"free_gb", free_gb},
            });
        }
    }

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

        json volume_inventory = json::array();
        json volume_live = json::array();
        scan_fixed_volumes(volume_inventory, volume_live);

        return {
            {"status", "Telemetry retrieved"},
            {"system_ram_percent", mem_percent},
            {"ram_available_gb", ram_available_gb},
            {"cpu_percent", cpu_percent},
            {"volume_free_gb", volume_live}
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

        json volumes = json::array();
        json volume_live = json::array();
        scan_fixed_volumes(volumes, volume_live);

        return {
            {"computer_name", std::string(name)},
            {"total_physical_ram_gb", total_ram_gb},
            {"logical_processors", static_cast<int>(system.dwNumberOfProcessors)},
            {"volumes", volumes},
        };
    }
}
