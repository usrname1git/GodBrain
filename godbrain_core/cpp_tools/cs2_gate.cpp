#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// 1-minute CS2 gate. WINDOWS subsystem: no console, no WT flash.
// Idle path is this exe only. pwsh runs only if CS2.exe is up or
// logs/cs2-pause.json says paused=true (resume window).

static bool process_named(const wchar_t* exe) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    bool hit = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, exe) == 0) {
                hit = true;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return hit;
}

static bool file_says_paused(const char* path) {
    HANDLE hf = CreateFileA(
        path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hf == INVALID_HANDLE_VALUE) return false;
    char buf[2048];
    DWORD n = 0;
    const BOOL ok = ReadFile(hf, buf, sizeof(buf) - 1, &n, nullptr);
    CloseHandle(hf);
    if (!ok) return false;
    buf[n] = 0;
    return strstr(buf, "\"paused\":  true") != nullptr ||
           strstr(buf, "\"paused\":true") != nullptr ||
           strstr(buf, "\"paused\": true") != nullptr;
}

static bool start_watch(const char* hidden, const char* cmdline) {
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    char mutable_cmd[1024];
    if (strcpy_s(mutable_cmd, cmdline) != 0) return false;
    const BOOL ok = CreateProcessA(
        hidden, mutable_cmd, nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    if (ok) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    return ok != 0;
}

int main() {
    char self[MAX_PATH];
    DWORD n = GetModuleFileNameA(nullptr, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    char* slash = strrchr(self, '\\');
    if (!slash) return 1;
    *slash = 0;
    // ...\godbrain_core\cpp_tools
    char raw[MAX_PATH];
    char repo[MAX_PATH];
    if (sprintf_s(raw, "%s\\..\\..", self) < 0) return 1;
    if (GetFullPathNameA(raw, MAX_PATH, repo, nullptr) == 0) return 1;
    char hidden[MAX_PATH];
    char watch[MAX_PATH];
    char state[MAX_PATH];
    sprintf_s(hidden, "%s\\run_hidden.exe", self);
    sprintf_s(watch, "%s\\Watch-Cs2Pause.ps1", repo);
    sprintf_s(state, "%s\\logs\\cs2-pause.json", repo);

    const bool need =
        process_named(L"CS2.exe") || process_named(L"cs2.exe") ||
        file_says_paused(state);
    if (!need) return 0;

    const char* shell = "C:\\pwsh\\pwsh.exe";
    if (GetFileAttributesA(shell) == INVALID_FILE_ATTRIBUTES) {
        shell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    }
    char cmdline[1024];
    sprintf_s(
        cmdline,
        "\"%s\" \"%s\" -NoProfile -WindowStyle Hidden -NonInteractive "
        "-File \"%s\" -RepoRoot \"%s\"",
        hidden, shell, watch, repo);
    if (!start_watch(hidden, cmdline)) return 4;
    return 0;
}
