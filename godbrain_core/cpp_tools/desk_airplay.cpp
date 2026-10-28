#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <objbase.h>
#include <UIAutomation.h>
#include <wrl/client.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include "../cpp_kernel/json.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using json = nlohmann::json;

static void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        throw std::runtime_error(std::string(operation) + " failed (HRESULT " +
            std::to_string(static_cast<unsigned long>(result)) + ")");
    }
}

static std::uint64_t number(const std::wstring& text) {
    if (text.empty()) throw std::runtime_error("Missing process identity");
    std::uint64_t result = 0;
    for (const wchar_t character : text) {
        if (character < L'0' || character > L'9' ||
            result > (std::numeric_limits<std::uint64_t>::max() -
                static_cast<unsigned>(character - L'0')) / 10) {
            throw std::runtime_error("Invalid process identity");
        }
        result = result * 10 + static_cast<unsigned>(character - L'0');
    }
    return result;
}

struct ProcessCloser {
    void operator()(void* value) const { if (value) ::CloseHandle(value); }
};
using ProcessHandle = std::unique_ptr<void, ProcessCloser>;

struct FreeBstr {
    void operator()(wchar_t* value) const { SysFreeString(value); }
};
using Bstr = std::unique_ptr<wchar_t, FreeBstr>;

static std::wstring name(IUIAutomationElement* element) {
    BSTR value = nullptr;
    check(element->get_CurrentName(&value), "Receiver accessible name");
    Bstr cleanup(value);
    const auto length = SysStringLen(value);
    if (length > 1024) throw std::runtime_error("Receiver accessible name is too long");
    return value ? std::wstring(value, length) : L"";
}

static void assert_element_process(IUIAutomationElement* element, DWORD pid) {
    int observed = 0;
    check(element->get_CurrentProcessId(&observed), "Receiver element identity");
    if (observed <= 0 || static_cast<DWORD>(observed) != pid)
        throw std::runtime_error("Receiver element belongs to another process");
}

struct PlaybackControl {
    std::wstring caption;
    bool enabled;
};

static std::string state(const std::wstring& connection,
        const std::vector<PlaybackControl>& controls) {
    if (connection == L"Ready") return "ready";
    const std::wstring prefix = L"Connected to ";
    if (connection.compare(0, prefix.size(), prefix) != 0 ||
        connection.size() == prefix.size()) {
        throw std::runtime_error("Receiver connection state is unavailable or unsupported");
    }
    if (controls.size() > 1)
        throw std::runtime_error("Receiver playback control is ambiguous");
    if (controls.empty() || !controls.front().enabled) return "connected";
    if (controls.front().caption == L"Pause") return "playing";
    if (controls.front().caption == L"Play") return "paused";
    throw std::runtime_error("Receiver playback state is unsupported");
}

struct WindowQuery {
    DWORD pid;
    std::vector<HWND> matches;
};

static BOOL CALLBACK find_window(HWND window, LPARAM parameter) {
    auto& query = *reinterpret_cast<WindowQuery*>(parameter);
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != query.pid || GetWindow(window, GW_OWNER) != nullptr) return TRUE;
    std::array<wchar_t, 256> class_name{};
    if (!GetClassNameW(window, class_name.data(), static_cast<int>(class_name.size()))) return TRUE;
    const std::wstring text(class_name.data());
    const auto ends_with = [&](const std::wstring& suffix) {
        return text.size() >= suffix.size() &&
            text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
    };
    if (text.compare(0, 2, L"Qt") == 0 &&
        (ends_with(L"QWindowIcon") || ends_with(L"QWindowOwnDCIcon")) &&
        (GetWindowLongW(window, GWL_STYLE) & WS_CAPTION) == WS_CAPTION) {
        query.matches.push_back(window);
    }
    return TRUE;
}

static ProcessHandle open_receiver(DWORD pid, std::uint64_t created) {
    ProcessHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid));
    if (!process) throw std::runtime_error("Could not inspect the receiver process");
    std::array<wchar_t, 32768> path{};
    DWORD length = static_cast<DWORD>(path.size());
    if (!QueryFullProcessImageNameW(process.get(), 0, path.data(), &length) ||
        _wcsicmp(path.data(), L"C:\\Tools\\ShairportQt\\ShairportQt.exe") != 0) {
        throw std::runtime_error("Unexpected receiver executable");
    }
    FILETIME start{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(process.get(), &start, &exit, &kernel, &user))
        throw std::runtime_error("Could not inspect receiver creation time");
    const auto observed = (static_cast<std::uint64_t>(start.dwHighDateTime) << 32) |
        start.dwLowDateTime;
    if (observed != created) throw std::runtime_error("Receiver process identity changed");
    DWORD session = 0, own_session = 0;
    if (!ProcessIdToSessionId(pid, &session) ||
        !ProcessIdToSessionId(GetCurrentProcessId(), &own_session) || session != own_session) {
        throw std::runtime_error("Receiver is outside this session");
    }
    if (WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT)
        throw std::runtime_error("Receiver process has exited");
    return process;
}

static ComPtr<IUIAutomationCondition> property_condition(IUIAutomation* automation,
        PROPERTYID property, LONG value) {
    VARIANT variant{};
    variant.vt = VT_I4;
    variant.lVal = value;
    ComPtr<IUIAutomationCondition> condition;
    check(automation->CreatePropertyCondition(property, variant, &condition), "Receiver property filter");
    return condition;
}

struct ReceiverTransport {
    bool listening = false;
    bool connected = false;
};

template<typename Table> static ReceiverTransport transport_rows(const Table& table, DWORD pid) {
    ReceiverTransport result;
    for (DWORD i = 0; i < table.dwNumEntries; ++i) {
        const auto& listener = table.table[i];
        if (listener.dwOwningPid != pid || listener.dwState != MIB_TCP_STATE_LISTEN) continue;
        result.listening = true;
        for (DWORD j = 0; j < table.dwNumEntries; ++j) {
            const auto& peer = table.table[j];
            if (peer.dwOwningPid == pid && peer.dwState == MIB_TCP_STATE_ESTAB &&
                peer.dwLocalPort == listener.dwLocalPort) result.connected = true;
        }
    }
    return result;
}

template<typename Table> static ReceiverTransport receiver_transport(DWORD pid, ULONG family) {
    DWORD bytes = 0;
    if (GetExtendedTcpTable(nullptr, &bytes, FALSE, family, TCP_TABLE_OWNER_PID_ALL, 0) != ERROR_INSUFFICIENT_BUFFER ||
        bytes > 16 * 1024 * 1024) throw std::runtime_error("Receiver TCP table size is unavailable");
    std::vector<BYTE> storage(bytes);
    if (GetExtendedTcpTable(storage.data(), &bytes, FALSE, family, TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR)
        throw std::runtime_error("Receiver TCP table is unavailable");
    return transport_rows(*reinterpret_cast<const Table*>(storage.data()), pid);
}

static std::string hidden_state(bool listening, bool connected, const std::vector<int>& playback) {
    if (!listening) throw std::runtime_error("Receiver listener disappeared during hidden inspection");
    if (!connected) return "listening";
    if (playback.size() > 1) throw std::runtime_error("Receiver Windows media session is ambiguous");
    if (playback.empty()) return "connected";
    using Status = winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus;
    if (playback.front() == static_cast<int>(Status::Playing)) return "playing";
    if (playback.front() == static_cast<int>(Status::Paused)) return "paused";
    return "connected";
}

static std::string read_hidden_receiver(DWORD pid) {
    const auto ipv4 = receiver_transport<MIB_TCPTABLE_OWNER_PID>(pid, AF_INET);
    const auto ipv6 = receiver_transport<MIB_TCP6TABLE_OWNER_PID>(pid, AF_INET6);
    const bool listening = ipv4.listening || ipv6.listening;
    const bool connected = ipv4.connected || ipv6.connected;
    std::vector<int> playback;
    if (connected) {
        using Manager = winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager;
        auto request = Manager::RequestAsync();
        if (request.wait_for(std::chrono::milliseconds(1500)) != winrt::Windows::Foundation::AsyncStatus::Completed)
            throw std::runtime_error("Receiver Windows media-session query timed out");
        const auto sessions = request.GetResults().GetSessions();
        if (sessions.Size() > 128) throw std::runtime_error("Windows media-session count is unsupported");
        for (const auto& session : sessions) {
            if (session.SourceAppUserModelId() == L"Airplay.Shairport.1.0")
                playback.push_back(static_cast<int>(session.GetPlaybackInfo().PlaybackStatus()));
        }
    }
    const auto after4 = receiver_transport<MIB_TCPTABLE_OWNER_PID>(pid, AF_INET);
    const auto after6 = receiver_transport<MIB_TCP6TABLE_OWNER_PID>(pid, AF_INET6);
    if (listening != (after4.listening || after6.listening) ||
        connected != (after4.connected || after6.connected))
        throw std::runtime_error("Receiver transport changed during hidden inspection");
    return hidden_state(listening, connected, playback);
}

static json read_receiver(DWORD pid, std::uint64_t created) {
    auto process = open_receiver(pid, created);
    WindowQuery query{pid, {}};
    if (!EnumWindows(find_window, reinterpret_cast<LPARAM>(&query)) || query.matches.size() != 1)
        throw std::runtime_error("Receiver main window is missing or ambiguous");
    const HWND window = query.matches.front();
    if (!IsWindowVisible(window)) {
        const auto observed_state = read_hidden_receiver(pid);
        DWORD observed_pid = 0;
        if (!IsWindow(window) || IsWindowVisible(window) ||
            !GetWindowThreadProcessId(window, &observed_pid) || observed_pid != pid ||
            WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT)
            throw std::runtime_error("Receiver identity or visibility changed during hidden inspection");
        return {{"schema_version", 1}, {"ok", true}, {"pid", pid},
            {"created", std::to_string(created)}, {"source", "shairportqt-windows-media"},
            {"state", observed_state}, {"audio_output_verified", false}};
    }
    ComPtr<IUIAutomation> automation;
    check(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&automation)), "Windows UI Automation");
    ComPtr<IUIAutomation2> automation2;
    check(automation.As(&automation2), "UI Automation timeouts");
    check(automation2->put_ConnectionTimeout(500), "UI Automation connection timeout");
    check(automation2->put_TransactionTimeout(500), "UI Automation transaction timeout");
    ComPtr<IUIAutomationElement> root;
    check(automation->ElementFromHandle(window, &root), "Receiver main window");
    assert_element_process(root.Get(), pid);
    const auto group = property_condition(automation.Get(), UIA_ControlTypePropertyId, UIA_GroupControlTypeId);
    ComPtr<IUIAutomationElementArray> groups;
    check(root->FindAll(TreeScope_Children, group.Get(), &groups), "Receiver connection group");
    int count = 0;
    check(groups->get_Length(&count), "Receiver group count");
    if (count < 1 || count > 12) throw std::runtime_error("Receiver connection group is unavailable");
    ComPtr<IUIAutomationElement> connection_group;
    check(groups->GetElement(0, &connection_group), "Receiver connection group");
    assert_element_process(connection_group.Get(), pid);
    const auto text = property_condition(automation.Get(), UIA_ControlTypePropertyId, UIA_TextControlTypeId);
    ComPtr<IUIAutomationElementArray> labels;
    check(connection_group->FindAll(TreeScope_Children, text.Get(), &labels), "Receiver connection label");
    check(labels->get_Length(&count), "Receiver connection label count");
    if (count != 1) throw std::runtime_error("Receiver connection label is missing or ambiguous");
    ComPtr<IUIAutomationElement> label;
    check(labels->GetElement(0, &label), "Receiver connection label");
    assert_element_process(label.Get(), pid);
    const auto connection = name(label.Get());

    // Read button captions only, never edit values, metadata labels or artwork.
    const auto button = property_condition(automation.Get(), UIA_ControlTypePropertyId, UIA_ButtonControlTypeId);
    ComPtr<IUIAutomationElementArray> buttons;
    check(root->FindAll(TreeScope_Descendants, button.Get(), &buttons), "Receiver playback controls");
    check(buttons->get_Length(&count), "Receiver button count");
    if (count < 0 || count > 64) throw std::runtime_error("Receiver button count is unsupported");
    std::vector<PlaybackControl> controls;
    for (int i = 0; i < count; ++i) {
        ComPtr<IUIAutomationElement> element;
        check(buttons->GetElement(i, &element), "Receiver playback control");
        assert_element_process(element.Get(), pid);
        const auto caption = name(element.Get());
        if (caption != L"Play" && caption != L"Pause") continue;
        BOOL enabled = FALSE;
        check(element->get_CurrentIsEnabled(&enabled), "Receiver playback-control state");
        controls.push_back({caption, enabled != FALSE});
    }
    // Reject a connection change during the control read rather than mixing states.
    if (connection != name(label.Get())) throw std::runtime_error("Receiver connection changed during inspection");
    DWORD window_pid = 0;
    if (!IsWindow(window) || !GetWindowThreadProcessId(window, &window_pid) ||
        window_pid != pid || WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT) {
        throw std::runtime_error("Receiver identity changed during inspection");
    }
    return {{"schema_version", 1}, {"ok", true}, {"pid", pid},
        {"created", std::to_string(created)}, {"source", "shairportqt-uia"},
        {"state", state(connection, controls)}, {"audio_output_verified", false}};
}

static void require(bool condition) {
    if (!condition) throw std::runtime_error("AirPlay state self-test failed");
}

template<typename Action> static void rejects(Action action) {
    bool rejected = false;
    try { action(); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected);
}

static void self_test() {
    require(state(L"Ready", {}) == "ready");
    require(state(L"Ready", {{L"Pause", true}}) == "ready");
    require(state(L"Connected to synthetic sender", {{L"Pause", true}}) == "playing");
    require(state(L"Connected to synthetic sender", {{L"Play", true}}) == "paused");
    require(state(L"Connected to synthetic sender", {{L"Pause", false}}) == "connected");
    require(state(L"Connected to synthetic sender", {}) == "connected");
    rejects([] { state(L"Connected to ", {{L"Pause", true}}); });
    rejects([] { state(L"...", {{L"Pause", true}}); });
    rejects([] { state(L"Receiver error", {}); });
    rejects([] { state(L"Translated receiver status", {}); });
    rejects([] { state(L"Connected to fixture", {{L"Play", true}, {L"Pause", true}}); });
    rejects([] { state(L"Connected to fixture", {{L"Unexpected", true}}); });
    require(hidden_state(true, false, {4}) == "listening");
    require(hidden_state(true, true, {4}) == "playing");
    require(hidden_state(true, true, {5}) == "paused");
    require(hidden_state(true, true, {}) == "connected");
    require(hidden_state(true, true, {3}) == "connected");
    rejects([] { hidden_state(false, true, {4}); });
    rejects([] { hidden_state(true, true, {4, 5}); });
    struct TransportFixture {
        DWORD dwNumEntries = 4;
        MIB_TCPROW_OWNER_PID table[4]{};
    } transport;
    transport.table[0].dwOwningPid = 7;
    transport.table[0].dwState = MIB_TCP_STATE_LISTEN;
    transport.table[0].dwLocalPort = 5000;
    transport.table[1].dwOwningPid = 99;
    transport.table[1].dwState = MIB_TCP_STATE_ESTAB;
    transport.table[1].dwLocalPort = 5000;
    transport.table[2].dwOwningPid = 7;
    transport.table[2].dwState = MIB_TCP_STATE_ESTAB;
    transport.table[2].dwLocalPort = 54000;
    require(transport_rows(transport, 7).listening);
    require(!transport_rows(transport, 7).connected);
    require(!transport_rows(transport, 99).listening);
    transport.table[3].dwOwningPid = 7;
    transport.table[3].dwState = MIB_TCP_STATE_ESTAB;
    transport.table[3].dwLocalPort = 5000;
    require(transport_rows(transport, 7).connected);
    require(number(L"18446744073709551615") == std::numeric_limits<std::uint64_t>::max());
    for (const auto* invalid : {L"", L"-1", L"+1", L"12x", L" 12", L"18446744073709551616"})
        rejects([&] { number(invalid); });
    std::cout << json({{"ok", true}, {"self_test", "pass"}}).dump() << '\n';
}

int wmain(int argc, wchar_t* argv[]) {
    bool com_initialized = false;
    try {
        if (argc == 2 && std::wstring(argv[1]) == L"--self-test") {
            self_test();
            return 0;
        }
        if (argc != 5 || std::wstring(argv[1]) != L"--pid" || std::wstring(argv[3]) != L"--created")
            throw std::runtime_error("Usage: desk-airplay --pid PID --created FILETIME");
        const auto pid = number(argv[2]);
        const auto created = number(argv[4]);
        if (pid == 0 || pid > std::numeric_limits<DWORD>::max() || created == 0)
            throw std::runtime_error("Invalid receiver process identity");
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        com_initialized = true;
        const auto result = read_receiver(static_cast<DWORD>(pid), created);
        winrt::uninit_apartment();
        com_initialized = false;
        std::cout << result.dump() << '\n';
        return 0;
    } catch (const std::exception& error) {
        if (com_initialized) winrt::uninit_apartment();
        std::cout << json({{"schema_version", 1}, {"ok", false}, {"error", error.what()}}).dump() << '\n';
        return 1;
    }
}
