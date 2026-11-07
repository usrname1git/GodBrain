#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <winioctl.h>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

static std::function<void()> after_resolve, after_entry, before_replace, before_move;
static std::function<void()> after_close;
static std::function<void()> before_create;
static HANDLE resolved_handle = INVALID_HANDLE_VALUE;
static std::string resolve_target, entry_target, created_temp, move_target;
static bool fail_write = false, fail_flush = false, fail_replace = false, short_write = false;
static DWORD WINAPI fixture_final(HANDLE, LPSTR, DWORD, DWORD);
static HANDLE WINAPI fixture_first(LPCSTR, LPWIN32_FIND_DATAA);
static BOOL WINAPI fixture_next(HANDLE, LPWIN32_FIND_DATAA);
static HANDLE WINAPI fixture_create(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
static BOOL WINAPI fixture_write(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
static BOOL WINAPI fixture_flush(HANDLE);
static BOOL WINAPI fixture_set(HANDLE, FILE_INFO_BY_HANDLE_CLASS, LPVOID, DWORD);
static BOOL WINAPI fixture_close(HANDLE);
static BOOL WINAPI fixture_move(LPCSTR, LPCSTR);
static FARPROC WINAPI fixture_proc(HMODULE, LPCSTR);
static NTSTATUS NTAPI fixture_rename(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, FILE_INFORMATION_CLASS);
static NTSTATUS NTAPI fixture_open(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
                                   PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);

#define GetFinalPathNameByHandleA fixture_final
#define FindFirstFileA fixture_first
#define FindNextFileA fixture_next
#define CreateFileA fixture_create
#define WriteFile fixture_write
#define FlushFileBuffers fixture_flush
#define SetFileInformationByHandle fixture_set
#define CloseHandle fixture_close
#define MoveFileA fixture_move
#define GetProcAddress fixture_proc
#ifdef GODBRAIN_PATH_BEFORE
#include "local_tools.before.cpp"
#else
#include "local_tools.cpp"
#endif
#undef GetFinalPathNameByHandleA
#undef FindFirstFileA
#undef FindNextFileA
#undef CreateFileA
#undef WriteFile
#undef FlushFileBuffers
#undef SetFileInformationByHandle
#undef CloseHandle
#undef MoveFileA
#undef GetProcAddress

namespace memory {
json working_shelf(const json&) { throw std::runtime_error("Unexpected fixture shelf call"); }
json shared_context(const std::string&, const std::string&, const std::string&, const godbrain_rag::Client&) {
    throw std::runtime_error("Unexpected fixture context call");
}
json research_document(const std::string&, bool) { throw std::runtime_error("Unexpected fixture document call"); }
}

static void check(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
static DWORD WINAPI fixture_final(HANDLE handle, LPSTR name, DWORD size, DWORD flags) {
    const DWORD n = GetFinalPathNameByHandleA(handle, name, size, flags);
    if (n && n < size && after_resolve &&
        local_tools::ascii_lower(local_tools::strip_extended_prefix(std::string(name, n))) ==
            local_tools::ascii_lower(resolve_target)) {
        after_close = std::move(after_resolve);
        after_resolve = {};
        resolved_handle = handle;
    }
    return n;
}
static BOOL WINAPI fixture_close(HANDLE handle) {
    const BOOL success = CloseHandle(handle);
    if (success && handle == resolved_handle && after_close) {
        resolved_handle = INVALID_HANDLE_VALUE;
        auto action = std::move(after_close);
        after_close = {};
        action();
    }
    return success;
}
static void found_entry(const WIN32_FIND_DATAA* data) {
    if (after_entry && data->cFileName == entry_target) {
        auto action = std::move(after_entry);
        after_entry = {};
        action();
    }
}
static HANDLE WINAPI fixture_first(LPCSTR name, LPWIN32_FIND_DATAA data) {
    HANDLE h = FindFirstFileA(name, data);
    if (h != INVALID_HANDLE_VALUE) found_entry(data);
    return h;
}
static BOOL WINAPI fixture_next(HANDLE handle, LPWIN32_FIND_DATAA data) {
    const BOOL result = FindNextFileA(handle, data);
    if (result) found_entry(data);
    return result;
}
static HANDLE WINAPI fixture_create(LPCSTR name, DWORD access, DWORD share,
    LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags, HANDLE templ) {
    HANDLE h = CreateFileA(name, access, share, security, disposition, flags, templ);
    if (disposition == CREATE_NEW && h != INVALID_HANDLE_VALUE) created_temp = name;
    return h;
}
static BOOL WINAPI fixture_write(HANDLE handle, LPCVOID bytes, DWORD count,
    LPDWORD written, LPOVERLAPPED overlapped) {
    if (fail_write) {
        fail_write = false;
        *written = 0;
        SetLastError(ERROR_WRITE_FAULT);
        return FALSE;
    }
    if (short_write) {
        short_write = false;
        count = (std::min)(count, DWORD{3});
    }
    return WriteFile(handle, bytes, count, written, overlapped);
}
static BOOL WINAPI fixture_flush(HANDLE handle) {
    if (fail_flush) {
        fail_flush = false;
        SetLastError(ERROR_WRITE_FAULT);
        return FALSE;
    }
    return FlushFileBuffers(handle);
}
static BOOL WINAPI fixture_set(HANDLE handle, FILE_INFO_BY_HANDLE_CLASS type, LPVOID info, DWORD size) {
    return SetFileInformationByHandle(handle, type, info, size);
}
static FARPROC WINAPI fixture_proc(HMODULE module, LPCSTR name) {
    if (reinterpret_cast<ULONG_PTR>(name) > 65535 && std::string(name) == "NtSetInformationFile") {
        return reinterpret_cast<FARPROC>(&fixture_rename);
    }
    if (reinterpret_cast<ULONG_PTR>(name) > 65535 && std::string(name) == "NtCreateFile") {
        return reinterpret_cast<FARPROC>(&fixture_open);
    }
    return GetProcAddress(module, name);
}
static NTSTATUS NTAPI fixture_open(PHANDLE file, ACCESS_MASK access, POBJECT_ATTRIBUTES attributes,
    PIO_STATUS_BLOCK result, PLARGE_INTEGER allocation, ULONG file_attributes, ULONG share,
    ULONG disposition, ULONG options, PVOID ea, ULONG ea_size) {
    using Open = NTSTATUS (NTAPI*)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
        PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
    const auto native = reinterpret_cast<Open>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile"));
    if (before_create && disposition >= 2 &&
        std::wstring(attributes->ObjectName->Buffer, attributes->ObjectName->Length / sizeof(wchar_t)) == L"new-step") {
        auto action = std::move(before_create);
        before_create = {};
        action();
    }
    const auto status = native(file, access, attributes, result, allocation, file_attributes, share,
                               disposition, options, ea, ea_size);
    if (status >= 0 && disposition == 2) {
        char path[32768];
        const auto count = GetFinalPathNameByHandleA(*file, path, sizeof(path), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (count && count < sizeof(path)) created_temp = local_tools::strip_extended_prefix(std::string(path, count));
    }
    return status;
}
static NTSTATUS NTAPI fixture_rename(HANDLE file, PIO_STATUS_BLOCK result, PVOID info,
                                     ULONG size, FILE_INFORMATION_CLASS type) {
    if (static_cast<int>(type) == 10) {
        if (before_replace) {
            auto action = std::move(before_replace);
            before_replace = {};
            action();
        }
        char path[32768];
        const auto count = GetFinalPathNameByHandleA(file, path, sizeof(path), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (count && count < sizeof(path) && before_move &&
            local_tools::strip_extended_prefix(std::string(path, count)) == move_target) {
            auto action = std::move(before_move);
            before_move = {};
            action();
        }
        if (fail_replace) {
            fail_replace = false;
            return static_cast<NTSTATUS>(0xC0000022L);
        }
    }
    using Rename = NTSTATUS (NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, FILE_INFORMATION_CLASS);
    const auto native = reinterpret_cast<Rename>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetInformationFile"));
    return native(file, result, info, size, type);
}
static BOOL WINAPI fixture_move(LPCSTR source, LPCSTR dest) {
    if (before_move && source == move_target) {
        auto action = std::move(before_move);
        before_move = {};
        action();
    }
    return MoveFileA(source, dest);
}
static void mkdir_owned(const std::string& path) {
    check(CreateDirectoryA(path.c_str(), nullptr) != FALSE, "Cannot create fixture " + path);
}
static void put(const std::string& path, const std::string& text) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, 0, nullptr);
    check(h != INVALID_HANDLE_VALUE, "Cannot create fixture file " + path);
    DWORD n = 0;
    const bool success = WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &n, nullptr) &&
                         n == text.size();
    CloseHandle(h);
    check(success, "Cannot write fixture");
}
static std::string get(const std::string& path) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, 0, nullptr);
    check(h != INVALID_HANDLE_VALUE, "Cannot read fixture " + path);
    char bytes[4096];
    DWORD n = 0;
    const bool success = ReadFile(h, bytes, sizeof(bytes), &n, nullptr) != FALSE;
    CloseHandle(h);
    check(success, "Fixture read failed");
    return std::string(bytes, n);
}
static void set_junction(const std::string& path, const std::string& target) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    check(h != INVALID_HANDLE_VALUE, "Cannot open owned junction");
    const std::wstring substitute = L"\\??\\" + std::wstring(target.begin(), target.end());
    const std::wstring print(target.begin(), target.end());
    struct Mount {
        DWORD tag;
        WORD length, reserved, substitute_offset, substitute_length, print_offset, print_length;
        wchar_t names[2048];
    } data{};
    data.tag = IO_REPARSE_TAG_MOUNT_POINT;
    data.substitute_length = static_cast<WORD>(substitute.size() * sizeof(wchar_t));
    data.print_offset = data.substitute_length + sizeof(wchar_t);
    data.print_length = static_cast<WORD>(print.size() * sizeof(wchar_t));
    memcpy(data.names, substitute.c_str(), data.substitute_length + sizeof(wchar_t));
    memcpy(reinterpret_cast<char*>(data.names) + data.print_offset,
           print.c_str(), data.print_length + sizeof(wchar_t));
    data.length = static_cast<WORD>(8 + data.print_offset + data.print_length + sizeof(wchar_t));
    DWORD returned = 0;
    const BOOL result = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, &data, data.length + 8,
                                       nullptr, 0, &returned, nullptr);
    const DWORD error = GetLastError();
    CloseHandle(h);
    check(result != FALSE, "Owned junction setup failed err=" + std::to_string(error));
}
static void junction(const std::string& path, const std::string& target) {
    mkdir_owned(path);
    set_junction(path, target);
}
static void clear_junction(const std::string& path) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    check(h != INVALID_HANDLE_VALUE, "Cannot reopen owned junction for restoration");
    struct { DWORD tag; WORD length, reserved; } tag{IO_REPARSE_TAG_MOUNT_POINT, 0, 0};
    DWORD count = 0;
    const auto ok = DeviceIoControl(h, FSCTL_DELETE_REPARSE_POINT, &tag, sizeof(tag), nullptr, 0, &count, nullptr);
    CloseHandle(h);
    check(ok != FALSE, "Cannot restore owned junction fixture");
}
static void remove_owned_tree(const std::string& dir) {
    WIN32_FIND_DATAA data{};
    HANDLE h = FindFirstFileA((dir + "\\*").c_str(), &data);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            const std::string name = data.cFileName;
            if (name == "." || name == "..") continue;
            const std::string path = dir + "\\" + name;
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) RemoveDirectoryA(path.c_str());
                else remove_owned_tree(path);
            } else DeleteFileA(path.c_str());
        } while (FindNextFileA(h, &data));
        FindClose(h);
    }
    RemoveDirectoryA(dir.c_str());
}
struct Fixture {
    std::string root, allowed, outside;
    std::vector<std::pair<std::string, std::string>> environment;
    Fixture() {
        const auto evidence = local_tools::repo_root() + "\\logs\\tool-path-hardening-20261106";
        CreateDirectoryA(evidence.c_str(), nullptr);
        root = evidence + "\\fixture-" + std::to_string(GetCurrentProcessId());
        mkdir_owned(root);
        allowed = root + "\\allowed"; outside = root + "\\outside";
        mkdir_owned(allowed); mkdir_owned(outside);
        for (const char* key : {"USERPROFILE", "APPDATA", "LOCALAPPDATA", "ProgramData",
                                "ProgramFiles", "ProgramFiles(x86)"}) {
            environment.push_back({key, local_tools::env_path(key)});
            SetEnvironmentVariableA(key, allowed.c_str());
        }
    }
    ~Fixture() {
        after_resolve = {}; after_close = {}; after_entry = {}; before_replace = {}; before_move = {}; before_create = {};
        fail_write = fail_flush = fail_replace = short_write = false;
        for (const auto& entry : environment) {
            SetEnvironmentVariableA(entry.first.c_str(), entry.second.empty() ? nullptr : entry.second.c_str());
        }
        remove_owned_tree(root);
    }
};
static std::string call(const std::string& name, const std::string& path,
                         const std::string& body = "", const std::string& args = "",
                         const std::string& old = "", const std::string& dest = "") {
    local_tools::Call c;
    c.name = name; c.path = path; c.content = body; c.args = args; c.old_text = old; c.dest = dest;
    return local_tools::execute_calls({c});
}
static void expect_contains(const std::string& text, const std::string& needle) {
    check(text.find(needle) != std::string::npos, "Expected '" + needle + "' in " + text);
}
int main(int argc, char**) {
    try {
        Fixture f;
        int failures = 0;
        const auto regression = [&](bool pass, const char* message) {
            std::cout << (pass ? "PASS " : "FAIL ") << message << "\n";
            if (!pass) ++failures;
        };
        mkdir_owned(f.allowed + "\\swap");
        put(f.allowed + "\\swap\\value.txt", "INSIDE-SENTINEL");
        put(f.outside + "\\value.txt", "OUTSIDE-SENTINEL");
        resolve_target = f.allowed + "\\swap\\value.txt";
        bool substituted = false;
        after_resolve = [&] {
            check(MoveFileA((f.allowed + "\\swap").c_str(), (f.allowed + "\\saved").c_str()),
                  "Controlled substitution did not occur");
            junction(f.allowed + "\\swap", f.outside);
            substituted = true;
        };
        const auto swapped = call("read_local_file", resolve_target);
        regression(substituted && swapped.find("OUTSIDE-SENTINEL") == std::string::npos,
                   "junction substitution between authorization and use cannot disclose outside bytes");
        const auto hard_target = f.allowed + "\\hard.txt";
        put(hard_target, "before");
        put(f.outside + "\\hard-sentinel.txt", "UNCHANGED-HARDLINK-SENTINEL");
        check(CreateHardLinkA((hard_target + ".gb-tmp").c_str(),
                             (f.outside + "\\hard-sentinel.txt").c_str(), nullptr),
              "Cannot create disposable hard link fixture");
        expect_contains(call("write_local_file", hard_target, "after"), "write_local_file ok");
        regression(get(f.outside + "\\hard-sentinel.txt") == "UNCHANGED-HARDLINK-SENTINEL",
                   "preexisting predictable .gb-tmp hard link cannot corrupt its sentinel");
        mkdir_owned(f.allowed + "\\tree");
        mkdir_owned(f.allowed + "\\tree\\child");
        put(f.allowed + "\\tree\\child\\inside.txt", "needle");
        put(f.outside + "\\outside-leak.txt", "needle");
        entry_target = "child";
        bool traversed_swap = false;
        after_entry = [&] {
            traversed_swap = true;
            if (!MoveFileA((f.allowed + "\\tree\\child").c_str(),
                           (f.allowed + "\\tree\\saved-child").c_str())) {
                check(GetLastError() == ERROR_SHARING_VIOLATION || GetLastError() == ERROR_ACCESS_DENIED,
                      "Unexpected traversal fixture substitution failure");
                return;
            }
            junction(f.allowed + "\\tree\\child", f.outside);
        };
        const auto listed = call("list_local_dir", f.allowed + "\\tree", "", "depth=3");
        regression(traversed_swap && listed.find("outside-leak.txt") == std::string::npos,
                   "enumeration metadata cannot authorize a substituted junction child");
        if (argc > 1) return failures ? 1 : 0;
        check(failures == 0, "Exploit regressions failed");

        const auto creation_parent = f.allowed + "\\creation-race";
        mkdir_owned(creation_parent);
        bool converted = false;
        before_create = [&] {
            set_junction(creation_parent, f.outside);
            converted = true;
        };
        const auto creation_result = call("write_local_file", creation_parent + "\\new-step\\safe.txt", "owned bytes");
        check(converted && GetFileAttributesA((f.outside + "\\new-step").c_str()) == INVALID_FILE_ATTRIBUTES,
              "Handle-relative creation followed an in-place parent reparse change: " + creation_result);
        clear_junction(creation_parent);
        std::cout << "PASS in-place empty-parent reparse cannot redirect directory or file creation\n";

        const auto ordinary = f.allowed + "\\new\\nested\\text.txt";
        expect_contains(call("write_local_file", ordinary, "alpha\nbeta\n"), "write_local_file ok");
        expect_contains(call("write_local_file", ordinary, "tail\n", "append"), " append ");
        expect_contains(call("edit_local_file", ordinary, "BETA", "", "beta"), "replacements=1");
        expect_contains(call("read_local_file", ordinary, "", "offset=1 limit=1"), "\nBETA\n");
        expect_contains(call("read_local_file", ordinary, "", "offset=-1"), "\ntail\n");
        expect_contains(call("get_file_info", ordinary), "file bytes=16");
        expect_contains(call("create_local_dir", f.allowed + "\\created\\deep"), "create_local_dir ok");
        const auto moved = f.allowed + "\\moved\\text.txt";
        expect_contains(call("move_local_file", ordinary, "", "", "", moved), "move_local_file ok");
        check(get(moved) == "alpha\nBETA\ntail\n", "Ordinary move changed bytes");
        junction(f.allowed + "\\alias", f.allowed + "\\moved");
        expect_contains(call("read_local_file", f.allowed + "\\alias\\text.txt"), "BETA");
        expect_contains(call("write_local_file", f.allowed + "\\alias\\text.txt", "linked\n"), "write_local_file ok");
        check(get(moved) == "linked\n", "Permitted in-jail reparse write changed behavior");
        const auto searched = call("search_local", f.allowed + "\\tree", "", "content:needle");
        check(searched.find("outside-leak.txt") == std::string::npos, "Content traversal escaped via reparse");
        expect_contains(searched, "inside.txt");
        expect_contains(call("repo_map", f.allowed + "\\moved"), "Repo map");
        const std::string utf16("\xff\xfe" "a\0\r\0\n\0b\0", 10);
        put(f.allowed + "\\utf16.txt", utf16);
        expect_contains(call("read_local_file", f.allowed + "\\utf16.txt", "", "offset=1 limit=1"), "\nb\n");
        put(f.allowed + "\\binary.dat", std::string("a\0b", 3));
        expect_contains(call("read_local_file", f.allowed + "\\binary.dat"), "binary");
        std::cout << "PASS ordinary read/write/append/edit/hash/slice/info/create/move, in-jail junction and safe traversal\n";

        bool parent_pinned = false;
        before_replace = [&] {
            parent_pinned = !MoveFileA((f.allowed + "\\moved").c_str(),
                                      (f.allowed + "\\renamed").c_str());
            HANDLE writer = CreateFileA((f.allowed + "\\moved").c_str(), GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (writer != INVALID_HANDLE_VALUE) CloseHandle(writer);
        };
        short_write = true;
        expect_contains(call("write_local_file", moved, "stable"), "write_local_file ok");
        check(get(moved) == "stable", "Short native writes lost bytes");
        check(parent_pinned, "Resolved destination ancestor was replaceable during atomic replacement");
        check(!created_temp.empty() && GetFileAttributesA(created_temp.c_str()) == INVALID_FILE_ATTRIBUTES,
              "Successful replacement left a staging file");
        for (int failure = 0; failure < 3; ++failure) {
            fail_write = failure == 0; fail_flush = failure == 1; fail_replace = failure == 2;
            expect_contains(call("write_local_file", moved, "must-not-commit"), "cannot write");
            check(get(moved) == "stable", "Failed commit changed destination");
            check(GetFileAttributesA(created_temp.c_str()) == INVALID_FILE_ATTRIBUTES,
                  "Failed commit did not clean up its owned staging object");
            check(get(f.outside + "\\hard-sentinel.txt") == "UNCHANGED-HARDLINK-SENTINEL",
                  "Failure cleanup touched an unowned object");
        }
        mkdir_owned(f.allowed + "\\move-target");
        move_target = moved;
        bool move_pinned = false;
        before_move = [&] {
            const bool source_pinned = !MoveFileA((f.allowed + "\\moved").c_str(),
                                                  (f.allowed + "\\source-renamed").c_str());
            const bool dest_pinned = !MoveFileA((f.allowed + "\\move-target").c_str(),
                                                (f.allowed + "\\target-renamed").c_str());
            move_pinned = source_pinned && dest_pinned;
        };
        expect_contains(call("move_local_file", moved, "", "", "",
                             f.allowed + "\\move-target\\text.txt"), "move_local_file ok");
        check(move_pinned, "Move did not retain both source and target ancestor leases");
        std::cout << "PASS pinned replacement, write/flush/rename failure and owned-temp-only cleanup\n";

        put(f.allowed + "\\test.ps1", "Write-Output 'PWSH-PATH-OK'\n");
        expect_contains(call("run_pwsh", f.allowed + "\\test.ps1"), "PWSH-PATH-OK");
        put(f.allowed + "\\test.py", "print('PYTHON-PATH-OK')\n");
        expect_contains(call("run_python", f.allowed + "\\test.py"), "PYTHON-PATH-OK");
        put(f.allowed + "\\test.js", "console.log('NODE-PATH-OK');\n");
        expect_contains(call("run_node", f.allowed + "\\test.js"), "NODE-PATH-OK");
        check(!local_tools::yolo_active(), "Baseline interpreter tests enabled YOLO");
        mkdir_owned(f.allowed + "\\script-swap");
        put(f.allowed + "\\script-swap\\test.ps1", "Write-Output 'INSIDE-SCRIPT'\n");
        put(f.outside + "\\test.ps1", "Write-Output 'OUTSIDE-SCRIPT'\n");
        resolve_target = f.allowed + "\\script-swap\\test.ps1";
        after_resolve = [&] {
            check(MoveFileA((f.allowed + "\\script-swap").c_str(),
                            (f.allowed + "\\saved-script").c_str()), "Cannot swap owned script ancestor");
            junction(f.allowed + "\\script-swap", f.outside);
        };
        const auto script = call("run_pwsh", resolve_target);
        check(!after_resolve && script.find("OUTSIDE-SCRIPT") == std::string::npos,
              "Script-by-path reopened a substituted outside object");
        std::cout << "PASS baseline PowerShell/Python/Node scripts and script junction substitution\n";
        std::cout << "local_path_test ok\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << "\n";
        return 1;
    }
}
