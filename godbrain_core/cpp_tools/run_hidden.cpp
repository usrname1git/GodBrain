#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

// Launch a child with CREATE_NO_WINDOW so Windows Terminal cannot flash.
// Usage: run_hidden.exe <exe> [args...]
// Refuse .cmd/.bat/.vbs: those go through cmd/wscript and flash WT.
static bool is_console_script(const wchar_t* path) {
    const wchar_t* dot = wcsrchr(path, L'.');
    if (!dot) return false;
    return _wcsicmp(dot, L".cmd") == 0 || _wcsicmp(dot, L".bat") == 0 ||
           _wcsicmp(dot, L".vbs") == 0 || _wcsicmp(dot, L".js") == 0;
}

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

    wchar_t app[MAX_PATH] = {};
    const wchar_t* p = cmd;
    if (*p == L'"') {
        ++p;
        size_t i = 0;
        while (*p && *p != L'"' && i + 1 < MAX_PATH) app[i++] = *p++;
    } else {
        size_t i = 0;
        while (*p && *p != L' ' && *p != L'\t' && i + 1 < MAX_PATH) app[i++] = *p++;
    }
    if (app[0] == 0 || is_console_script(app)) return 5;

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    wchar_t* mutable_cmd = _wcsdup(cmd);
    if (!mutable_cmd) return 3;
    const BOOL ok = CreateProcessW(
        nullptr, mutable_cmd, nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    free(mutable_cmd);
    if (!ok) return 4;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
