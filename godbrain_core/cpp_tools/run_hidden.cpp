#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

// Launch a child with CREATE_NO_WINDOW so Windows Terminal cannot flash.
// Usage: run_hidden.exe <exe> [args...]
int main() {
    wchar_t* cmd = GetCommandLineW();
    if (!cmd || !*cmd) return 1;
    if (*cmd == L'"') {
        ++cmd;
        while (*cmd && *cmd != L'"') ++cmd;
        if (*cmd == L'"') ++cmd;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') ++cmd;
    }
    while (*cmd == L' ' || *cmd == L'\t') ++cmd;
    if (!*cmd) return 2;

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    wchar_t* mutable_cmd = _wcsdup(cmd);
    if (!mutable_cmd) return 3;
    const BOOL ok = CreateProcessW(
        nullptr, mutable_cmd, nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr, &si, &pi);
    free(mutable_cmd);
    if (!ok) return 4;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
