#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <sddl.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include "../cpp_kernel/json.hpp"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using json = nlohmann::json;
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
static void win(bool ok, const char* what) {
    if (!ok) throw std::runtime_error(std::string(what) + ": Windows error " + std::to_string(GetLastError()));
}
static void com(HRESULT hr, const char* what) {
    if (FAILED(hr)) throw std::runtime_error(std::string(what) + ": HRESULT " + std::to_string(hr));
}
static std::string utf8(const std::wstring& text) {
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    win(count > 0 || text.empty(), "UTF-8 size");
    std::string out(static_cast<size_t>(count), '\0');
    if (count) win(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), out.data(), count, nullptr, nullptr) == count, "UTF-8 conversion");
    return out;
}
static std::wstring quote(const std::wstring& text) {
    std::wstring out = L"\"";
    size_t slashes = 0;
    for (wchar_t c : text) {
        if (c == L'\\') { ++slashes; continue; }
        out.append(slashes * (c == L'"' ? 2 : 1), L'\\');
        slashes = 0;
        if (c == L'"') out += L'\\';
        out += c;
    }
    out.append(slashes * 2, L'\\');
    return out + L'"';
}
static std::wstring full(const std::wstring& path) {
    win(!path.empty() && path.size() < 30000, "Path length");
    std::vector<wchar_t> buffer(32768);
    const DWORD count = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
    win(count && count < buffer.size(), "Resolve path");
    std::wstring result(buffer.data(), count);
    while (result.size() > 3 && result.back() == L'\\') result.pop_back();
    return result;
}
static std::wstring sid(HANDLE process) {
    Handle token;
    win(OpenProcessToken(process, TOKEN_QUERY, &token.value) != FALSE, "Read process owner");
    DWORD count = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &count);
    win(count && count <= 65536, "Token size");
    std::vector<BYTE> buffer(count);
    win(GetTokenInformation(token.value, TokenUser, buffer.data(), count, &count) != FALSE, "Token owner");
    wchar_t* value = nullptr;
    win(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &value) != FALSE, "Owner SID");
    const std::wstring result(value);
    LocalFree(value);
    return result;
}
struct Identity {
    std::wstring root, app, tag, owner, mutex;
};
static Identity identity(const std::wstring& path) {
    Identity result;
    result.root = full(path);
    const int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, result.root.data(),
        static_cast<int>(result.root.size()), nullptr, 0, nullptr, nullptr, 0);
    win(count > 0, "Desk path case mapping size");
    std::wstring normalized(static_cast<size_t>(count), L'\0');
    win(LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, result.root.data(),
        static_cast<int>(result.root.size()), normalized.data(), count, nullptr, nullptr, 0) == count,
        "Desk path case mapping");
    // Retain existing ASCII identities after Windows filesystem case mapping.
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
        [](wchar_t c) { return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + (L'a' - L'A')) : c; });
    BYTE digest[32]{};
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        throw std::runtime_error("SHA-256 provider unavailable");
    const NTSTATUS hashed = BCryptHash(algorithm, nullptr, 0,
        reinterpret_cast<PUCHAR>(normalized.data()), static_cast<ULONG>(normalized.size() * sizeof(wchar_t)),
        digest, sizeof(digest));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (hashed < 0) throw std::runtime_error("Desk identity hash failed");
    std::wstring suffix;
    for (size_t i = 0; i < 8; ++i) {
        suffix += L"0123456789abcdef"[digest[i] >> 4];
        suffix += L"0123456789abcdef"[digest[i] & 15];
    }
    result.app = L"GodBrain.CommandCenter." + suffix;
    result.tag = L"GodBrain.Desk." + suffix;
    result.owner = sid(GetCurrentProcess());
    DWORD session = 0;
    win(ProcessIdToSessionId(GetCurrentProcessId(), &session) != FALSE, "Session identity");
    result.mutex = L"Local\\" + result.tag + L"." + result.owner + L"." + std::to_wstring(session);
    return result;
}
static std::wstring executable() {
    std::vector<wchar_t> buffer(32768);
    const DWORD count = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    win(count && count < buffer.size(), "Executable path");
    return std::wstring(buffer.data(), count);
}
static void property(IPropertyStore* store, const PROPERTYKEY& key, const std::wstring& value) {
    PROPVARIANT item{};
    com(InitPropVariantFromString(value.c_str(), &item), "Property value");
    const HRESULT hr = store->SetValue(key, item);
    PropVariantClear(&item);
    com(hr, "Set shell property");
}
static std::wstring window_identity(const Identity& id, HWND window, bool secondary) {
    ComPtr<IPropertyStore> store;
    com(SHGetPropertyStoreForWindow(window, IID_PPV_ARGS(&store)), "Window identity store");
    property(store.Get(), PKEY_AppUserModel_ID, id.app);
    property(store.Get(), PKEY_AppUserModel_RelaunchCommand,
        quote(executable()) + L" launch " + quote(id.root));
    property(store.Get(), PKEY_AppUserModel_RelaunchDisplayNameResource, L"GodBrain Desk");
    property(store.Get(), PKEY_AppUserModel_RelaunchIconResource,
        id.root + L"\\godbrain_core\\frontend\\command-center.ico,0");
    com(store->Commit(), "Commit window identity");
    PROPVARIANT relaunch{};
    com(store->GetValue(PKEY_AppUserModel_RelaunchCommand, &relaunch), "Read window relaunch command");
    const std::wstring command = relaunch.vt == VT_LPWSTR && relaunch.pwszVal ? relaunch.pwszVal : L"";
    PropVariantClear(&relaunch);
    if (command.empty()) throw std::runtime_error("Window relaunch command was not retained");
    win(SetPropW(window, id.tag.c_str(), reinterpret_cast<HANDLE>(static_cast<uintptr_t>(secondary ? 2 : 1))) != FALSE, "Window tag");
    return command;
}
static bool owns(HWND window, const Identity& id) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    Handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    if (!process.value) return false;
    std::vector<wchar_t> image(32768);
    DWORD count = static_cast<DWORD>(image.size());
    if (!QueryFullProcessImageNameW(process.value, 0, image.data(), &count)) return false;
    if (_wcsicmp(image.data(), L"C:\\pwsh\\pwsh.exe") != 0) return false;
    return sid(process.value) == id.owner;
}
static bool legacy(HWND window, const Identity& id) {
    wchar_t title[128]{};
    GetWindowTextW(window, title, 128);
    if (wcscmp(title, L"Command Center") != 0 || !owns(window, id)) return false;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    Handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    using Query = LONG (WINAPI*)(HANDLE, ULONG, void*, ULONG, ULONG*);
    const auto address = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess");
    Query query = nullptr;
    static_assert(sizeof(query) == sizeof(address));
    std::memcpy(&query, &address, sizeof(query));
    if (!query) return false;
    ULONG count = 0;
    query(process.value, 60, nullptr, 0, &count);
    if (count < sizeof(void*) * 2 || count > 65536) return false;
    std::vector<BYTE> data(count);
    if (query(process.value, 60, data.data(), count, &count) < 0) return false;
    struct Unicode { USHORT length, maximum; wchar_t* buffer; };
    const auto* text = reinterpret_cast<const Unicode*>(data.data());
    const auto begin = reinterpret_cast<uintptr_t>(data.data());
    const auto at = reinterpret_cast<uintptr_t>(text->buffer);
    if (text->length % 2 || at < begin || at > begin + data.size() ||
        text->length > begin + data.size() - at) return false;
    const std::wstring command(text->buffer, text->length / sizeof(wchar_t));
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(command.c_str(), &argc);
    if (!argv) return false;
    bool file = false, host = false;
    const std::wstring expected = id.root + L"\\scripts\\Show-DeskMenu.ps1";
    for (int i = 1; i < argc; ++i) {
        if (_wcsicmp(argv[i], L"-ControlPanelHost") == 0) host = true;
        if (_wcsicmp(argv[i], L"-File") == 0 && i + 1 < argc &&
            _wcsicmp(argv[i + 1], expected.c_str()) == 0) file = true;
    }
    LocalFree(argv);
    return file && host;
}
struct Search {
    const Identity* id;
    HWND primary = nullptr, secondary = nullptr;
    std::string error;
};
static BOOL CALLBACK find_window(HWND window, LPARAM parameter) {
    auto& search = *reinterpret_cast<Search*>(parameter);
    try {
        const HANDLE tag = GetPropW(window, search.id->tag.c_str());
        if (tag && owns(window, *search.id)) {
            if (tag == reinterpret_cast<HANDLE>(1)) search.primary = window;
            else if (!search.secondary) search.secondary = window;
        } else if (!tag && legacy(window, *search.id)) search.primary = window;
    } catch (const std::exception& e) { search.error = e.what(); return FALSE; }
    return TRUE;
}
static json activate(const Identity& id) {
    Search search{&id};
    EnumWindows(find_window, reinterpret_cast<LPARAM>(&search));
    if (!search.error.empty()) throw std::runtime_error(search.error);
    const HWND window = search.primary ? search.primary : search.secondary;
    if (!window) return {{"status", "absent"}};
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    const bool tagged = GetPropW(window, id.tag.c_str()) != nullptr;
    if (!tagged) window_identity(id, window, false);
    Handle event{OpenEventW(EVENT_MODIFY_STATE, FALSE,
        (L"Local\\GodBrain.Desk.Show." + std::to_wstring(pid)).c_str())};
    if (event.value) win(SetEvent(event.value) != FALSE, "Desk show signal");
    else {
        win(!tagged || GetLastError() == ERROR_FILE_NOT_FOUND, "Open Desk show signal");
        if (!IsWindowVisible(window)) {
            // WS_EX_APPWINDOW keeps the WinForms parking owner intact.
            SetLastError(0);
            const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
            win(SetWindowLongPtrW(window, GWL_EXSTYLE, (style | WS_EX_APPWINDOW) & ~WS_EX_TOOLWINDOW) != 0 ||
                GetLastError() == 0, "Restore taskbar style");
        }
    }
    AllowSetForegroundWindow(pid);
    win(ShowWindowAsync(window, SW_RESTORE) != FALSE, "Restore Desk");
    const bool foreground = SetForegroundWindow(window) != FALSE;
    return {{"status", "shown"}, {"pid", pid}, {"foreground", foreground}, {"signal", event.value != nullptr}};
}
static ComPtr<IShellLinkW> task(const Identity& id, const wchar_t* title, bool admin) {
    ComPtr<IShellLinkW> link;
    com(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)), "Create task");
    com(link->SetPath(executable().c_str()), "Task executable");
    const std::wstring args = L"launch " + quote(id.root) + (admin ? L" --admin" : L" --new-instance");
    com(link->SetArguments(args.c_str()), "Task arguments");
    com(link->SetWorkingDirectory(id.root.c_str()), "Task working directory");
    com(link->SetIconLocation((id.root + L"\\godbrain_core\\frontend\\command-center.ico").c_str(), 0), "Task icon");
    ComPtr<IPropertyStore> store;
    com(link.As(&store), "Task properties");
    property(store.Get(), PKEY_Title, title);
    property(store.Get(), PKEY_AppUserModel_ID, id.app);
    com(store->Commit(), "Task identity");
    return link;
}
static void tasks(const Identity& id) {
    com(SetCurrentProcessExplicitAppUserModelID(id.app.c_str()), "Task app identity");
    ComPtr<ICustomDestinationList> list;
    com(CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list)), "Jump List");
    com(list->SetAppID(id.app.c_str()), "Jump List identity");
    UINT slots = 0;
    ComPtr<IObjectArray> removed;
    com(list->BeginList(&slots, IID_PPV_ARGS(&removed)), "Begin Jump List");
    try {
        ComPtr<IObjectCollection> collection;
        com(CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&collection)), "Task collection");
        com(collection->AddObject(task(id, L"GodBrain Desk - New instance", false).Get()), "New instance task");
        com(collection->AddObject(task(id, L"Run as Administrator", true).Get()), "Admin task");
        ComPtr<IObjectArray> items;
        com(collection.As(&items), "Task array");
        com(list->AddUserTasks(items.Get()), "Install tasks");
        com(list->CommitList(), "Commit Jump List");
    } catch (...) { list->AbortList(); throw; }
}
static void install(const Identity& id, const std::wstring& path) {
    ComPtr<IShellLinkW> link;
    com(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)), "Shortcut");
    ComPtr<IPersistFile> file;
    com(link.As(&file), "Shortcut persistence");
    com(file->Load(path.c_str(), STGM_READWRITE), "Read existing pin");
    com(link->SetPath(executable().c_str()), "Pin executable");
    com(link->SetArguments((L"launch " + quote(id.root)).c_str()), "Pin arguments");
    com(link->SetWorkingDirectory(id.root.c_str()), "Pin working directory");
    com(link->SetIconLocation((id.root + L"\\godbrain_core\\frontend\\command-center.ico").c_str(), 0), "Pin icon");
    ComPtr<IPropertyStore> store;
    com(link.As(&store), "Pin properties");
    property(store.Get(), PKEY_AppUserModel_ID, id.app);
    com(store->Commit(), "Pin identity");
    com(file->Save(path.c_str(), TRUE), "Save existing pin");
    SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, path.c_str(), nullptr);
    tasks(id);
}
static json launch(const Identity& id, bool fresh, bool admin) {
    if (!fresh && !admin) {
        const auto found = activate(id);
        if (found.at("status") != "absent") return found;
    }
    const std::wstring script = id.root + L"\\scripts\\Show-DeskMenu.ps1";
    win(GetFileAttributesW(script.c_str()) != INVALID_FILE_ATTRIBUTES, "Desk script");
    const std::wstring args = L"-NoProfile -Sta -File " + quote(script) + L" -ControlPanelHost" +
        ((fresh || admin) ? L" -NewInstance" : L"");
    DWORD pid = 0;
    if (admin) {
        SHELLEXECUTEINFOW run{sizeof(run)};
        run.fMask = SEE_MASK_NOCLOSEPROCESS;
        run.lpVerb = L"runas"; run.lpFile = L"C:\\pwsh\\pwsh.exe"; run.lpParameters = args.c_str();
        run.lpDirectory = id.root.c_str(); run.nShow = SW_HIDE;
        win(ShellExecuteExW(&run) != FALSE, "Administrator launch");
        if (run.hProcess) { pid = GetProcessId(run.hProcess); CloseHandle(run.hProcess); }
    } else {
        std::wstring command = quote(L"C:\\pwsh\\pwsh.exe") + L" " + args;
        STARTUPINFOW startup{sizeof(startup)};
        startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};
        win(CreateProcessW(L"C:\\pwsh\\pwsh.exe", command.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, id.root.c_str(), &startup, &process) != FALSE, "Desk launch");
        pid = process.dwProcessId;
        CloseHandle(process.hThread); CloseHandle(process.hProcess);
    }
    return {{"status", "started"}, {"new_instance", fresh || admin}, {"pid", pid}};
}
int wmain(int argc, wchar_t** argv) {
    bool initialized = false;
    try {
        if ((argc == 2 || argc == 3) && wcscmp(argv[1], L"--self-test") == 0) {
            if (quote(L"a b\\") != L"\"a b\\\\\"" || quote(L"a\"b") != L"\"a\\\"b\"")
                throw std::runtime_error("Windows argument quoting regression");
            std::cout << json({{"status", "pass"}, {"checks", {"spaces", "quotes", "trailing backslash"}}}).dump() << '\n';
            return 0;
        }
        if (argc < 3) throw std::runtime_error("Usage: desk-shell info|activate|launch|attach|install <repo> [argument]");
        com(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED), "Shell COM");
        initialized = true;
        const Identity id = identity(argv[2]);
        const std::wstring mode = argv[1];
        json result;
        if (mode == L"info" && argc == 3)
            result = {{"status", "ok"}, {"app_id", utf8(id.app)}, {"mutex_name", utf8(id.mutex)}};
        else if (mode == L"activate" && argc == 3) result = activate(id);
        else if (mode == L"launch" && (argc == 3 || (argc == 4 &&
            (wcscmp(argv[3], L"--new-instance") == 0 || wcscmp(argv[3], L"--admin") == 0))))
            result = launch(id, argc == 4, argc == 4 && wcscmp(argv[3], L"--admin") == 0);
        else if (mode == L"attach" && (argc == 4 || (argc == 5 && wcscmp(argv[4], L"--secondary") == 0))) {
            size_t consumed = 0;
            const auto value = std::stoull(argv[3], &consumed, 10);
            if (consumed != wcslen(argv[3])) throw std::runtime_error("Invalid window handle");
            const HWND window = reinterpret_cast<HWND>(static_cast<uintptr_t>(value));
            win(IsWindow(window) != FALSE && owns(window, id), "Desk window ownership");
            const auto relaunch = window_identity(id, window, argc == 5);
            result = {{"status", "attached"}, {"app_id", utf8(id.app)}, {"relaunch_command", utf8(relaunch)}};
        } else if (mode == L"install" && argc == 4) {
            install(id, full(argv[3]));
            result = {{"status", "installed"}, {"app_id", utf8(id.app)}};
        } else throw std::runtime_error("Unsupported Desk shell command");
        std::cout << result.dump() << '\n';
        CoUninitialize();
        return 0;
    } catch (const std::exception& e) {
        const std::string error = e.what();
        std::cerr << json({{"status", "failed"}, {"error", error}}).dump() << '\n';
        if (!GetStdHandle(STD_ERROR_HANDLE) || GetStdHandle(STD_ERROR_HANDLE) == INVALID_HANDLE_VALUE)
            MessageBoxA(nullptr, error.c_str(), "GodBrain Desk launch failed", MB_OK | MB_ICONERROR);
        if (initialized) CoUninitialize();
        return 1;
    }
}
