#include "telemetry.h"
#include "host_observation.h"
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
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <optional>
#include <stdexcept>
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

    std::optional<std::uint32_t> reg_dword(HKEY root, const wchar_t* subkey, const wchar_t* value) {
        DWORD data = 0;
        DWORD bytes = sizeof(data);
        DWORD type = 0;
        const LONG rc = RegGetValueW(
            root, subkey, value, RRF_RT_REG_DWORD, &type, &data, &bytes);
        if (rc != ERROR_SUCCESS || bytes != sizeof(data)) return std::nullopt;
        return static_cast<std::uint32_t>(data);
    }

    json read_windows_pin() {
        const wchar_t* key = L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
        std::string edition = reg_sz(HKEY_LOCAL_MACHINE, key, L"EditionID");
        std::string build = reg_sz(HKEY_LOCAL_MACHINE, key, L"CurrentBuild");
        const auto ubr = reg_dword(HKEY_LOCAL_MACHINE, key, L"UBR");
        const std::string pin = godbrain_host::make_windows_pin(edition, build, ubr);
        return {
            {"edition_id", edition},
            {"product_name", reg_sz(HKEY_LOCAL_MACHINE, key, L"ProductName")},
            {"display_version",
             reg_sz(HKEY_LOCAL_MACHINE, key, L"DisplayVersion")},
            {"current_build", build},
            {"ubr", *ubr},
            {"os_pin", pin},
        };
    }

    std::string get_computer_name() {
        char name[MAX_COMPUTERNAME_LENGTH + 1] = {};
        DWORD name_size = MAX_COMPUTERNAME_LENGTH + 1;
        if (GetComputerNameA(name, &name_size) == 0) {
            throw std::runtime_error("Host computer name could not be read");
        }
        return std::string(name);
    }

    json get_host_inventory() {
        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        if (!GlobalMemoryStatusEx(&memory)) {
            throw std::runtime_error("Host physical memory could not be read");
        }
        const int total_ram_gb = static_cast<int>(
            memory.ullTotalPhys / (1024ull * 1024ull * 1024ull));

        SYSTEM_INFO system{};
        GetSystemInfo(&system);

        json volumes = json::array();
        json volume_live = json::array();
        scan_fixed_volumes(volumes, volume_live);

        const json pin = read_windows_pin();
        return {
            {"computer_name", get_computer_name()},
            {"total_physical_ram_gb", total_ram_gb},
            {"logical_processors", static_cast<int>(system.dwNumberOfProcessors)},
            {"edition_id", pin.value("edition_id", "")},
            {"product_name", pin.value("product_name", "")},
            {"display_version", pin.value("display_version", "")},
            {"current_build", pin.value("current_build", "")},
            {"ubr", pin.at("ubr")},
            {"os_pin", pin.value("os_pin", "")},
            {"volumes", volumes},
        };
    }

    json parse_smbios_memory(const std::vector<unsigned char>& bytes) {
        if (bytes.size() < 8) throw std::runtime_error("SMBIOS header is missing");
        uint32_t length = 0;
        std::memcpy(&length, bytes.data() + 4, sizeof(length));
        if (length > bytes.size() - 8) throw std::runtime_error("SMBIOS table is truncated");
        const size_t end = 8 + static_cast<size_t>(length);
        json devices = json::array();
        size_t at = 8, structures = 0;
        while (at + 4 <= end && ++structures <= 2048) {
            const auto type = bytes[at];
            const size_t size = bytes[at + 1];
            if (size < 4 || size > end - at) throw std::runtime_error("SMBIOS structure is truncated");
            size_t strings_end = at + size;
            while (strings_end + 1 < end &&
                   (bytes[strings_end] != 0 || bytes[strings_end + 1] != 0)) ++strings_end;
            if (strings_end + 1 >= end) throw std::runtime_error("SMBIOS strings are unterminated");
            const auto string_at = [&](size_t field) -> json {
                if (field >= size || bytes[at + field] == 0) return nullptr;
                const unsigned int wanted = bytes[at + field];
                size_t start = at + size;
                for (unsigned int n = 1; start < strings_end && n <= wanted; ++n) {
                    size_t stop = start;
                    while (stop < strings_end && bytes[stop]) ++stop;
                    if (n == wanted) {
                        const std::string value(
                            reinterpret_cast<const char*>(bytes.data() + start), stop - start);
                        try {
                            (void)json(value).dump();
                        } catch (const json::exception&) {
                            throw std::runtime_error("SMBIOS string is not valid UTF-8");
                        }
                        return value;
                    }
                    start = stop + 1;
                }
                throw std::runtime_error("SMBIOS string index is invalid");
            };
            const auto word_at = [&](size_t field) -> uint16_t {
                uint16_t value = 0;
                std::memcpy(&value, bytes.data() + at + field, sizeof(value));
                return value;
            };
            if (type == 17 && size >= 21 && word_at(12) != 0) {
                const uint16_t raw_size = word_at(12);
                json capacity = nullptr;
                if (raw_size == 0x7fff) {
                    if (size < 32) throw std::runtime_error("SMBIOS extended memory size is missing");
                    uint32_t mb = 0;
                    std::memcpy(&mb, bytes.data() + at + 28, sizeof(mb));
                    capacity = static_cast<uint64_t>(mb & 0x7fffffff) * 1024 * 1024;
                } else if (raw_size != 0xffff) {
                    capacity = static_cast<uint64_t>(raw_size & 0x7fff) *
                               ((raw_size & 0x8000) ? 1024ull : 1024ull * 1024ull);
                }
                const auto speed = [&](size_t field) -> json {
                    if (size < field + 2) return nullptr;
                    const auto value = word_at(field);
                    return value == 0 || value == 0xffff ? json(nullptr) : json(value);
                };
                devices.push_back({
                    {"device", string_at(16)}, {"bank", string_at(17)},
                    {"manufacturer", string_at(23)}, {"part_number", string_at(26)},
                    {"capacity_bytes", capacity}, {"rated_speed_mt_s", speed(21)},
                    {"configured_speed_mt_s", speed(32)},
                });
            }
            at = strings_end + 2;
            if (type == 127) return devices;
        }
        if (at != end || structures > 2048) throw std::runtime_error("SMBIOS table has invalid framing");
        return devices;
    }

    json get_host_profile() {
        json profile = get_host_inventory();
        profile["probe_errors"] = json::array();
        const auto registry = [&](const wchar_t* key, const wchar_t* name, const char* label) -> json {
            const auto value = reg_sz(HKEY_LOCAL_MACHINE, key, name);
            if (!value.empty()) return value;
            profile["probe_errors"].push_back(std::string(label) + " is unavailable");
            return nullptr;
        };
        const wchar_t* bios = L"HARDWARE\\DESCRIPTION\\System\\BIOS";
        profile["cpu"] = registry(L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                                  L"ProcessorNameString", "CPU model");
        profile["baseboard"] = {
            {"manufacturer", registry(bios, L"BaseBoardManufacturer", "Board manufacturer")},
            {"product", registry(bios, L"BaseBoardProduct", "Board product")},
            {"version", registry(bios, L"BaseBoardVersion", "Board version")},
        };
        profile["bios"] = {
            {"vendor", registry(bios, L"BIOSVendor", "BIOS vendor")},
            {"version", registry(bios, L"BIOSVersion", "BIOS version")},
            {"release_date", registry(bios, L"BIOSReleaseDate", "BIOS date")},
        };
        profile["gpus"] = json::array();
        IDXGIFactory1* factory = nullptr;
        const HRESULT factory_result = CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                                          reinterpret_cast<void**>(&factory));
        if (FAILED(factory_result)) {
            profile["probe_errors"].push_back("DXGI adapter enumeration failed: " + std::to_string(factory_result));
        } else {
            for (UINT n = 0; n < 16; ++n) {
                IDXGIAdapter1* adapter = nullptr;
                const HRESULT enumerated = factory->EnumAdapters1(n, &adapter);
                if (enumerated == DXGI_ERROR_NOT_FOUND) break;
                if (FAILED(enumerated)) {
                    profile["probe_errors"].push_back("DXGI adapter read failed: " + std::to_string(enumerated));
                    break;
                }
                DXGI_ADAPTER_DESC1 desc{};
                const HRESULT described = adapter->GetDesc1(&desc);
                adapter->Release();
                if (FAILED(described)) {
                    profile["probe_errors"].push_back("DXGI adapter description failed");
                    continue;
                }
                if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
                profile["gpus"].push_back({
                    {"name", utf8_from_wide(desc.Description)},
                    {"dedicated_vram_bytes", static_cast<uint64_t>(desc.DedicatedVideoMemory)},
                    {"vendor_id", desc.VendorId}, {"device_id", desc.DeviceId},
                });
            }
            factory->Release();
        }
        const UINT bytes = GetSystemFirmwareTable(0x52534D42, 0, nullptr, 0);
        if (bytes < 8 || bytes > 1024 * 1024) {
            profile["memory_devices"] = nullptr;
            profile["probe_errors"].push_back("SMBIOS memory table is unavailable or oversized");
        } else {
            std::vector<unsigned char> table(bytes);
            if (GetSystemFirmwareTable(0x52534D42, 0, table.data(), bytes) != bytes) {
                profile["memory_devices"] = nullptr;
                profile["probe_errors"].push_back("SMBIOS memory table could not be read completely");
            } else {
                try {
                    profile["memory_devices"] = parse_smbios_memory(table);
                } catch (const std::runtime_error& error) {
                    profile["memory_devices"] = nullptr;
                    profile["probe_errors"].push_back(error.what());
                }
            }
        }
        profile["complete"] = profile["probe_errors"].empty();
        profile["limits"] = "Firmware-reported DIMM speeds are not live clocks. Timings, voltages and BIOS settings are not inferred.";
        return profile;
    }

    std::string windows_pin() {
        return read_windows_pin().value("os_pin", "");
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

    bool tcp_loopback_open(int port, int timeout_ms) {
        if (port <= 0 || port > 65535) return false;
        if (timeout_ms < 50) timeout_ms = 50;
        // Extra WSAStartup is refcounted. Never WSACleanup here: httplib owns the count.
        // call_once so concurrent /api/status probes do not race the first init.
        static std::once_flag wsa_once;
        static bool wsa_ok = false;
        std::call_once(wsa_once, [] {
            WSADATA wsa{};
            wsa_ok = WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
        });
        if (!wsa_ok) return false;
        const SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) return false;
        u_long nonblock = 1;
        ioctlsocket(sock, FIONBIO, &nonblock);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<u_short>(port));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bool open = false;
        const int rc = connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (rc == 0) {
            open = true;
        } else if (WSAGetLastError() == WSAEWOULDBLOCK) {
            fd_set writable;
            FD_ZERO(&writable);
            FD_SET(sock, &writable);
            timeval wait{};
            wait.tv_sec = timeout_ms / 1000;
            wait.tv_usec = (timeout_ms % 1000) * 1000;
            if (select(0, nullptr, &writable, nullptr, &wait) > 0) {
                int so_error = 0;
                int so_len = sizeof(so_error);
                getsockopt(sock, SOL_SOCKET, SO_ERROR,
                           reinterpret_cast<char*>(&so_error), &so_len);
                open = (so_error == 0);
            }
        }
        closesocket(sock);
        return open;
    }
}
