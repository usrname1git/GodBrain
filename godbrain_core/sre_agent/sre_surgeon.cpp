#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <cstdlib>
#include <thread>
#include <mutex>
#include <sstream>
#include <cstdio>

// Ceiling on a single Colibri invocation, matching the C++ kernel router's
// timeout so both native launch sites behave the same way.
static const DWORD COLIBRI_TIMEOUT_MS = 180000;

static std::string get_exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

static bool path_exists(const std::string& p) {
    if (p.empty()) return false;
    return GetFileAttributesA(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}

static std::string resolve_colibri_path() {
    const char* env = std::getenv("GODBRAIN_COLIBRI_PATH");
    if (env && *env) return std::string(env);

    static const char* candidates[] = {
        "\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\..\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\LLM\\colibri_LLM\\c\\colibri.exe",
    };
    std::string exe_dir = get_exe_dir();
    for (const char* rel : candidates) {
        if (!exe_dir.empty()) {
            std::string cand = exe_dir + rel;
            if (path_exists(cand)) return cand;
        }
    }
    std::string fallback = "..\\..\\LLM\\colibri_LLM\\c\\colibri.exe";
    if (path_exists(fallback)) return fallback;
    std::cerr << "[SRE] WARNING: could not locate colibri.exe via GODBRAIN_COLIBRI_PATH or repo-relative defaults; "
                 "using best-effort path '" << fallback << "'." << std::endl;
    return fallback;
}

std::string exec_cmd(const std::string& cmd) {
    char buffer[512];
    std::string result;
    FILE* pipe = _popen(cmd.c_str(), "r");
    if (!pipe) return "[exec error]";
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        result += buffer;
        if (result.size() > 4000) break;
    }
    _pclose(pipe);
    return result;
}

std::string run_colibri_sre(const std::string& prompt) {
    SECURITY_ATTRIBUTES saAttr;
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = TRUE;
    saAttr.lpSecurityDescriptor = NULL;

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;
    CreatePipe(&hOutRd, &hOutWr, &saAttr, 0);
    CreatePipe(&hInRd, &hInWr, &saAttr, 0);
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdError = hOutWr;
    si.hStdOutput = hOutWr;
    si.hStdInput = hInRd;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    std::string cmd = "\"" + resolve_colibri_path() + "\" 64 8 8";

    const char* snap_env = std::getenv("GODBRAIN_SNAPSHOT_PATH");
    SetEnvironmentVariableA("SNAP", (snap_env && *snap_env) ? snap_env : "C:\\nvme\\glm52-uncensored");
    SetEnvironmentVariableA("NGEN", "2048");
    SetEnvironmentVariableA("COLI_RAM_OVERCOMMIT", "0");
    SetEnvironmentVariableA("COLI_CUDA", "1");
    SetEnvironmentVariableA("CUDA_EXPERT_GB", "12");
    SetEnvironmentVariableA("COLI_API", "1");
    SetEnvironmentVariableA("COLI_PROMPT", prompt.c_str());

    std::vector<char> cmd_buf(cmd.begin(), cmd.end());
    cmd_buf.push_back('\0');

    BOOL success = CreateProcessA(NULL, cmd_buf.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInWr);
    CloseHandle(hInRd);

    if (!success) {
        CloseHandle(hOutRd);
        return "Error: Failed to spawn Colibri C-Engine natively.";
    }

    std::string output;
    std::mutex output_mutex;
    std::thread reader([&]() {
        DWORD read;
        CHAR buf[4096];
        while (ReadFile(hOutRd, buf, sizeof(buf) - 1, &read, NULL) && read > 0) {
            buf[read] = '\0';
            std::cout << buf;
            std::lock_guard<std::mutex> lock(output_mutex);
            output.append(buf, read);
        }
    });

    bool timed_out = false;
    bool marker_found = false;
    const DWORD poll_interval_ms = 100;
    DWORD waited_ms = 0;
    for (;;) {
        {
            std::lock_guard<std::mutex> lock(output_mutex);
            if (output.find("PROFILO") != std::string::npos || output.find("PROFILE:") != std::string::npos) {
                marker_found = true;
            }
        }
        if (marker_found) break;

        DWORD exitCode;
        if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != STILL_ACTIVE) {
            break;
        }

        if (waited_ms >= COLIBRI_TIMEOUT_MS) {
            timed_out = true;
            break;
        }
        Sleep(poll_interval_ms);
        waited_ms += poll_interval_ms;
    }

    TerminateProcess(pi.hProcess, 0);
    WaitForSingleObject(pi.hProcess, 5000);
    reader.join();

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    if (timed_out) {
        return "Error: Colibri C-Engine timed out after 180s and was terminated.";
    }

    std::string final_answer = output;
    size_t ans_idx = output.rfind("Answer:");
    if (ans_idx != std::string::npos) {
        final_answer = output.substr(ans_idx + 7);
        size_t end_idx = final_answer.find("PROFILE");
        if (end_idx == std::string::npos) end_idx = final_answer.find("PROFILO");
        if (end_idx != std::string::npos) {
            final_answer = final_answer.substr(0, end_idx);
        }
    }

    final_answer.erase(0, final_answer.find_first_not_of(" \n\r\t"));
    final_answer.erase(final_answer.find_last_not_of(" \n\r\t") + 1);
    return final_answer;
}

enum Gate { GateDiagnose, GateHeal, GateGo };

struct SreTool {
    const char* id;
    const char* path;     // empty = Windows builtin
    const char* invoke;
    const char* purpose;
    Gate gate;
};

static const SreTool kToolkit[] = {
    {"ping", "", "ping -n 1 -w 800 <host>",
     "ICMP reachability. First step.", GateDiagnose},
    {"nslookup", "", "nslookup <name>",
     "DNS resolve via configured servers. First step.", GateDiagnose},
    {"tracert", "", "tracert -d -h 15 <host>",
     "Path after ping/nslookup. First step.", GateDiagnose},
    {"ipconfig-all", "", "ipconfig /all",
     "NIC, DHCP, DNS servers, MAC.", GateDiagnose},
    {"net-adapter", "",
     "Get-NetAdapter -IncludeHidden; Get-NetAdapterBinding -ComponentID ms_tcpip",
     "Present vs Not Present, Tcpip bind.", GateDiagnose},
    {"net-ip", "",
     "Get-NetIPConfiguration; Get-DnsClientServerAddress; Get-NetRoute -AddressFamily IPv4",
     "Address, DNS servers, routes.", GateDiagnose},
    {"netstat", "", "netstat -ano",
     "Local sockets and owning PID.", GateDiagnose},
    {"sc-query", "", "sc.exe query MongoDB & Dnscache & iphlpsvc & nsi",
     "Heal allowlist services.", GateDiagnose},
    {"wevtutil", "", "wevtutil qe System /c:8 /rd:true /f:text /q:*[System[(Level=2 or Level=3)]]",
     "Recent System errors/warnings.", GateDiagnose},
    {"arp", "", "arp -a",
     "Neighbor cache after L3 fail.", GateDiagnose},
    {"route", "", "route print",
     "IPv4/IPv6 route table.", GateDiagnose},
    {"netsh-show", "",
     "netsh interface ipv4 show interfaces; netsh interface ipv4 show config",
     "Interface list and IPv4 config. Show only.", GateDiagnose},
    {"psping", "C:\\Tools\\SysInternals\\psping64.exe",
     "psping64 -? i|t|l|b ; psping64 -n 4 host  or host:port",
     "ICMP or TCP connect, latency, bandwidth.", GateDiagnose},
    {"tcpvcon", "C:\\Tools\\SysInternals\\tcpvcon64.exe",
     "tcpvcon64 -a -n",
     "Process that owns each TCP/UDP endpoint.", GateDiagnose},
    {"tcpview", "C:\\Tools\\SysInternals\\tcpview64.exe",
     "tcpview64",
     "GUI for the same sockets.", GateDiagnose},
    {"whois", "C:\\Tools\\SysInternals\\whois64.exe",
     "whois64 <name-or-ip>",
     "Who owns the name or IP.", GateDiagnose},
    {"procmon", "C:\\Tools\\SysInternals\\Procmon64.exe",
     "procmon64 with Network filter",
     "Deeper only: who is talking.", GateDiagnose},
    {"shareenum", "C:\\Tools\\SysInternals\\ShareEnum64.exe",
     "shareenum64",
     "SMB shares in reach.", GateDiagnose},
    {"psfile", "C:\\Tools\\SysInternals\\psfile64.exe",
     "psfile64",
     "Files opened remotely on this box.", GateDiagnose},
    {"handle", "C:\\Tools\\SysInternals\\handle64.exe",
     "handle64",
     "Who holds a file or section.", GateDiagnose},
    {"procexp", "C:\\Tools\\SysInternals\\procexp64.exe",
     "procexp64",
     "Process tree, handles, GPU.", GateDiagnose},
    {"heal", "",
     "Heal-GodBrain.ps1 / Watch-GodBrain.ps1 / Galaxy /heal",
     "Start allowlist + icmp/dns_self/nic_tcpip. flushdns once after DNS miss.",
     GateHeal},
    {"flushdns", "", "ipconfig /flushdns",
     "Heal may run once after dns_self fail + Dnscache + icmp.", GateHeal},
    {"registerdns", "", "ipconfig /registerdns",
     "Re-register this host in DNS. Needs GO.", GateGo},
    {"release-renew", "", "ipconfig /release && ipconfig /renew",
     "Drops the address. Needs GO.", GateGo},
    {"winsock-reset", "", "netsh winsock reset",
     "Rebuilds Winsock catalog. Needs GO + reboot.", GateGo},
    {"ip-reset", "", "netsh int ip reset",
     "Rewrites the TCP/IP stack. Needs GO + reboot.", GateGo},
    {"devicecleanup", "C:\\Tools\\DeviceCleanupCmd\\DeviceCleanupCmd.exe",
     "DeviceCleanupCmd <pattern> -t -n   then without -t after GO",
     "Non-present PnP. * is hygiene, SRP first. Needs GO.", GateGo},
    {"reboot", "", "shutdown /r /t 0",
     "Clean reboot after a GO'd stack rewrite. Needs GO.", GateGo},
};

static const char* gate_name(Gate g) {
    switch (g) {
        case GateDiagnose: return "diagnose";
        case GateHeal: return "heal";
        case GateGo: return "go";
    }
    return "?";
}

static void print_usage() {
    std::cout
        << "Usage:\n"
        << "  sre_surgeon --toolkit              list the SRE kit (present/missing, gate)\n"
        << "  sre_surgeon --diagnose [issue]     read-only probes, no repairs\n"
        << "  sre_surgeon --ask \"issue\"          cold-spawn Colibri (steals the GPU slot)\n"
        << "\n"
        << "Diagnose first: ping, nslookup, tracert, then NIC-Tcpip binding.\n"
        << "Heal may flushdns after a real DNS miss. release / winsock / ip reset /\n"
        << "DeviceCleanup / reboot need an explicit operator GO, one named tool.\n";
}

static int print_toolkit() {
    std::cout << "SRE toolkit  host=" << (std::getenv("COMPUTERNAME") ? std::getenv("COMPUTERNAME") : "?")
              << "\n gate=diagnose (always)  heal (unattended allowlist)  go (operator in chat)\n\n";
    std::cout << "id                 gate      have  invoke\n";
    int missing = 0;
    for (const SreTool& tool : kToolkit) {
        const bool builtin = tool.path == nullptr || tool.path[0] == '\0';
        const bool have = builtin || path_exists(tool.path);
        if (!have) ++missing;
        char id[20];
        std::snprintf(id, sizeof(id), "%-18s", tool.id);
        std::cout << id << " " << gate_name(tool.gate);
        std::cout << std::string(10 - std::string(gate_name(tool.gate)).size(), ' ');
        std::cout << (have ? "yes " : "NO  ") << " " << tool.invoke << "\n";
        std::cout << "                     " << tool.purpose << "\n";
        if (!builtin) {
            std::cout << "                     " << tool.path << "\n";
        }
    }
    std::cout << "\nSysInternals=C:\\Tools\\SysInternals  DeviceCleanup=C:\\Tools\\DeviceCleanupCmd\n";
    if (missing) {
        std::cout << "missing binaries=" << missing << "\n";
    }
    return missing == 0 ? 0 : 2;
}

static void print_block(const char* title, const std::string& body) {
    std::cout << "---- " << title << " ----\n";
    if (body.empty()) {
        std::cout << "(empty)\n";
    } else {
        std::cout << body;
        if (body.back() != '\n') std::cout << "\n";
    }
}

static int run_diagnose(const std::string& issue) {
    std::cout << "[SRE] diagnose-only. No release/winsock/ip reset/DeviceCleanup/reboot.\n";
    if (!issue.empty()) {
        std::cout << "[SRE] issue: " << issue << "\n";
    }

    print_block("ping 127.0.0.1",
                exec_cmd("ping -n 1 -w 800 127.0.0.1"));
    const std::string ping_up = exec_cmd("ping -n 1 -w 800 1.1.1.1");
    print_block("ping 1.1.1.1", ping_up);
    print_block("nslookup localhost", exec_cmd("nslookup localhost"));
    print_block("dns_self",
                exec_cmd("powershell.exe -NoProfile -NonInteractive -Command "
                         "\"try { [Net.Dns]::GetHostEntry('localhost') | Out-Null; "
                         "[Net.Dns]::GetHostEntry($env:COMPUTERNAME) | Out-Null; "
                         "'ok '+$env:COMPUTERNAME } catch { 'FAIL '+$_.Exception.Message }\""));
    const bool uplink_ok =
        ping_up.find("TTL=") != std::string::npos ||
        ping_up.find("ttl=") != std::string::npos;
    if (!uplink_ok) {
        print_block("tracert 1.1.1.1",
                    exec_cmd("tracert -d -h 8 -w 800 1.1.1.1"));
    } else {
        print_block("tracert", "skipped (uplink ping ok)");
    }
    print_block("nic_tcpip",
                exec_cmd("powershell.exe -NoProfile -NonInteractive -Command "
                         "\"Get-NetAdapter -Physical | "
                         "Select-Object Name,Status,InterfaceDescription,MacAddress,InterfaceGuid | "
                         "Format-Table -AutoSize | Out-String -Width 200; "
                         "Get-NetAdapterBinding -ComponentID ms_tcpip | "
                         "Where-Object { $_.Name -notmatch 'Local Area Connection' } | "
                         "Select-Object Name,Enabled | Format-Table -AutoSize | Out-String -Width 120\""));
    print_block("sc MongoDB", exec_cmd("sc.exe query MongoDB"));
    print_block("sc Dnscache", exec_cmd("sc.exe query Dnscache"));
    print_block("sc iphlpsvc", exec_cmd("sc.exe query iphlpsvc"));
    print_block("sc nsi", exec_cmd("sc.exe query nsi"));

    if (path_exists("C:\\Tools\\SysInternals\\tcpvcon64.exe")) {
        print_block("tcpvcon64 -a -n",
                    exec_cmd("C:\\Tools\\SysInternals\\tcpvcon64.exe -accepteula -nobanner -a -n"));
    } else {
        print_block("tcpvcon64", "missing C:\\Tools\\SysInternals\\tcpvcon64.exe");
    }

    std::string sys_logs = exec_cmd(
        "wevtutil qe System /c:5 /rd:true /f:text /q:\"*[System[(Level=2 or Level=3)]]\"");
    if (sys_logs.size() > 1500) sys_logs.resize(1500);
    print_block("wevtutil System L2/L3", sys_logs);

    std::cout << "[SRE] next: if dns_self failed, Heal flushdns is allowlisted. "
                 "Anything else needs GO.\n";
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage();
        return 1;
    }

    const std::string a1 = argv[1];
    if (a1 == "-h" || a1 == "--help") {
        print_usage();
        return 0;
    }
    if (a1 == "--toolkit") {
        return print_toolkit();
    }
    if (a1 == "--diagnose") {
        std::string issue;
        for (int i = 2; i < argc; ++i) {
            if (!issue.empty()) issue += " ";
            issue += argv[i];
        }
        return run_diagnose(issue);
    }
    if (a1 == "--ask") {
        if (argc < 3) {
            std::cout << "[ERR] --ask needs an issue string\n";
            return 1;
        }
        std::cout << "[SRE] --ask cold-spawns Colibri and steals the GPU slot. "
                     "Prefer Galaxy + coli serve. Continuing because you asked.\n";
        std::string issue = argv[2];
        std::string sys_logs = exec_cmd(
            "wevtutil qe System /c:3 /rd:true /f:text /q:\"*[System[(Level=2 or Level=3)]]\"");
        if (sys_logs.size() > 1000) sys_logs.resize(1000);
        std::string prompt =
            "You are GodBrain, the Windows SRE. Diagnose first (ping, nslookup, "
            "tracert, NIC-Tcpip binding). Heal may flushdns after a DNS miss. "
            "release, winsock reset, int ip reset, DeviceCleanup, reboot need "
            "operator GO. Do not emit those unless the issue clearly needs them, "
            "and label them GO. User issue: " +
            issue + "\n\nRecent System Event Log Errors:\n" + sys_logs + "\n\nAnswer:";
        std::string resolution = run_colibri_sre(prompt);
        std::cout << "\n================ [ SRE ASK ] ================\n";
        std::cout << resolution << "\n";
        std::cout << "============================================\n";
        return 0;
    }

    // Bare issue string: diagnose, do not steal the GPU.
    std::string issue = a1;
    for (int i = 2; i < argc; ++i) {
        issue += " ";
        issue += argv[i];
    }
    return run_diagnose(issue);
}
