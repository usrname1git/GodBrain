#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <physicalmonitorenumerationapi.h>
#include <lowlevelmonitorconfigurationapi.h>
#include "../cpp_kernel/json.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cctype>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using json = nlohmann::json;

struct Preset {
    const char* id;
    const char* name;
    BYTE code;
    DWORD value;
    DWORD readback;
};
static constexpr std::array<Preset, 12> presets{{
    {"standard", "Standard", 0xDC, 0x00, 0x00},
    {"game1", "Game 1", 0xDC, 0x05, 0x04},
    {"comfortview", "ComfortView", 0xF0, 0x0C, 0x1D},
    {"game2", "Game 2", 0xF0, 0x0D, 0x1E},
    {"game3", "Game 3", 0xF0, 0x0E, 0x1F},
    {"fps", "FPS", 0xF0, 0x0F, 0x20},
    {"rts", "RTS", 0xF0, 0x10, 0x21},
    {"rpg", "RPG", 0xF0, 0x11, 0x22},
    {"sports", "Sports", 0xF0, 0x13, 0x2F},
    {"warm", "Warm", 0x14, 0x0B, 0x0E},
    {"cool", "Cool", 0x14, 0x08, 0x12},
    {"custom", "Custom Color", 0x14, 0x0C, 0x14}
}};

static unsigned number(const std::string& text, int base = 10) {
    unsigned value = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value, base);
    if (text.empty() || result.ec != std::errc{} || result.ptr != text.data() + text.size())
        throw std::runtime_error("Invalid monitor value: " + text);
    return value;
}

static std::string group(const std::string& text, const std::string& name) {
    const std::string marker = name + "(";
    size_t begin = text.find(marker);
    if (begin == std::string::npos) throw std::runtime_error("Missing capability group: " + name);
    if (begin != 0 && text[begin - 1] != '(' && text[begin - 1] != ')' &&
        !std::isspace(static_cast<unsigned char>(text[begin - 1])))
        throw std::runtime_error("Invalid capability group boundary: " + name);
    if (text.find(marker, begin + marker.size()) != std::string::npos)
        throw std::runtime_error("Duplicate capability group: " + name);
    begin += marker.size();
    unsigned depth = 1;
    for (size_t i = begin; i < text.size(); ++i) {
        if (text[i] == '(') ++depth;
        if (text[i] == ')' && --depth == 0) return text.substr(begin, i - begin);
        if (depth > 8) throw std::runtime_error("Capability nesting is too deep");
    }
    throw std::runtime_error("Unclosed capability group: " + name);
}

struct Capabilities {
    std::string model;
    std::map<unsigned, std::vector<unsigned>> vcp;
    bool has(unsigned code) const { return vcp.count(code) != 0; }
    bool allows(unsigned code, unsigned value) const {
        const auto it = vcp.find(code);
        return it != vcp.end() &&
            std::find(it->second.begin(), it->second.end(), value) != it->second.end();
    }
};

static Capabilities parse_capabilities(const std::string& text) {
    if (text.empty() || text.size() > 16384) throw std::runtime_error("Invalid capability size");
    Capabilities result;
    result.model = group(text, "model");
    const std::string body = group(text, "vcp");
    size_t i = 0;
    auto spaces = [&]() { while (i < body.size() && std::isspace(static_cast<unsigned char>(body[i]))) ++i; };
    auto hex = [&]() {
        const size_t begin = i;
        while (i < body.size() && std::isxdigit(static_cast<unsigned char>(body[i]))) ++i;
        if (i == begin || i - begin > 4) throw std::runtime_error("Invalid VCP capability token");
        return number(body.substr(begin, i - begin), 16);
    };
    while (i < body.size()) {
        spaces();
        if (i == body.size()) break;
        const unsigned code = hex();
        if (code > 255 || result.vcp.count(code)) throw std::runtime_error("Invalid or duplicate VCP code");
        std::vector<unsigned> values;
        spaces();
        if (i < body.size() && body[i] == '(') {
            ++i;
            for (;;) {
                spaces();
                if (i == body.size()) throw std::runtime_error("Unclosed VCP values");
                if (body[i] == ')') { ++i; break; }
                values.push_back(hex());
            }
        }
        result.vcp.emplace(code, std::move(values));
    }
    return result;
}

static bool supported(const Capabilities& caps, const Preset& preset) {
    return caps.allows(preset.code, preset.value) && caps.allows(0xE2, preset.readback);
}

static const Preset& find_preset(const std::string& id) {
    for (const auto& preset : presets) if (id == preset.id) return preset;
    throw std::runtime_error("Unsupported color preset: " + id);
}

static void validate_change(const std::string& control, const std::string& value) {
    if (control == "preset") { find_preset(value); return; }
    if (control != "brightness" && control != "contrast" && control != "dark_stabilizer")
        throw std::runtime_error("Unsupported monitor control: " + control);
    if (number(value) > (control == "dark_stabilizer" ? 3u : 100u))
        throw std::runtime_error("Monitor value is outside the allowed range");
}

static std::string win_error(const std::string& operation) {
    return operation + " failed (Windows error " + std::to_string(GetLastError()) + ")";
}

static bool dell_device(const std::wstring& id) {
    return id.size() >= 11 && _wcsnicmp(id.c_str(), L"MONITOR\\DEL", 11) == 0;
}

struct PhysicalSet {
    std::vector<PHYSICAL_MONITOR> monitors;
    bool open = false;
    explicit PhysicalSet(HMONITOR monitor) {
        DWORD count = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count))
            throw std::runtime_error(win_error("Physical monitor count"));
        if (count == 0 || count > 16) throw std::runtime_error("Unexpected physical monitor count");
        monitors.resize(count);
        if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, monitors.data()))
            throw std::runtime_error(win_error("Physical monitor enumeration"));
        open = true;
    }
    void close() {
        if (open) {
            const BOOL ok = DestroyPhysicalMonitors(static_cast<DWORD>(monitors.size()), monitors.data());
            open = false;
            if (!ok) throw std::runtime_error(win_error("Physical monitor handle cleanup"));
        }
    }
    ~PhysicalSet() {
        if (open && !DestroyPhysicalMonitors(static_cast<DWORD>(monitors.size()), monitors.data()))
            std::cerr << win_error("Physical monitor handle cleanup") << '\n';
    }
    PhysicalSet(const PhysicalSet&) = delete;
    PhysicalSet& operator=(const PhysicalSet&) = delete;
};

static BOOL CALLBACK collect_monitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
    try {
        reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(monitor);
        return TRUE;
    } catch (const std::bad_alloc&) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }
}

struct Target {
    std::unique_ptr<PhysicalSet> owner;
    HANDLE handle = nullptr;
    bool selected = false; // Dxva2 handles are opaque; zero can be valid.
    Capabilities caps;
    std::string display;
};

static bool match_physical_target(Target& target, HANDLE handle, Capabilities caps, const wchar_t* display) {
    if (caps.model != "S2522HG") return false;
    if (target.selected) throw std::runtime_error("Multiple Dell S2522HG monitors: target is ambiguous");
    target.handle = handle;
    target.caps = std::move(caps);
    for (const wchar_t* c = display; *c; ++c) target.display.push_back(static_cast<char>(*c));
    target.selected = true;
    return true;
}

static Target select_target() {
    std::vector<HMONITOR> screens;
    if (!EnumDisplayMonitors(nullptr, nullptr, collect_monitor, reinterpret_cast<LPARAM>(&screens)))
        throw std::runtime_error(win_error("Display enumeration"));
    Target target;
    for (const auto screen : screens) {
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        if (!GetMonitorInfoW(screen, reinterpret_cast<MONITORINFO*>(&info)))
            throw std::runtime_error(win_error("Display identity"));
        DISPLAY_DEVICEW device{};
        device.cb = sizeof(device);
        if (!EnumDisplayDevicesW(info.szDevice, 0, &device, 0))
            throw std::runtime_error(win_error("Monitor identity"));
        if (!dell_device(device.DeviceID)) continue;
        auto owner = std::make_unique<PhysicalSet>(screen);
        for (const auto& physical : owner->monitors) {
            DWORD length = 0;
            if (!GetCapabilitiesStringLength(physical.hPhysicalMonitor, &length))
                throw std::runtime_error(win_error("Monitor capabilities length"));
            if (length < 2 || length > 16384) throw std::runtime_error("Invalid monitor capability length");
            std::vector<char> text(length, '\0');
            if (!CapabilitiesRequestAndCapabilitiesReply(physical.hPhysicalMonitor, text.data(), length))
                throw std::runtime_error(win_error("Monitor capabilities"));
            if (std::find(text.begin(), text.end(), '\0') == text.end())
                throw std::runtime_error("Unterminated monitor capabilities");
            auto caps = parse_capabilities(text.data());
            match_physical_target(target, physical.hPhysicalMonitor, std::move(caps), info.szDevice);
        }
        if (target.selected && !target.owner) target.owner = std::move(owner);
        else owner->close();
    }
    if (!target.selected) throw std::runtime_error("Dell S2522HG not found; no monitor was changed");
    return target;
}

static DWORD read_value(HANDLE monitor, BYTE code, DWORD* maximum = nullptr) {
    DWORD current = 0, max = 0;
    if (!GetVCPFeatureAndVCPFeatureReply(monitor, code, nullptr, &current, &max))
        throw std::runtime_error(win_error("Read VCP " + std::to_string(code)));
    if (maximum) *maximum = max;
    return current;
}

static DWORD dark_level(DWORD wire_value) {
    if (wire_value < 0x30 || wire_value > 0x33)
        throw std::runtime_error("Unknown Dark Stabilizer gaming reply");
    return wire_value - 0x30;
}

static bool supports_dark(const Capabilities& caps) {
    for (unsigned value = 0x30; value <= 0x33; ++value)
        if (!caps.allows(0xF4, value)) return false;
    return true;
}

static bool supports_dark_cycle(const Capabilities& caps) {
    return caps.model == "S2522HG" && caps.has(0xE3);
}

template <typename Write>
static void cycle_dark(const Capabilities& caps, HANDLE monitor, bool& may_have_changed, Write write) {
    if (!supports_dark_cycle(caps))
        throw std::runtime_error("Dark Stabilizer cycling is not advertised by the Dell S2522HG");
    may_have_changed = true;
    if (!write(monitor, 0xE3, 0x10))
        throw std::runtime_error(win_error("Dark Stabilizer cycle command"));
}

static DWORD read_dark(HANDLE monitor) {
    // F4=3F selects a read. The separate E3 cycle cannot establish the current level.
    if (!SetVCPFeature(monitor, 0xF4, 0x3F))
        throw std::runtime_error(win_error("Select Dark Stabilizer read"));
    Sleep(100);
    return dark_level(read_value(monitor, 0xF4));
}

static json feature(const Target& target, BYTE code, bool continuous) {
    if (code == 0xF4 && !supports_dark(target.caps))
        return {{"supported", false}, {"error", "Absolute Dark Stabilizer levels are not advertised. The separate cycle action does not report a current level."}};
    if (!target.caps.has(code)) return {{"supported", false}, {"error", "Control is not advertised by this monitor"}};
    try {
        DWORD maximum = 0;
        const DWORD value = code == 0xF4 ? read_dark(target.handle) : read_value(target.handle, code, &maximum);
        if (continuous && (maximum != 100 || value > maximum))
            throw std::runtime_error("Unexpected brightness/contrast range");
        return {{"supported", true}, {"current", value},
            {"maximum", continuous ? maximum : (code == 0xF4 ? 3u : 255u)}};
    } catch (const std::runtime_error& error) {
        return {{"supported", false}, {"error", error.what()}};
    }
}

static json snapshot(const Target& target) {
    json result{{"schema_version", 1}, {"ok", true}, {"model", "Dell S2522HG"}, {"display", target.display},
        {"brightness", feature(target, 0x10, true)}, {"contrast", feature(target, 0x12, true)},
        {"dark_stabilizer", feature(target, 0xF4, false)}, {"preset", feature(target, 0xE2, false)},
        {"dark_stabilizer_cycle", {{"supported", supports_dark_cycle(target.caps)},
            {"readback_available", false}, {"current", nullptr}}},
        {"presets", json::array()}};
    if (!supports_dark_cycle(target.caps))
        result["dark_stabilizer_cycle"]["error"] = "Dell S2522HG E3 cycling is not advertised";
    for (const auto& preset : presets) {
        if (!supported(target.caps, preset)) continue;
        result["presets"].push_back({{"id", preset.id}, {"name", preset.name}});
        if (result["preset"]["supported"] == true && result["preset"]["current"] == preset.readback) {
            result["preset"]["id"] = preset.id;
            result["preset"]["name"] = preset.name;
        }
    }
    return result;
}

static void apply_change(const Target& target, const std::string& control, const std::string& value,
                         bool& may_have_changed) {
    BYTE code = control == "brightness" ? 0x10 : control == "contrast" ? 0x12 : 0xF4;
    BYTE read_code = code;
    DWORD wanted = 0, expected = 0;
    if (control == "preset") {
        const auto& preset = find_preset(value);
        if (!supported(target.caps, preset)) throw std::runtime_error("Preset is not advertised by this monitor");
        code = preset.code; read_code = 0xE2; wanted = preset.value; expected = preset.readback;
        read_value(target.handle, read_code);
    } else {
        const auto state = feature(target, code, control != "dark_stabilizer");
        if (state["supported"] != true) throw std::runtime_error(state["error"].get<std::string>());
        wanted = expected = number(value);
        if (control == "dark_stabilizer") wanted += 0x30;
    }
    may_have_changed = true;
    if (!SetVCPFeature(target.handle, code, wanted)) throw std::runtime_error(win_error("Monitor write"));
    // Retry only the readback, never the write.
    for (int attempt = 0; attempt < 5; ++attempt) {
        Sleep(100);
        const DWORD current = control == "dark_stabilizer" ?
            read_dark(target.handle) : read_value(target.handle, read_code);
        if (current == expected) return;
    }
    throw std::runtime_error("Monitor did not confirm the requested value; refresh before retrying");
}

struct OperationLock {
    HANDLE handle = nullptr;
    OperationLock() {
        handle = CreateMutexW(nullptr, FALSE, L"Local\\GodBrain.DeskMonitor.v1");
        if (!handle) throw std::runtime_error(win_error("Monitor operation lock"));
        const DWORD wait = WaitForSingleObject(handle, 0);
        if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
            CloseHandle(handle); handle = nullptr;
            throw std::runtime_error("Another monitor operation is running; try again after it finishes");
        }
    }
    ~OperationLock() { if (handle) { ReleaseMutex(handle); CloseHandle(handle); } }
};

static json self_test() {
    const auto caps = parse_capabilities("(prot(monitor)model(S2522HG)vcp(10 12 14(05 08 0B 0C) DC(00 05) F0(0D 0E 0C 0F 10 11 13) E2(00 20 21 22 2F 04 1E 1F 1D 0E 12 14) E3 F4(30 31 32 33)))");
    auto check = [](bool ok) { if (!ok) throw std::runtime_error("Offline monitor assertion failed"); };
    check(caps.model == "S2522HG" && caps.has(0xE3) && caps.vcp.at(0xE3).empty());
    check(supports_dark(caps));
    for (unsigned level = 0; level <= 3; ++level) check(dark_level(0x30 + level) == level);
    for (const auto& preset : presets) check(supported(caps, preset));
    check(find_preset("game2").code == 0xF0 && find_preset("game2").value == 0x0D &&
        find_preset("game2").readback == 0x1E);
    check(dell_device(L"MONITOR\\DELA1C2\\fixture") && !dell_device(L"MONITOR\\SAM1234\\fixture"));
    auto rejects = [&](auto action) {
        bool rejected = false;
        try { action(); } catch (const std::runtime_error&) { rejected = true; }
        check(rejected);
    };
    for (const auto& control : {"brightness", "contrast"}) {
        validate_change(control, "0"); validate_change(control, "100");
        rejects([&]() { validate_change(control, "101"); });
    }
    for (unsigned level = 0; level <= 3; ++level) validate_change("dark_stabilizer", std::to_string(level));
    rejects([]() { validate_change("dark_stabilizer", "4"); });
    rejects([]() { dark_level(0x3F); });
    rejects([]() { dark_level(0x21); });
    rejects([]() { validate_change("dark_stabilizer", "65535"); });
    rejects([]() { validate_change("brightness", "-1"); });
    rejects([]() { validate_change("brightness", "50junk"); });
    rejects([]() { validate_change("brightness", "50.5"); });
    rejects([]() { validate_change("input", "1"); });
    rejects([]() { validate_change("preset", "hdr"); });
    rejects([]() { parse_capabilities("model(S2522HG)vcp(10(ZZ))"); });
    rejects([]() { parse_capabilities("model(S2522HG)vcp(10"); });
    rejects([]() { parse_capabilities("model(S2522HG)vcp(10 10)"); });
    rejects([]() { parse_capabilities("wrongmodel(S2522HG)vcp(10)"); });
    check(!supported(parse_capabilities("model(S2522HG)vcp(E2(1E) F0(0E))"), find_preset("game2")));
    check(!supports_dark(parse_capabilities("model(S2522HG)vcp(E3 F4(30 31))")));
    const auto legacy = parse_capabilities("model(S2522HG)vcp(10 12 E3)");
    check(supports_dark_cycle(legacy) && !supports_dark(legacy));
    Target zero_handle;
    check(!match_physical_target(zero_handle, nullptr, parse_capabilities("model(OTHER)vcp(E3)"), L"fixture"));
    check(!zero_handle.selected);
    check(match_physical_target(zero_handle, nullptr, legacy, L"fixture"));
    check(zero_handle.selected && zero_handle.handle == nullptr && zero_handle.display == "fixture");
    rejects([&]() { match_physical_target(zero_handle, nullptr, legacy, L"duplicate"); });
    unsigned writes = 0;
    bool changed = false;
    auto write = [&](HANDLE, BYTE code, DWORD value) {
        ++writes;
        check(code == 0xE3 && value == 0x10);
        return TRUE;
    };
    cycle_dark(legacy, nullptr, changed, write);
    check(writes == 1 && changed);
    writes = 0; changed = false;
    rejects([&]() { cycle_dark(parse_capabilities("model(S2522HG)vcp(10)"), nullptr, changed, write); });
    rejects([&]() { cycle_dark(parse_capabilities("model(OTHER)vcp(E3)"), nullptr, changed, write); });
    check(writes == 0 && !changed);
    rejects([&]() {
        cycle_dark(legacy, nullptr, changed, [&](HANDLE, BYTE code, DWORD value) {
            ++writes;
            check(code == 0xE3 && value == 0x10);
            SetLastError(ERROR_GEN_FAILURE);
            return FALSE;
        });
    });
    check(writes == 1 && changed);
    return {{"schema_version", 1}, {"ok", true}, {"self_test", "passed"}};
}

int main(int argc, char** argv) {
    bool may_have_changed = false;
    try {
        if (argc == 2 && std::string(argv[1]) == "--self-test") {
            std::cout << self_test().dump() << '\n'; return 0;
        }
        const bool write = argc == 4 && std::string(argv[1]) == "--set";
        const bool cycle = argc == 2 && std::string(argv[1]) == "--cycle-dark";
        if (!write && !cycle && !(argc == 2 && std::string(argv[1]) == "--read"))
            throw std::runtime_error("Usage: desk-monitor --read | --cycle-dark | --set brightness|contrast|preset|dark_stabilizer VALUE | --self-test");
        if (write) validate_change(argv[2], argv[3]);
        OperationLock lock;
        auto target = select_target();
        if (write) apply_change(target, argv[2], argv[3], may_have_changed);
        if (cycle) cycle_dark(target.caps, target.handle, may_have_changed, SetVCPFeature);
        auto result = snapshot(target);
        if (cycle) {
            result["action"] = {{"control", "dark_stabilizer_cycle"}, {"command_accepted", true},
                {"state_verified", false}, {"current", nullptr}, {"vcp_code", 0xE3},
                {"value", 0x10}, {"write_count", 1}};
        }
        if (write) {
            if (result[argv[2]]["supported"] != true)
                throw std::runtime_error("The post-write snapshot could not read the changed control");
            const DWORD expected = std::string(argv[2]) == "preset" ?
                find_preset(argv[3]).readback : number(argv[3]);
            if (result[argv[2]]["current"] != expected)
                throw std::runtime_error("The monitor value changed again before confirmation; refresh");
            result["changed"] = {{"control", argv[2]}, {"requested", argv[3]}, {"verified", true}};
        }
        target.owner->close();
        std::cout << result.dump() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cout << json{{"schema_version", 1}, {"ok", false}, {"error", error.what()},
            {"may_have_changed", may_have_changed}}.dump() << '\n';
        return 1;
    }
}
