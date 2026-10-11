#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shlobj.h>
#include "../cpp_kernel/json.hpp"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <numeric>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

using json = nlohmann::json;
namespace fs = std::filesystem;
static constexpr size_t max_bytes = 1024 * 1024;
static constexpr size_t max_displays = 16;

static void require(bool condition, const std::string& error) {
    if (!condition) throw std::runtime_error(error);
}
static void win_check(LONG result, const char* operation) {
    require(result == ERROR_SUCCESS, std::string(operation) + " failed (Windows error " + std::to_string(result) + ")");
}
static std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    require(size > 0, "Invalid Windows text");
    std::string result(static_cast<size_t>(size), '\0');
    require(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), result.data(), size, nullptr, nullptr) == size, "Windows text conversion failed");
    return result;
}
static std::wstring wide(const std::string& text) {
    require(!text.empty() && text.size() <= max_bytes, "Invalid UTF-8 text length");
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0);
    require(size > 0, "Invalid UTF-8 text");
    std::wstring result(static_cast<size_t>(size), L'\0');
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), result.data(), size) == size, "UTF-8 conversion failed");
    return result;
}
static std::string folded(const std::string& text) {
    auto value = wide(text);
    require(CharUpperBuffW(value.data(), static_cast<DWORD>(value.size())) != 0, "Identity normalization failed");
    return utf8(value);
}
static void keys(const json& value, std::initializer_list<const char*> expected) {
    require(value.is_object() && value.size() == expected.size(), "Invalid profile object fields");
    for (const auto key : expected) require(value.contains(key), std::string("Missing profile field: ") + key);
}
static int64_t integer(const json& value, int64_t low, int64_t high) {
    require(value.is_number_integer(), "Profile integer required");
    if (value.is_number_unsigned()) require(value.get<uint64_t>() <= static_cast<uint64_t>(high), "Profile integer overflow");
    const auto result = value.get<int64_t>();
    require(result >= low && result <= high, "Profile number is outside its allowed range");
    return result;
}
static std::string text(const json& value, size_t maximum) {
    require(value.is_string(), "Profile string required");
    const auto result = value.get<std::string>();
    require(!result.empty() && result.size() <= maximum && result.find('\0') == std::string::npos, "Invalid profile text");
    wide(result);
    return result;
}
static void name_valid(const std::string& name) {
    const auto value = wide(name);
    require(value.size() <= 64 && value.front() != L' ' && value.back() != L' ', "Profile names must contain 1-64 characters, without outer spaces");
    for (const auto c : value) require(c >= 32 && c != 127 && std::wstring(L"<>:\"/\\|?*").find(c) == std::wstring::npos,
        "Profile name contains a control or path character");
}
static json ratio_json(DISPLAYCONFIG_RATIONAL value) {
    return json::array({value.Numerator, value.Denominator});
}
static DISPLAYCONFIG_RATIONAL ratio(const json& value) {
    require(value.is_array() && value.size() == 2, "Invalid refresh/timing ratio");
    return {static_cast<UINT32>(integer(value[0], 1, UINT32_MAX)), static_cast<UINT32>(integer(value[1], 1, UINT32_MAX))};
}
static json point_json(POINTL value) { return json::array({value.x, value.y}); }
static POINTL point(const json& value, bool positive = false) {
    require(value.is_array() && value.size() == 2, "Invalid display point");
    return {static_cast<LONG>(integer(value[0], positive ? 1 : -131072, 131072)),
        static_cast<LONG>(integer(value[1], positive ? 1 : -131072, 131072))};
}
static json rect_json(RECTL value) { return json::array({value.left, value.top, value.right, value.bottom}); }
static RECTL rect(const json& value) {
    require(value.is_array() && value.size() == 4, "Invalid desktop rectangle");
    RECTL result{static_cast<LONG>(integer(value[0], -131072, 131072)), static_cast<LONG>(integer(value[1], -131072, 131072)),
        static_cast<LONG>(integer(value[2], -131072, 131072)), static_cast<LONG>(integer(value[3], -131072, 131072))};
    require(result.right >= result.left && result.bottom >= result.top, "Inverted desktop rectangle");
    return result;
}
static json source_json(const DISPLAYCONFIG_SOURCE_MODE& value) {
    return {{"width", value.width}, {"height", value.height}, {"pixel_format", value.pixelFormat}, {"position", point_json(value.position)}};
}
static DISPLAYCONFIG_SOURCE_MODE source_mode(const json& value) {
    keys(value, {"width", "height", "pixel_format", "position"});
    return {static_cast<UINT32>(integer(value["width"], 1, 32768)), static_cast<UINT32>(integer(value["height"], 1, 32768)),
        static_cast<DISPLAYCONFIG_PIXELFORMAT>(integer(value["pixel_format"], 1, 4)), point(value["position"])};
}
static json signal_json(const DISPLAYCONFIG_VIDEO_SIGNAL_INFO& value) {
    return {{"pixel_rate", value.pixelRate}, {"h_sync", ratio_json(value.hSyncFreq)}, {"v_sync", ratio_json(value.vSyncFreq)},
        {"active", json::array({value.activeSize.cx, value.activeSize.cy})},
        {"total", json::array({value.totalSize.cx, value.totalSize.cy})},
        {"standard", value.videoStandard}, {"scan", value.scanLineOrdering}};
}
static DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal_mode(const json& value, bool database = false) {
    keys(value, {"pixel_rate", "h_sync", "v_sync", "active", "total", "standard", "scan"});
    DISPLAYCONFIG_VIDEO_SIGNAL_INFO result{};
    result.pixelRate = static_cast<UINT64>(integer(value["pixel_rate"], 1, INT64_MAX));
    result.hSyncFreq = ratio(value["h_sync"]); result.vSyncFreq = ratio(value["v_sync"]);
    const auto active = point(value["active"], true), total = point(value["total"]);
    // QDC_DATABASE_CURRENT intentionally returns zero totalSize; live profiles may not.
    const bool database_total = database && total.x == 0 && total.y == 0;
    require(database_total || (total.x >= active.x && total.y >= active.y), "Display timing is smaller than its active region");
    result.activeSize = {static_cast<UINT32>(active.x), static_cast<UINT32>(active.y)};
    result.totalSize = {static_cast<UINT32>(total.x), static_cast<UINT32>(total.y)};
    result.videoStandard = static_cast<UINT32>(integer(value["standard"], 0, UINT32_MAX));
    result.scanLineOrdering = static_cast<DISPLAYCONFIG_SCANLINE_ORDERING>(integer(value["scan"], 0, 3));
    return result;
}
static json desktop_json(const DISPLAYCONFIG_DESKTOP_IMAGE_INFO& value) {
    return {{"source_size", point_json(value.PathSourceSize)}, {"region", rect_json(value.DesktopImageRegion)}, {"clip", rect_json(value.DesktopImageClip)}};
}
static DISPLAYCONFIG_DESKTOP_IMAGE_INFO desktop_mode(const json& value) {
    keys(value, {"source_size", "region", "clip"});
    return {point(value["source_size"], true), rect(value["region"]), rect(value["clip"])};
}
struct Configuration {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    bool refresh_aware = true;
};
static Configuration query(UINT32 kind) {
    Configuration result;
    for (unsigned attempt = 0; attempt < 5; ++attempt) {
        const UINT32 flags = kind | QDC_VIRTUAL_MODE_AWARE | (result.refresh_aware ? QDC_VIRTUAL_REFRESH_RATE_AWARE : 0);
        UINT32 paths = 0, modes = 0;
        LONG status = GetDisplayConfigBufferSizes(flags, &paths, &modes);
        if (status == ERROR_INVALID_PARAMETER && result.refresh_aware) { result.refresh_aware = false; continue; }
        win_check(status, "Display buffer sizes");
        require(paths > 0 && paths <= 512 && modes <= 1024, "Unexpected display configuration size");
        result.paths.resize(paths); result.modes.resize(std::max(1u, modes));
        DISPLAYCONFIG_TOPOLOGY_ID topology{};
        status = QueryDisplayConfig(flags, &paths, result.paths.data(), &modes, result.modes.data(),
            kind == QDC_DATABASE_CURRENT ? &topology : nullptr);
        if (status == ERROR_INSUFFICIENT_BUFFER) continue;
        win_check(status, "Query display configuration");
        result.paths.resize(paths); result.modes.resize(modes);
        return result;
    }
    throw std::runtime_error("Display configuration kept changing during enumeration");
}
static bool same_luid(LUID a, LUID b) { return a.LowPart == b.LowPart && a.HighPart == b.HighPart; }
static std::string adapter_name(LUID adapter) {
    DISPLAYCONFIG_ADAPTER_NAME value{};
    value.header = {DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME, sizeof(value), adapter, 0};
    win_check(DisplayConfigGetDeviceInfo(&value.header), "Display adapter identity");
    return utf8(value.adapterDevicePath);
}
struct Identity { std::string device, adapter, name; };
static Identity identity(const DISPLAYCONFIG_PATH_INFO& path) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME value{};
    value.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(value), path.targetInfo.adapterId, path.targetInfo.id};
    win_check(DisplayConfigGetDeviceInfo(&value.header), "Monitor identity");
    require(value.monitorDevicePath[0] != 0, "Monitor has no stable device identity");
    auto name = utf8(value.monitorFriendlyDeviceName);
    if (name.empty()) name = "Unnamed monitor";
    return {utf8(value.monitorDevicePath), adapter_name(path.targetInfo.adapterId), name};
}
static bool virtual_path(const DISPLAYCONFIG_PATH_INFO& path) { return (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE) != 0; }
static const DISPLAYCONFIG_MODE_INFO& get_mode(const Configuration& config, UINT32 index, DISPLAYCONFIG_MODE_INFO_TYPE type, LUID adapter, UINT32 id) {
    require(index < config.modes.size(), "Display path references a missing mode");
    const auto& mode = config.modes[index];
    require(mode.infoType == type && same_luid(mode.adapterId, adapter) && mode.id == id, "Display mode identity mismatch");
    return mode;
}
static json capture(const Configuration& config, const std::string& name) {
    name_valid(name);
    json displays = json::array();
    std::map<std::string, unsigned> groups;
    for (const auto& path : config.paths) {
        if (!(path.flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
        const auto device = identity(path);
        const bool virt = virtual_path(path);
        const UINT32 si = virt ? path.sourceInfo.sourceModeInfoIdx : path.sourceInfo.modeInfoIdx;
        const UINT32 ti = virt ? path.targetInfo.targetModeInfoIdx : path.targetInfo.modeInfoIdx;
        const auto& source = get_mode(config, si, DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE, path.sourceInfo.adapterId, path.sourceInfo.id);
        const auto& target = get_mode(config, ti, DISPLAYCONFIG_MODE_INFO_TYPE_TARGET, path.targetInfo.adapterId, path.targetInfo.id);
        require(same_luid(path.sourceInfo.adapterId, path.targetInfo.adapterId), "Cross-adapter display path is unsupported");
        const auto key = folded(device.adapter) + ":" + std::to_string(path.sourceInfo.id);
        const auto inserted = groups.emplace(key, static_cast<unsigned>(groups.size()));
        json desktop = nullptr;
        if (virt && path.targetInfo.desktopModeInfoIdx != DISPLAYCONFIG_PATH_DESKTOP_IMAGE_IDX_INVALID)
            desktop = desktop_json(get_mode(config, path.targetInfo.desktopModeInfoIdx, DISPLAYCONFIG_MODE_INFO_TYPE_DESKTOP_IMAGE,
                path.targetInfo.adapterId, path.targetInfo.id).desktopImageInfo);
        displays.push_back({{"device", device.device}, {"adapter", device.adapter}, {"label", device.name},
            {"group", inserted.first->second}, {"source", source_json(source.sourceMode)}, {"signal", signal_json(target.targetMode.targetVideoSignalInfo)},
            {"rotation", path.targetInfo.rotation}, {"scaling", path.targetInfo.scaling}, {"refresh", ratio_json(path.targetInfo.refreshRate)},
            {"scan", path.targetInfo.scanLineOrdering}, {"boost", (path.flags & DISPLAYCONFIG_PATH_BOOST_REFRESH_RATE) != 0},
            {"virtual", virt}, {"desktop", desktop}});
    }
    return {{"name", name}, {"hotkey", 0}, {"refresh_aware", config.refresh_aware}, {"displays", displays}};
}
static void profile_valid(const json& value, bool database = false) {
    keys(value, {"name", "hotkey", "refresh_aware", "displays"});
    name_valid(text(value["name"], 256));
    integer(value["hotkey"], 0, 12);
    require(value["refresh_aware"].is_boolean(), "Invalid refresh-awareness flag");
    const auto& displays = value["displays"];
    require(displays.is_array() && !displays.empty() && displays.size() <= max_displays, "A profile needs 1-16 active displays");
    std::set<std::string> devices;
    std::map<int64_t, std::pair<std::string, json>> groups;
    bool primary = false;
    for (const auto& display : displays) {
        keys(display, {"device", "adapter", "label", "group", "source", "signal", "rotation", "scaling", "refresh", "scan", "boost", "virtual", "desktop"});
        const auto device = folded(text(display["device"], 512)), adapter = folded(text(display["adapter"], 512));
        text(display["label"], 256);
        require(devices.insert(device).second, "Duplicate monitor identity in profile");
        const auto group = integer(display["group"], 0, max_displays - 1);
        const auto source = source_mode(display["source"]);
        signal_mode(display["signal"], database); ratio(display["refresh"]);
        integer(display["rotation"], 1, 4); integer(display["scan"], 0, 3);
        const auto scaling = integer(display["scaling"], 1, 128);
        require(scaling <= 5 || scaling == 128, "Unsupported display scaling");
        require(display["virtual"].is_boolean() && display["boost"].is_boolean(), "Invalid display mode flags");
        require(!display["boost"].get<bool>() || value["refresh_aware"].get<bool>(), "Boost refresh requires an aware profile");
        if (!display["desktop"].is_null()) { require(display["virtual"].get<bool>(), "Desktop image requires virtual mode"); desktop_mode(display["desktop"]); }
        const auto inserted = groups.emplace(group, std::make_pair(adapter, display["source"]));
        require(inserted.second || inserted.first->second == std::make_pair(adapter, display["source"]), "Clone source modes disagree");
        primary = primary || (source.position.x == 0 && source.position.y == 0);
    }
    require(primary, "A profile must retain a primary display at desktop origin");
}
struct Candidate {
    DISPLAYCONFIG_PATH_INFO path;
    Identity id;
};
static std::vector<Candidate> candidates(const Configuration& config) {
    std::vector<Candidate> result;
    std::map<std::string, Identity> cache;
    for (const auto& path : config.paths) {
        if (!path.targetInfo.targetAvailable) continue;
        const auto key = std::to_string(path.targetInfo.adapterId.HighPart) + ":" +
            std::to_string(path.targetInfo.adapterId.LowPart) + ":" + std::to_string(path.targetInfo.id);
        auto found = cache.find(key);
        if (found == cache.end()) found = cache.emplace(key, identity(path)).first;
        result.push_back({path, found->second});
    }
    return result;
}
static Configuration resolve(const json& profile, const std::vector<Candidate>& available, bool refresh_aware, bool database = false) {
    profile_valid(profile, database);
    require(!profile["refresh_aware"].get<bool>() || refresh_aware, "This Windows session cannot restore virtual refresh rates");
    const auto& displays = profile["displays"];
    std::vector<std::vector<size_t>> matches(displays.size());
    std::map<int, std::set<UINT32>> options;
    std::map<int, std::string> adapters;
    for (size_t d = 0; d < displays.size(); ++d) {
        const auto& display = displays[d];
        std::set<std::string> targets;
        std::set<UINT32> sources;
        for (size_t c = 0; c < available.size(); ++c) {
            const auto& candidate = available[c];
            if (folded(candidate.id.device) != folded(display["device"]) || folded(candidate.id.adapter) != folded(display["adapter"])) continue;
            targets.insert(std::to_string(candidate.path.targetInfo.adapterId.HighPart) + ":" +
                std::to_string(candidate.path.targetInfo.adapterId.LowPart) + ":" + std::to_string(candidate.path.targetInfo.id));
            require(virtual_path(candidate.path) == display["virtual"].get<bool>(), "Monitor virtual-mode support changed; recapture the profile");
            matches[d].push_back(c); sources.insert(candidate.path.sourceInfo.id);
        }
        require(!matches[d].empty(), "Missing or disconnected monitor: " + display["label"].get<std::string>());
        require(targets.size() == 1, "Ambiguous current monitor identity: " + display["label"].get<std::string>());
        const int group = display["group"].get<int>();
        adapters[group] = folded(display["adapter"]);
        auto found = options.find(group);
        if (found == options.end()) options.emplace(group, sources);
        else {
            std::set<UINT32> common;
            std::set_intersection(found->second.begin(), found->second.end(), sources.begin(), sources.end(), std::inserter(common, common.end()));
            found->second = std::move(common);
        }
    }
    std::vector<int> order;
    for (const auto& option : options) order.push_back(option.first);
    std::sort(order.begin(), order.end(), [&](int a, int b) { return options.at(a).size() < options.at(b).size(); });
    std::map<int, UINT32> assignment;
    std::set<std::pair<std::string, UINT32>> used;
    unsigned visits = 0;
    std::function<bool(size_t)> assign = [&](size_t at) {
        require(++visits <= 4096, "Display source matching exceeds its bound");
        if (at == order.size()) return true;
        const int group = order[at];
        for (const auto source : options.at(group)) {
            const auto key = std::make_pair(adapters.at(group), source);
            if (used.count(key)) continue;
            used.insert(key); assignment[group] = source;
            if (assign(at + 1)) return true;
            used.erase(key); assignment.erase(group);
        }
        return false;
    };
    require(assign(0), "No compatible source assignment for the requested layout");
    Configuration result;
    result.refresh_aware = profile["refresh_aware"].get<bool>();
    std::map<int, UINT32> source_indices;
    for (size_t d = 0; d < displays.size(); ++d) {
        const auto& display = displays[d];
        const int group = display["group"].get<int>();
        const auto chosen = std::find_if(matches[d].begin(), matches[d].end(), [&](size_t c) { return available[c].path.sourceInfo.id == assignment.at(group); });
        require(chosen != matches[d].end(), "Source matching lost its candidate");
        auto path = available[*chosen].path;
        path.flags = DISPLAYCONFIG_PATH_ACTIVE | (display["virtual"].get<bool>() ? DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE : 0) |
            (display["boost"].get<bool>() ? DISPLAYCONFIG_PATH_BOOST_REFRESH_RATE : 0);
        path.sourceInfo.statusFlags = 0; path.targetInfo.statusFlags = 0;
        UINT32 source_index = 0;
        const auto existing = source_indices.find(group);
        if (existing == source_indices.end()) {
            source_index = static_cast<UINT32>(result.modes.size());
            DISPLAYCONFIG_MODE_INFO mode{};
            mode.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE; mode.id = path.sourceInfo.id; mode.adapterId = path.sourceInfo.adapterId;
            mode.sourceMode = source_mode(display["source"]);
            result.modes.push_back(mode); source_indices[group] = source_index;
        } else source_index = existing->second;
        DISPLAYCONFIG_MODE_INFO mode{};
        mode.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_TARGET; mode.id = path.targetInfo.id; mode.adapterId = path.targetInfo.adapterId;
        mode.targetMode.targetVideoSignalInfo = signal_mode(display["signal"], database);
        const auto target_index = static_cast<UINT32>(result.modes.size());
        result.modes.push_back(mode);
        UINT32 desktop_index = DISPLAYCONFIG_PATH_DESKTOP_IMAGE_IDX_INVALID;
        if (!display["desktop"].is_null()) {
            desktop_index = static_cast<UINT32>(result.modes.size());
            mode.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_DESKTOP_IMAGE;
            mode.desktopImageInfo = desktop_mode(display["desktop"]);
            result.modes.push_back(mode);
        }
        if (display["virtual"].get<bool>()) {
            path.sourceInfo.cloneGroupId = DISPLAYCONFIG_PATH_CLONE_GROUP_INVALID;
            path.sourceInfo.sourceModeInfoIdx = source_index;
            path.targetInfo.targetModeInfoIdx = target_index;
            path.targetInfo.desktopModeInfoIdx = desktop_index;
        } else { path.sourceInfo.modeInfoIdx = source_index; path.targetInfo.modeInfoIdx = target_index; }
        path.targetInfo.rotation = static_cast<DISPLAYCONFIG_ROTATION>(display["rotation"].get<int>());
        path.targetInfo.scaling = static_cast<DISPLAYCONFIG_SCALING>(display["scaling"].get<int>());
        path.targetInfo.refreshRate = ratio(display["refresh"]);
        path.targetInfo.scanLineOrdering = static_cast<DISPLAYCONFIG_SCANLINE_ORDERING>(display["scan"].get<int>());
        result.paths.push_back(path);
    }
    return result;
}
static json layout_key(const json& profile) {
    json result = json::object();
    std::map<int, std::vector<std::string>> groups;
    for (const auto& d : profile["displays"]) groups[d["group"].get<int>()].push_back(folded(d["device"]));
    for (auto& group : groups) std::sort(group.second.begin(), group.second.end());
    for (const auto& d : profile["displays"]) {
        auto frequency = ratio(d["refresh"]);
        const auto divisor = std::gcd(frequency.Numerator, frequency.Denominator);
        // SetDisplayConfig forces identity scaling at matching source/target dimensions.
        const auto scaling = d["source"]["width"] == d["signal"]["active"][0] &&
            d["source"]["height"] == d["signal"]["active"][1] ? json(1) : d["scaling"];
        result[folded(d["device"])] = {{"adapter", folded(d["adapter"])}, {"source", d["source"]},
            {"clone_members", groups.at(d["group"].get<int>())},
            {"rotation", d["rotation"]}, {"scaling", scaling}, {"refresh", json::array({frequency.Numerator / divisor, frequency.Denominator / divisor})},
            {"scan", d["scan"]}, {"boost", d["boost"]}, {"active", d["signal"]["active"]}};
    }
    return result;
}
static UINT32 set_flags(const Configuration& config, UINT32 action) {
    return SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VIRTUAL_MODE_AWARE | action |
        (config.refresh_aware ? SDC_VIRTUAL_REFRESH_RATE_AWARE : 0);
}
static void set_config(Configuration& config, UINT32 action) {
    win_check(SetDisplayConfig(static_cast<UINT32>(config.paths.size()), config.paths.data(),
        static_cast<UINT32>(config.modes.size()), config.modes.data(), set_flags(config, action)), "Set display configuration");
}
static void verify_layout(const json& expected, UINT32 kind = QDC_ONLY_ACTIVE_PATHS) {
    for (unsigned attempt = 0; attempt < 10; ++attempt) {
        if (layout_key(capture(query(kind), "Readback")) == layout_key(expected)) return;
        Sleep(200);
    }
    throw std::runtime_error(kind == QDC_DATABASE_CURRENT ?
        "Saved Windows display layout does not match the requested configuration" :
        "Actual display layout does not match the requested configuration");
}
struct OwnedHandle {
    HANDLE value = nullptr;
    ~OwnedHandle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    OwnedHandle() = default;
    OwnedHandle(const OwnedHandle&) = delete;
    OwnedHandle& operator=(const OwnedHandle&) = delete;
};
struct ProfileLock {
    OwnedHandle handle;
    ProfileLock() {
        handle.value = CreateMutexW(nullptr, FALSE, L"Local\\GodBrain.DisplayProfiles.v1");
        require(handle.value != nullptr, "Could not create the display profile lock");
        const auto status = WaitForSingleObject(handle.value, 0);
        require(status == WAIT_OBJECT_0 || status == WAIT_ABANDONED, "Another display profile operation is running");
    }
    ~ProfileLock() { if (!ReleaseMutex(handle.value)) std::cerr << "Display profile lock release failed\n"; }
};
static fs::path profile_root() {
    PWSTR path = nullptr;
    const auto status = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &path);
    require(SUCCEEDED(status) && path != nullptr, "Local application-data directory is unavailable");
    fs::path result(path); CoTaskMemFree(path);
    return result / L"GodBrain";
}
static json read_json(const fs::path& path) {
    require(fs::is_regular_file(path) && fs::file_size(path) <= max_bytes, "Profile file is missing or exceeds 1 MiB");
    std::ifstream input(path, std::ios::binary);
    require(input.good(), "Could not open the profile file");
    json result;
    input >> result;
    input >> std::ws;
    require(input.eof(), "Trailing data in the profile file");
    return result;
}
static void write_json(const fs::path& path, const json& value) {
    const auto bytes = value.dump(2);
    require(bytes.size() <= max_bytes, "Profile file exceeds 1 MiB");
    fs::create_directories(path.parent_path());
    const auto temporary = fs::path(path.wstring() + L"." + std::to_wstring(GetCurrentProcessId()) + L".tmp");
    OwnedHandle file;
    file.value = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    require(file.value != INVALID_HANDLE_VALUE, "Could not create the profile staging file");
    DWORD written = 0;
    if (!WriteFile(file.value, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) ||
        written != bytes.size() || !FlushFileBuffers(file.value)) {
        CloseHandle(file.value); file.value = nullptr;
        if (!DeleteFileW(temporary.c_str())) std::cerr << "Profile staging cleanup failed\n";
        throw std::runtime_error("Could not write and flush the profile staging file");
    }
    require(CloseHandle(file.value) != FALSE, "Profile staging handle close failed"); file.value = nullptr;
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const auto error = GetLastError();
        if (!DeleteFileW(temporary.c_str())) std::cerr << "Profile staging cleanup failed\n";
        win_check(static_cast<LONG>(error), "Atomic profile replacement");
    }
}
static json load_store(const fs::path& root) {
    const auto file = root / L"display-profiles.json";
    if (!fs::exists(file)) return {{"schema_version", 1}, {"profiles", json::array()}};
    auto store = read_json(file);
    keys(store, {"schema_version", "profiles"});
    require(store["schema_version"] == 1 && store["profiles"].is_array() && store["profiles"].size() <= 32, "Invalid profile store");
    std::set<std::string> names;
    std::set<int> hotkeys;
    for (const auto& profile : store["profiles"]) {
        profile_valid(profile);
        require(names.insert(folded(profile["name"])).second, "Duplicate profile name");
        const int hotkey = profile["hotkey"].get<int>();
        require(hotkey == 0 || hotkeys.insert(hotkey).second, "Duplicate profile hotkey");
    }
    return store;
}
static size_t find_profile(const json& store, const std::string& name) {
    name_valid(name);
    for (size_t i = 0; i < store["profiles"].size(); ++i)
        if (folded(store["profiles"][i]["name"]) == folded(name)) return i;
    throw std::runtime_error("Display profile not found: " + name);
}
static json summary(const json& profile) {
    json displays = json::array();
    for (const auto& d : profile["displays"]) {
        const auto source = source_mode(d["source"]);
        const auto refresh = ratio(d["refresh"]);
        displays.push_back({{"label", d["label"]}, {"width", source.width}, {"height", source.height},
            {"x", source.position.x}, {"y", source.position.y}, {"primary", source.position.x == 0 && source.position.y == 0},
            {"rotation", d["rotation"]}, {"refresh_hz", static_cast<double>(refresh.Numerator) / refresh.Denominator}});
    }
    return {{"name", profile["name"]}, {"hotkey", profile["hotkey"]}, {"displays", displays}};
}
struct Confirmation {
    bool keep = false, done = false;
    const char* decision = "closed";
    ULONGLONG deadline = 0;
    HANDLE owner = nullptr;
    HWND label = nullptr;
};
static LRESULT CALLBACK confirm_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto state = reinterpret_cast<Confirmation*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        state = static_cast<Confirmation*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
    }
    if (state) {
        if (message == WM_COMMAND && (LOWORD(wparam) == 1 || LOWORD(wparam) == 2)) {
            if (LOWORD(wparam) == 1 && GetTickCount64() >= state->deadline) {
                state->decision = "timeout"; state->done = true; return 0;
            }
            if (LOWORD(wparam) == 1 && state->owner && WaitForSingleObject(state->owner, 0) == WAIT_OBJECT_0) {
                state->decision = "owner_exit"; state->done = true; return 0;
            }
            state->keep = LOWORD(wparam) == 1; state->decision = state->keep ? "keep" : "revert"; state->done = true; return 0;
        }
        if (message == WM_CLOSE) { state->done = true; return 0; }
        if (message == WM_TIMER) {
            const auto now = GetTickCount64();
            if (now >= state->deadline) { state->decision = "timeout"; state->done = true; return 0; }
            if (state->owner && WaitForSingleObject(state->owner, 0) == WAIT_OBJECT_0) {
                state->decision = "owner_exit"; state->done = true; return 0;
            }
            const auto text = L"Keep this display layout?\nReverting automatically in " +
                std::to_wstring((state->deadline - now + 999) / 1000) + L" seconds.";
            SetWindowTextW(state->label, text.c_str());
            return 0;
        }
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
static bool confirm_layout(HANDLE owner, std::string& decision) {
    Confirmation state;
    state.deadline = GetTickCount64() + 15000; state.owner = owner;
    WNDCLASSW cls{}; cls.lpfnWndProc = confirm_proc; cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"GodBrainDisplayConfirmation"; cls.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    require(RegisterClassW(&cls) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS, "Could not register display confirmation window");
    HWND window = CreateWindowExW(WS_EX_TOPMOST, cls.lpszClassName, L"GodBrain - Keep / Revert display layout",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, (GetSystemMetrics(SM_CXSCREEN) - 440) / 2,
        (GetSystemMetrics(SM_CYSCREEN) - 185) / 2, 440, 185, nullptr, nullptr, cls.hInstance, &state);
    require(window != nullptr, "Could not show display confirmation; restoring the previous layout");
    try {
        state.label = CreateWindowW(L"STATIC", L"Keep this layout? Automatic revert in 15 seconds.", WS_CHILD | WS_VISIBLE,
            18, 15, 400, 55, window, nullptr, cls.hInstance, nullptr);
        const auto keep = CreateWindowW(L"BUTTON", L"Keep", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 200, 85, 95, 32, window,
            reinterpret_cast<HMENU>(1), cls.hInstance, nullptr);
        const auto revert = CreateWindowW(L"BUTTON", L"Revert", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 310, 85, 95, 32,
            window, reinterpret_cast<HMENU>(2), cls.hInstance, nullptr);
        require(state.label && keep && revert && SetTimer(window, 1, 100, nullptr) != 0, "Could not initialize display confirmation");
        ShowWindow(window, SW_SHOW); SetForegroundWindow(window); SetFocus(revert);
        MSG message{};
        while (!state.done) {
            const auto status = GetMessageW(&message, nullptr, 0, 0);
            require(status != -1, "Display confirmation message loop failed");
            if (status == 0) break;
            if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        }
        DestroyWindow(window);
        decision = state.decision;
        return state.keep;
    } catch (...) { DestroyWindow(window); throw; }
}
struct Recovery {
    json profile;
    json database;
};
static Recovery recovery_snapshot(const json& journal) {
    require(journal.is_object() && journal.contains("schema_version"), "Missing recovery journal version");
    const auto version = integer(journal["schema_version"], 1, 3);
    json database = nullptr;
    if (version == 1) keys(journal, {"schema_version", "profile"});
    else if (version == 2) {
        keys(journal, {"schema_version", "profile", "restore_database"});
        require(journal["restore_database"].is_boolean(), "Invalid recovery persistence marker");
    } else {
        keys(journal, {"schema_version", "profile", "database_profile"});
        database = journal["database_profile"];
    }
    profile_valid(journal["profile"]);
    // Legacy journals have no separate saved-layout snapshot.
    if (version == 1 || (version == 2 && journal["restore_database"].get<bool>())) database = journal["profile"];
    if (!database.is_null()) profile_valid(database, true);
    return {journal["profile"], database};
}
static void write_recovery(const fs::path& root, const json& profile, const json& database = nullptr) {
    write_json(root / L"display-restore.json", {{"schema_version", 3}, {"profile", profile}, {"database_profile", database}});
}
template <typename Apply, typename Verify>
static void restore_snapshot(const Recovery& snapshot, Apply apply, Verify verify) {
    if (!snapshot.database.is_null()) {
        apply(snapshot.database, true); verify(snapshot.database, true);
    }
    apply(snapshot.profile, false); verify(snapshot.profile, false);
}
template <typename Apply, typename Verify, typename Confirm, typename Journal, typename Restore, typename Clear>
static bool transaction(const json& before, const json& desired, Apply apply, Verify verify, Confirm confirm, Journal journal, Restore restore, Clear clear) {
    journal(before, false);
    bool persistence_attempted = false;
    const auto undo = [&]() { restore(persistence_attempted); clear(); };
    try {
        apply(desired, false); verify(desired);
        if (confirm()) {
            journal(before, true);
            persistence_attempted = true;
            apply(desired, true); verify(desired); clear(); return true;
        }
    } catch (const std::exception& error) {
        const std::string original = error.what();
        try { undo(); }
        catch (const std::exception& failure) { throw std::runtime_error(original + ". RESTORATION FAILED: " + failure.what() + ". Use Recover previous layout."); }
        throw std::runtime_error(original + ". Previous layout restored and verified.");
    }
    try { undo(); }
    catch (const std::exception& failure) { throw std::runtime_error(std::string("RESTORATION FAILED: ") + failure.what() + ". Use Recover previous layout."); }
    return false;
}
static void clear_journal(const fs::path& root) {
    require(DeleteFileW((root / L"display-restore.json").c_str()) != FALSE, "Verified restoration journal could not be cleared");
}
static bool apply_profile(const json& profile, const fs::path& root, HANDLE owner, const std::function<bool()>& confirmation = {},
                          std::string* decision = nullptr, bool no_confirm = false) {
    const auto current = query(QDC_ONLY_ACTIVE_PATHS);
    const auto before = capture(current, "Previous layout");
    profile_valid(before);
    auto database = query(QDC_DATABASE_CURRENT);
    const auto saved = capture(database, "Previous saved layout");
    profile_valid(saved, true);
    auto requested = resolve(profile, candidates(query(QDC_ALL_PATHS)), current.refresh_aware);
    set_config(requested, SDC_VALIDATE);
    auto original = current;
    return transaction(before, profile,
        [&](const json&, bool persist) {
            if (persist && owner) require(WaitForSingleObject(owner, 0) == WAIT_TIMEOUT, "Desk owner exited before persistence; restoring the previous layout");
            set_config(requested, SDC_APPLY | (persist ? SDC_SAVE_TO_DATABASE : 0));
            if (persist) verify_layout(profile, QDC_DATABASE_CURRENT);
        }, [](const json& value) { verify_layout(value); }, [&]() {
            if (confirmation) return confirmation();
            if (no_confirm) {
                if (decision) *decision = "saved_profile";
                return true;
            }
            std::string choice;
            const auto keep = confirm_layout(owner, choice);
            if (decision) *decision = choice;
            return keep;
        },
        [&](const json& value, bool persist) {
            if (persist) set_config(database, SDC_VALIDATE);
            write_recovery(root, value, persist ? saved : json(nullptr));
        }, [&](bool persist) {
            restore_snapshot({before, persist ? saved : json(nullptr)},
                [&](const json&, bool db) { set_config(db ? database : original, SDC_APPLY | (db ? SDC_SAVE_TO_DATABASE : 0)); },
                [](const json& value, bool db) { verify_layout(value, db ? QDC_DATABASE_CURRENT : QDC_ONLY_ACTIVE_PATHS); });
        },
        [&]() { clear_journal(root); });
}
static json fixture_profile() {
    return {{"name", "Fixture"}, {"hotkey", 0}, {"refresh_aware", false}, {"displays", json::array({
        {{"device", "monitor-A"}, {"adapter", "adapter-A"}, {"label", "Fixture monitor"}, {"group", 0},
        {"source", {{"width", 1920}, {"height", 1080}, {"pixel_format", 4}, {"position", json::array({0, 0})}}},
        {"signal", {{"pixel_rate", 148500000}, {"h_sync", json::array({67500, 1})}, {"v_sync", json::array({60, 1})},
            {"active", json::array({1920, 1080})}, {"total", json::array({2200, 1125})}, {"standard", 0}, {"scan", 1}}},
        {"rotation", 1}, {"scaling", 1}, {"refresh", json::array({60, 1})}, {"scan", 1}, {"boost", false}, {"virtual", false}, {"desktop", nullptr}}
    })}};
}
static void self_test() {
    auto profile = fixture_profile();
    profile_valid(profile);
    auto rejects = [](const std::function<void()>& call) {
        bool failed = false; try { call(); } catch (const std::exception&) { failed = true; }
        require(failed, "Native display profile rejection fixture failed");
    };
    for (const auto& mutate : std::vector<std::function<void(json&)>>{
        [](json& p) { p["displays"] = json::array(); }, [](json& p) { p["name"] = "../escape"; },
        [](json& p) { p["displays"][0]["refresh"][1] = 0; }, [](json& p) { p["displays"][0]["source"]["width"] = 0; },
        [](json& p) { p["hotkey"] = 13; }, [](json& p) { p["displays"][0]["source"]["position"] = json::array({1, 1}); },
        [](json& p) { p["extra"] = true; }, [](json& p) { p["displays"].push_back(p["displays"][0]); },
        [](json& p) { p["displays"][0]["virtual"] = "false"; }, [](json& p) { p["displays"][0]["source"]["width"] = UINT64_MAX; }
    }) { auto bad = profile; mutate(bad); rejects([&]() { profile_valid(bad); }); }
    Candidate candidate{};
    candidate.id = {"MONITOR-A", "ADAPTER-A", "Fixture"};
    candidate.path.sourceInfo.id = 8; candidate.path.targetInfo.id = 19; candidate.path.targetInfo.targetAvailable = TRUE;
    const auto resolved = resolve(profile, {candidate}, true);
    require(resolved.paths[0].sourceInfo.id == 8 && resolved.paths[0].targetInfo.id == 19, "Current target/source IDs were not remapped");
    rejects([&]() { resolve(profile, {}, true); });
    auto duplicate = candidate; duplicate.path.targetInfo.id = 20;
    rejects([&]() { resolve(profile, {candidate, duplicate}, true); });
    auto two = profile;
    auto second = two["displays"][0]; second["device"] = "monitor-B"; second["group"] = 1; second["source"]["position"] = json::array({1920, 0});
    two["displays"].push_back(second);
    auto b = candidate; b.id.device = "monitor-B"; b.path.targetInfo.id = 20;
    rejects([&]() { resolve(two, {candidate, b}, true); });
    auto a2 = candidate; a2.path.sourceInfo.id = 9;
    auto b2 = b; b2.path.sourceInfo.id = 9;
    const auto independent = resolve(two, {candidate, a2, b, b2}, true);
    require(independent.paths[0].sourceInfo.id != independent.paths[1].sourceInfo.id, "Distinct displays share an unintended source");
    two["displays"][1]["group"] = 0; two["displays"][1]["source"] = two["displays"][0]["source"];
    require(resolve(two, {candidate, b}, true).modes.size() == 3, "Clone source was duplicated");
    auto overlapping = two; overlapping["displays"][1]["group"] = 1;
    require(layout_key(two) != layout_key(overlapping), "Clone topology was mistaken for overlapping independent displays");
    auto renumbered = two;
    for (auto& d : renumbered["displays"]) d["group"] = 7;
    std::reverse(renumbered["displays"].begin(), renumbered["displays"].end());
    require(layout_key(two) == layout_key(renumbered), "Clone verification depends on enumeration order or transient group numbers");
    auto normalized = profile; normalized["displays"][0]["refresh"] = json::array({60000, 1000});
    require(layout_key(profile) == layout_key(normalized), "Equivalent rational refresh rates differ");
    auto preferred_scaling = profile; preferred_scaling["displays"][0]["scaling"] = 4;
    require(layout_key(profile) == layout_key(preferred_scaling), "Windows' native-size identity scaling normalization was rejected");
    preferred_scaling["displays"][0]["source"]["width"] = 1280;
    auto other_scaling = preferred_scaling; other_scaling["displays"][0]["scaling"] = 1;
    require(layout_key(preferred_scaling) != layout_key(other_scaling), "Non-native display scaling differences were hidden");
    auto virt = profile; virt["displays"][0]["virtual"] = true;
    auto virtual_candidate = candidate; virtual_candidate.path.flags = DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE;
    const auto virtual_result = resolve(virt, {virtual_candidate}, true);
    require(virtual_result.paths[0].sourceInfo.sourceModeInfoIdx == 0 && virtual_result.paths[0].targetInfo.targetModeInfoIdx == 1 &&
        virtual_result.paths[0].targetInfo.desktopModeInfoIdx == DISPLAYCONFIG_PATH_DESKTOP_IMAGE_IDX_INVALID, "Virtual mode indices were not encoded correctly");
    auto changed_layout = profile; changed_layout["displays"][0]["source"]["width"] = 1280;
    require(layout_key(profile) != layout_key(changed_layout), "Resolution readback mismatch was hidden");
    WNDCLASSW confirmation_class{};
    confirmation_class.lpfnWndProc = confirm_proc; confirmation_class.hInstance = GetModuleHandleW(nullptr);
    confirmation_class.lpszClassName = L"GodBrainDisplayConfirmationFixture";
    require(RegisterClassW(&confirmation_class) != 0, "Confirmation fixture class failed");
    Confirmation confirmation;
    const auto fixture_window = CreateWindowExW(0, confirmation_class.lpszClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, confirmation_class.hInstance, &confirmation);
    require(fixture_window != nullptr, "Confirmation fixture hidden window failed");
    try {
        SendMessageW(fixture_window, WM_COMMAND, 1, 0);
        require(confirmation.done && !confirmation.keep && std::string(confirmation.decision) == "timeout", "Late Keep bypassed the absolute deadline");
        confirmation = Confirmation{}; confirmation.deadline = GetTickCount64() + 15000;
        OwnedHandle exited_owner; exited_owner.value = CreateEventW(nullptr, TRUE, TRUE, nullptr);
        require(exited_owner.value != nullptr, "Exited-owner wait fixture failed");
        confirmation.owner = exited_owner.value;
        SendMessageW(fixture_window, WM_COMMAND, 1, 0);
        require(confirmation.done && !confirmation.keep && std::string(confirmation.decision) == "owner_exit", "Keep bypassed an exited owner");
        confirmation = Confirmation{}; confirmation.deadline = GetTickCount64() + 15000;
        SendMessageW(fixture_window, WM_COMMAND, 1, 0);
        require(confirmation.done && confirmation.keep && std::string(confirmation.decision) == "keep", "Timely Keep was rejected");
        DestroyWindow(fixture_window);
    } catch (...) { DestroyWindow(fixture_window); throw; }
    for (int scenario = 0; scenario < 10; ++scenario) {
        std::vector<std::string> calls;
        bool journal = false, database_marker = false, desired_persisted = false;
        unsigned clears = 0;
        const json before = {{"id", "before"}}, desired = {{"id", "desired"}}, database_before = {{"id", "database"}};
        bool failed = false;
        auto fixture_apply = [&](const json& value, bool persist) {
            require(journal && (!persist || database_marker), "Display apply preceded its durable recovery marker");
            calls.push_back(value["id"].get<std::string>() + (persist ? ":persist" : ":temporary"));
            if ((scenario == 2 && value == desired) || (scenario == 4 && value == before) ||
                (scenario == 5 && value == desired && persist) || (scenario == 9 && value == database_before)) throw std::runtime_error("Fixture set failure");
            if (value == desired && persist) desired_persisted = true;
        };
        try {
            const bool kept = transaction(before, desired, fixture_apply, [&](const json& value) {
                    if (value == desired && (scenario == 3 || ((scenario == 7 || scenario == 9) && desired_persisted))) throw std::runtime_error("Fixture mismatch");
                }, [&]() { return scenario == 1 || scenario >= 5; },
                [&](const json& value, bool persist) {
                    require(value == before, "Recovery marker lost the original layout");
                    if (scenario == 6 && persist) throw std::runtime_error("Fixture marker write failure");
                    journal = true; database_marker = persist;
                }, [&](bool persist) {
                    restore_snapshot({before, persist ? database_before : json(nullptr)}, fixture_apply,
                        [&](const json& value, bool db) { require(db == (value == database_before), "Recovery verified the wrong database/live snapshot"); });
                }, [&]() {
                    if (scenario == 8 && ++clears == 1) throw std::runtime_error("Fixture journal clear failure");
                    journal = false;
                });
            require(kept == (scenario == 1), "Wrong confirmation outcome");
        } catch (const std::exception&) { failed = true; }
        require(failed == (scenario >= 2), "Transaction failure was hidden");
        require(journal == (scenario == 4 || scenario == 9), "Recovery journal lifetime is incorrect");
        const bool database_restore = scenario == 5 || scenario == 7 || scenario == 8;
        require(calls.size() == (scenario == 9 ? 3u : database_restore ? 4u : 2u) &&
            calls.back() == (scenario == 1 ? "desired:persist" : scenario == 9 ? "database:persist" : "before:temporary"), "Transaction did not restore/keep exactly");
        if (database_restore) require(calls[2] == "database:persist", "Saved layout was replaced by the previous temporary layout");
    }
    const auto root = fs::temp_directory_path() / (L"GodBrain-display-fixture-" + std::to_wstring(GetCurrentProcessId()));
    require(!fs::exists(root), "Offline profile fixture directory already exists");
    fs::create_directory(root);
    auto cleanup = [&]() {
        for (const auto file : {L"display-profiles.json", L"display-restore.json"})
            if (fs::exists(root / file)) require(fs::remove(root / file), "Offline profile fixture cleanup failed");
        require(fs::remove(root), "Offline profile fixture directory cleanup failed");
    };
    try {
        auto store = json{{"schema_version", 1}, {"profiles", json::array({profile})}};
        write_json(root / L"display-profiles.json", store);
        require(load_store(root) == store, "Profile persistence roundtrip failed");
        store["profiles"].push_back(profile);
        write_json(root / L"display-profiles.json", store);
        rejects([&]() { load_store(root); });
        store["profiles"][1]["name"] = "Different name"; store["profiles"][0]["hotkey"] = 1; store["profiles"][1]["hotkey"] = 1;
        write_json(root / L"display-profiles.json", store);
        rejects([&]() { load_store(root); });
        auto database_profile = profile;
        database_profile["name"] = "Separate saved layout";
        database_profile["displays"][0]["source"]["width"] = 1280;
        database_profile["displays"][0]["signal"]["total"] = json::array({0, 0});
        rejects([&]() { profile_valid(database_profile); });
        for (const bool persist : {false, true}) {
            write_recovery(root, profile, persist ? database_profile : json(nullptr));
            const auto snapshot = recovery_snapshot(read_json(root / L"display-restore.json"));
            require(snapshot.profile == profile && snapshot.database == (persist ? database_profile : json(nullptr)), "Distinct database/live recovery roundtrip failed");
        }
        require(recovery_snapshot({{"schema_version", 1}, {"profile", profile}}).database == profile, "Legacy recovery must conservatively restore the database");
        require(recovery_snapshot({{"schema_version", 2}, {"profile", profile}, {"restore_database", false}}).database.is_null(), "Legacy temporary recovery must not write the database");
        require(recovery_snapshot({{"schema_version", 2}, {"profile", profile}, {"restore_database", true}}).database == profile, "Legacy Keep recovery lost its rollback layout");
        rejects([&]() { recovery_snapshot({{"schema_version", 2}, {"profile", profile}}); });
        rejects([&]() { recovery_snapshot({{"schema_version", 2}, {"profile", profile}, {"restore_database", "true"}}); });
        rejects([&]() { recovery_snapshot({{"schema_version", 3}, {"profile", profile}, {"database_profile", "invalid"}}); });
        rejects([&]() { recovery_snapshot({{"schema_version", 4}, {"profile", profile}, {"database_profile", nullptr}}); });
        clear_journal(root);
        {
            std::ofstream invalid(root / L"display-profiles.json", std::ios::binary | std::ios::trunc);
            invalid << "{} {}";
        }
        rejects([&]() { read_json(root / L"display-profiles.json"); });
        cleanup();
    } catch (...) { cleanup(); throw; }
}
static json live_test(const fs::path& root) {
    const auto baseline = capture(query(QDC_ONLY_ACTIVE_PATHS), "Live baseline");
    require(baseline["displays"].size() >= 2, "Live switch test requires at least two active monitors");
    const auto alternate = std::find_if(baseline["displays"].begin(), baseline["displays"].end(), [](const json& d) {
        const auto position = point(d["source"]["position"]); return position.x != 0 || position.y != 0;
    });
    require(alternate != baseline["displays"].end(), "Live primary-switch test needs an extended layout");
    const auto offset = point((*alternate)["source"]["position"]);
    auto single = baseline;
    single["name"] = "Live single-display fixture"; single["displays"].erase(single["displays"].begin() + 1, single["displays"].end());
    single["displays"][0]["source"]["position"] = json::array({0, 0});
    // Recaptured virtual desktop geometry must follow the moved source.
    single["displays"][0]["desktop"] = nullptr;
    require(!apply_profile(single, root, nullptr, []() { Sleep(1500); return false; }), "Live fixture unexpectedly kept");
    verify_layout(baseline);
    auto primary = baseline;
    primary["name"] = "Live alternate-primary fixture";
    for (auto& d : primary["displays"]) {
        auto location = point(d["source"]["position"]);
        d["source"]["position"] = json::array({location.x - offset.x, location.y - offset.y});
        d["desktop"] = nullptr;
    }
    require(!apply_profile(primary, root, nullptr, []() { Sleep(1500); return false; }), "Live fixture unexpectedly kept");
    verify_layout(baseline);
    return {{"fixtures", 2}, {"single_display_reverted", true}, {"alternate_primary_reverted", true}, {"restored", true}};
}
int wmain(int argc, wchar_t** argv) {
    bool may_have_changed = false;
    try {
        require(argc >= 2, "Specify --list, --current, --save, --preview, --apply, --hotkey, --delete, --recover or --self-test");
        const auto command = utf8(argv[1]);
        if (command == "--self-test") {
            require(argc == 2, "Self-test takes no arguments"); self_test();
            std::cout << json({{"schema_version", 1}, {"ok", true}, {"operation", "self-test"}, {"self_test", "passed"}}).dump() << '\n'; return 0;
        }
        require(command == "--list" || command == "--current" || command == "--save" || command == "--preview" ||
            command == "--apply" || command == "--hotkey" || command == "--delete" || command == "--recover" || command == "--live-test", "Unsupported display profile operation");
        const bool named = command == "--save" || command == "--preview" || command == "--apply" || command == "--hotkey" || command == "--delete";
        require(named ? argc >= 3 : argc == 2, "Incorrect display profile arguments");
        const auto name = named ? utf8(argv[2]) : std::string();
        if (named) name_valid(name);
        if (command == "--save") require(argc == 3 || (argc == 4 && std::wstring(argv[3]) == L"--overwrite"), "Save accepts only --overwrite");
        else if (command == "--hotkey") require(argc == 4, "Hotkey requires a Ctrl+Alt+F1-F12 slot (0 disables)");
        else if (command == "--apply") require(argc == 3 ||
            (argc == 4 && std::wstring(argv[3]) == L"--no-confirm") ||
            (argc == 5 && std::wstring(argv[3]) == L"--owner") ||
            (argc == 6 && std::wstring(argv[3]) == L"--owner" && std::wstring(argv[5]) == L"--no-confirm"),
            "Apply accepts only --owner PID followed by optional --no-confirm");
        else if (named) require(argc == 3, "Unexpected display profile arguments");
        const bool no_confirm = command == "--apply" &&
            ((argc == 4 && std::wstring(argv[3]) == L"--no-confirm") || argc == 6);
        ProfileLock lock;
        const auto root = profile_root();
        const bool pending = fs::exists(root / L"display-restore.json");
        require(!pending || command == "--list" || command == "--recover", "An unfinished switch requires Recover previous layout before further operations");
        json store;
        if (command != "--recover" && command != "--current" && command != "--live-test") store = load_store(root);
        json result{{"schema_version", 1}, {"ok", true}, {"operation", command.substr(2)}};
        if (command == "--list") {
            result["profiles"] = json::array();
            for (const auto& profile : store["profiles"]) result["profiles"].push_back(summary(profile));
            result["recovery_pending"] = pending;
        } else if (command == "--current") {
            const auto current = capture(query(QDC_ONLY_ACTIVE_PATHS), "Current layout"); profile_valid(current);
            result["profile"] = summary(current);
        } else if (command == "--save") {
            auto profile = capture(query(QDC_ONLY_ACTIVE_PATHS), name); profile_valid(profile);
            size_t index = store["profiles"].size();
            for (size_t i = 0; i < index; ++i) if (folded(store["profiles"][i]["name"]) == folded(name)) { index = i; break; }
            if (index < store["profiles"].size()) {
                require(argc == 4, "Profile already exists; confirm overwrite first");
                profile["hotkey"] = store["profiles"][index]["hotkey"]; store["profiles"][index] = profile;
            } else { require(store["profiles"].size() < 32, "The profile limit is 32"); store["profiles"].push_back(profile); }
            write_json(root / L"display-profiles.json", store); result["profile"] = summary(profile);
        } else if (command == "--hotkey" || command == "--delete") {
            const auto index = find_profile(store, name);
            if (command == "--hotkey") {
                const auto slot_text = utf8(argv[3]);
                require(slot_text.size() <= 2 && !slot_text.empty() && std::all_of(slot_text.begin(), slot_text.end(), [](char c) { return c >= '0' && c <= '9'; }), "Invalid hotkey slot");
                const int slot = std::stoi(slot_text); require(slot <= 12, "Hotkey slot must be 0-12");
                for (size_t i = 0; i < store["profiles"].size(); ++i)
                    require(slot == 0 || i == index || store["profiles"][i]["hotkey"] != slot, "Another profile already uses this hotkey");
                store["profiles"][index]["hotkey"] = slot; result["profile"] = summary(store["profiles"][index]);
            } else { store["profiles"].erase(store["profiles"].begin() + static_cast<json::difference_type>(index)); result["deleted"] = name; }
            write_json(root / L"display-profiles.json", store);
        } else if (command == "--preview" || command == "--apply") {
            const auto profile = store["profiles"][find_profile(store, name)];
            if (command == "--preview") {
                const auto available = query(QDC_ALL_PATHS);
                auto requested = resolve(profile, candidates(available), available.refresh_aware);
                set_config(requested, SDC_VALIDATE);
                result["validated"] = true; result["profile"] = summary(profile);
            } else {
                OwnedHandle owner;
                if (argc >= 5) {
                    const auto id = utf8(argv[4]);
                    require(!id.empty() && id.size() <= 10 && std::all_of(id.begin(), id.end(), [](char c) { return c >= '0' && c <= '9'; }), "Invalid owner PID");
                    const auto number = std::stoull(id); require(number > 0 && number <= UINT32_MAX, "Invalid owner PID");
                    owner.value = OpenProcess(SYNCHRONIZE, FALSE, static_cast<DWORD>(number));
                    require(owner.value != nullptr && WaitForSingleObject(owner.value, 0) == WAIT_TIMEOUT, "Desk owner is unavailable; no layout change made");
                }
                may_have_changed = true;
                std::string decision;
                const bool kept = apply_profile(profile, root, owner.value, {}, &decision, no_confirm);
                may_have_changed = false;
                result["outcome"] = kept ? "kept" : "reverted"; result["verified"] = true; result["profile"] = summary(profile);
                result["confirmation"] = decision;
            }
        } else if (command == "--recover") {
            require(pending, "No unfinished display switch to recover");
            const auto snapshot = recovery_snapshot(read_json(root / L"display-restore.json"));
            const auto available = query(QDC_ALL_PATHS);
            const auto options = candidates(available);
            auto requested = resolve(snapshot.profile, options, available.refresh_aware); set_config(requested, SDC_VALIDATE);
            Configuration database;
            if (!snapshot.database.is_null()) {
                database = resolve(snapshot.database, options, available.refresh_aware, true);
                set_config(database, SDC_VALIDATE);
            }
            may_have_changed = true;
            restore_snapshot(snapshot,
                [&](const json&, bool db) { set_config(db ? database : requested, SDC_APPLY | (db ? SDC_SAVE_TO_DATABASE : 0)); },
                [](const json& value, bool db) { verify_layout(value, db ? QDC_DATABASE_CURRENT : QDC_ONLY_ACTIVE_PATHS); });
            clear_journal(root); may_have_changed = false;
            result["outcome"] = "restored"; result["verified"] = true;
        } else {
            may_have_changed = true; result.update(live_test(root)); may_have_changed = false;
        }
        std::cout << result.dump() << '\n'; return 0;
    } catch (const std::exception& error) {
        std::cout << json({{"schema_version", 1}, {"ok", false}, {"error", error.what()}, {"may_have_changed", may_have_changed}}).dump() << '\n';
        return 1;
    }
}
