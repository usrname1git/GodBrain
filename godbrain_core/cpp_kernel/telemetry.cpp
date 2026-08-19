#include "telemetry.h"
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <dxgi.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#pragma comment(lib, "pdh.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

namespace telemetry {
    static PDH_HQUERY cpuQuery = nullptr;
    static PDH_HCOUNTER cpuTotal = nullptr;

    constexpr size_t kMaxFixedVolumes = 16;

    std::string utf8_from_wide(const std::wstring& raw) {
        if (raw.empty()) return {};
        const int needed = WideCharToMultiByte(
            CP_UTF8, 0, raw.c_str(), static_cast<int>(raw.size()),
            nullptr, 0, nullptr, nullptr);
        if (needed <= 0) return {};
        std::string utf8(static_cast<size_t>(needed), '\0');
        WideCharToMultiByte(
            CP_UTF8, 0, raw.c_str(), static_cast<int>(raw.size()),
            utf8.data(), needed, nullptr, nullptr);
        return utf8;
    }

    std::string sanitize_volume_label(const wchar_t* raw) {
        std::wstring cleaned;
        for (const wchar_t* cursor = raw; cursor && *cursor != L'\0' &&
             cleaned.size() < 32; ++cursor) {
            if (*cursor >= 32 && *cursor != L'=' && *cursor != L'\n' &&
                *cursor != L'\r') {
                cleaned.push_back(*cursor);
            }
        }
        return utf8_from_wide(cleaned);
    }

    void scan_fixed_volumes(json& inventory, json& live) {
        inventory = json::array();
        live = json::array();
        wchar_t drives[512] = {};
        const DWORD written = GetLogicalDriveStringsW(511, drives);
        if (written == 0 || written >= 511) return;

        std::vector<std::wstring> roots;
        for (wchar_t* cursor = drives; *cursor != L'\0';
             cursor += std::wcslen(cursor) + 1) {
            roots.emplace_back(cursor);
        }
        std::sort(roots.begin(), roots.end());

        for (const auto& root : roots) {
            if (inventory.size() >= kMaxFixedVolumes) break;
            if (GetDriveTypeW(root.c_str()) != DRIVE_FIXED) continue;

            ULARGE_INTEGER free_bytes{};
            ULARGE_INTEGER total_bytes{};
            if (GetDiskFreeSpaceExW(root.c_str(), &free_bytes, &total_bytes, nullptr) == 0) {
                continue;
            }

            wchar_t label[33] = {};
            GetVolumeInformationW(
                root.c_str(), label, 33, nullptr, nullptr, nullptr, nullptr, 0);

            const char letter = root.empty() ? '?' : static_cast<char>(root[0]);
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

    std::string reg_sz(HKEY root, const wchar_t* subkey, const wchar_t* value) {
        wchar_t buffer[256];
        DWORD bytes = sizeof(buffer);
        DWORD type = 0;
        const LONG rc = RegGetValueW(
            root, subkey, value, RRF_RT_REG_SZ, &type, buffer, &bytes);
        if (rc != ERROR_SUCCESS || bytes < sizeof(wchar_t)) return "";
        const size_t chars = (bytes / sizeof(wchar_t)) - 1;
        return utf8_from_wide(std::wstring(buffer, chars));
    }

    DWORD reg_dword(HKEY root, const wchar_t* subkey, const wchar_t* value) {
        DWORD data = 0;
        DWORD bytes = sizeof(data);
        DWORD type = 0;
        const LONG rc = RegGetValueW(
            root, subkey, value, RRF_RT_REG_DWORD, &type, &data, &bytes);
        return rc == ERROR_SUCCESS ? data : 0;
    }

    json read_windows_pin() {
        const wchar_t* key = L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
        std::string edition = reg_sz(HKEY_LOCAL_MACHINE, key, L"EditionID");
        std::string build = reg_sz(HKEY_LOCAL_MACHINE, key, L"CurrentBuild");
        const DWORD ubr = reg_dword(HKEY_LOCAL_MACHINE, key, L"UBR");
        if (edition.empty()) edition = "unknown";
        if (build.empty()) build = "0";
        char pin[96];
        std::snprintf(
            pin, sizeof(pin), "%s/%s.%lu", edition.c_str(), build.c_str(),
            static_cast<unsigned long>(ubr));
        return {
            {"edition_id", edition},
            {"product_name", reg_sz(HKEY_LOCAL_MACHINE, key, L"ProductName")},
            {"display_version",
             reg_sz(HKEY_LOCAL_MACHINE, key, L"DisplayVersion")},
            {"current_build", build},
            {"ubr", static_cast<int>(ubr)},
            {"os_pin", std::string(pin)},
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

        const json pin = read_windows_pin();
        return {
            {"computer_name", std::string(name)},
            {"total_physical_ram_gb", total_ram_gb},
            {"logical_processors", static_cast<int>(system.dwNumberOfProcessors)},
            {"edition_id", pin.value("edition_id", "")},
            {"product_name", pin.value("product_name", "")},
            {"display_version", pin.value("display_version", "")},
            {"current_build", pin.value("current_build", "")},
            {"ubr", pin.value("ubr", 0)},
            {"os_pin", pin.value("os_pin", "")},
            {"volumes", volumes},
        };
    }

    std::string windows_pin() {
        return get_host_inventory().value("os_pin", "");
    }

    json get_tailscale() {
        json result = {
            {"up", false},
            {"ip", ""},
            {"adapter", ""},
            {"remember_url", ""},
            {"writes", "loopback_only"},
            {"bound", false},
            {"reason", "down"},
        };
        ULONG size = 16384;
        std::vector<unsigned char> buffer(size);
        auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        const ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                            GAA_FLAG_SKIP_DNS_SERVER;
        DWORD error = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
        if (error == ERROR_BUFFER_OVERFLOW) {
            buffer.assign(size, 0);
            adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
            error = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
        }
        if (error != NO_ERROR || adapters == nullptr) return result;

        for (IP_ADAPTER_ADDRESSES* adapter = adapters; adapter != nullptr;
             adapter = adapter->Next) {
            const std::string name = utf8_from_wide(
                adapter->FriendlyName ? adapter->FriendlyName : L"");
            const std::string description = utf8_from_wide(
                adapter->Description ? adapter->Description : L"");
            const bool named =
                name.find("Tailscale") != std::string::npos ||
                name.find("tailscale") != std::string::npos ||
                description.find("Tailscale") != std::string::npos ||
                description.find("tailscale") != std::string::npos;
            if (!named) continue;
            result["adapter"] = name;
            result["reason"] = "needs_login";
            for (IP_ADAPTER_UNICAST_ADDRESS* address = adapter->FirstUnicastAddress;
                 address != nullptr; address = address->Next) {
                if (address->Address.lpSockaddr == nullptr ||
                    address->Address.lpSockaddr->sa_family != AF_INET) {
                    continue;
                }
                const auto* ipv4 = reinterpret_cast<sockaddr_in*>(
                    address->Address.lpSockaddr);
                const unsigned long host = ntohl(ipv4->sin_addr.S_un.S_addr);
                const bool cgnat = (host & 0xFFC00000ul) == 0x64400000ul;
                if (!cgnat) continue;
                char ip[16] = {};
                std::snprintf(
                    ip, sizeof(ip), "%lu.%lu.%lu.%lu",
                    (host >> 24) & 255ul, (host >> 16) & 255ul,
                    (host >> 8) & 255ul, host & 255ul);
                result["up"] = true;
                result["ip"] = std::string(ip);
                result["adapter"] = name;
                result["reason"] = "up";
                result["remember_url"] =
                    std::string("http://") + ip + ":8083/api/remember";
                result["librarian_url"] =
                    std::string("http://") + ip + ":8083/api/librarian";
                result["brief_url"] =
                    std::string("http://") + ip + ":8083/api/brief";
                result["vram_url"] =
                    std::string("http://") + ip + ":8083/api/vram";
                result["heal_url"] =
                    std::string("http://") + ip + ":8083/api/heal";
                result["doors_url"] =
                    std::string("http://") + ip + ":8083/api/doors";
                result["desk_url"] =
                    std::string("http://") + ip + ":8083/api/desk";
                result["pending_url"] =
                    std::string("http://") + ip + ":8083/api/pending";
                result["last_edit_url"] =
                    std::string("http://") + ip + ":8083/api/last-edit";
                return result;
            }
        }
        return result;
    }

    json get_gpu_memory() {
        json adapters = json::array();
        IDXGIFactory* factory = nullptr;
        if (FAILED(CreateDXGIFactory(__uuidof(IDXGIFactory), reinterpret_cast<void**>(&factory))) ||
            factory == nullptr) {
            return {{"adapters", adapters}, {"dedicated_gb", 0}};
        }

        int best_gb = 0;
        std::string best_name;
        for (UINT index = 0;; ++index) {
            IDXGIAdapter* adapter = nullptr;
            if (factory->EnumAdapters(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
            if (adapter == nullptr) continue;
            DXGI_ADAPTER_DESC description{};
            if (SUCCEEDED(adapter->GetDesc(&description)) &&
                description.DedicatedVideoMemory > 0) {
                char name[128] = {};
                WideCharToMultiByte(
                    CP_UTF8, 0, description.Description, -1, name, sizeof(name),
                    nullptr, nullptr);
                const int dedicated_gb = static_cast<int>(
                    (description.DedicatedVideoMemory + 512ull * 1024ull * 1024ull) /
                    (1024ull * 1024ull * 1024ull));
                adapters.push_back({
                    {"name", std::string(name)},
                    {"dedicated_gb", dedicated_gb},
                });
                if (dedicated_gb > best_gb &&
                    std::string(name).find("Microsoft") == std::string::npos) {
                    best_gb = dedicated_gb;
                    best_name = name;
                }
            }
            adapter->Release();
        }
        factory->Release();
        return {
            {"adapters", adapters},
            {"name", best_name},
            {"dedicated_gb", best_gb},
        };
    }

    json plan_colibri_vram() {
        const json gpu = get_gpu_memory();
        int dedicated_gb = gpu.value("dedicated_gb", 0);
        if (dedicated_gb < 0) dedicated_gb = 0;

        char* override_expert = nullptr;
        size_t override_len = 0;
        int expert_gb = 0;
        bool expert_overridden = false;
        if (_dupenv_s(&override_expert, &override_len, "GODBRAIN_CUDA_EXPERT_GB") == 0 &&
            override_expert != nullptr) {
            expert_gb = std::atoi(override_expert);
            expert_overridden = expert_gb > 0;
            std::free(override_expert);
        }

        // 16 GB cards need ~4 GB for KV, CUDA workspace, and the desktop.
        // Bigger cards can spare more for experts and still leave a buffer.
        const int reserve_gb = dedicated_gb <= 16 ? 4 : 6;
        if (!expert_overridden) {
            expert_gb = dedicated_gb > reserve_gb ? dedicated_gb - reserve_gb : 2;
            if (expert_gb < 2) expert_gb = 2;
        }

        char* overcommit_env = nullptr;
        size_t overcommit_len = 0;
        bool overcommit = false;
        if (_dupenv_s(&overcommit_env, &overcommit_len, "GODBRAIN_COLI_OVERCOMMIT") == 0 &&
            overcommit_env != nullptr) {
            overcommit = std::string(overcommit_env) == "1";
            std::free(overcommit_env);
        }

        return {
            {"name", gpu.value("name", "")},
            {"dedicated_gb", dedicated_gb},
            {"reserve_gb", reserve_gb},
            {"expert_gb", expert_gb},
            {"overcommit", overcommit},
            {"adapters", gpu.value("adapters", json::array())},
        };
    }
}
