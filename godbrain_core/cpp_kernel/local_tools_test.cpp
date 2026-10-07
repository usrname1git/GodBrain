#include "local_tools.h"

#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <unordered_set>

#include <windows.h>

#ifndef LOAD_LIBRARY_SEARCH_SYSTEM32
#define LOAD_LIBRARY_SEARCH_SYSTEM32 0x00000800
#endif

static bool expect(bool ok, const char* msg) {
    if (!ok) std::cerr << "FAIL " << msg << std::endl;
    return ok;
}

static std::unordered_set<std::string> schema_names(bool full) {
    std::unordered_set<std::string> names;
    for (const auto& def : local_tools::openai_tool_defs(full)) {
        names.insert(def.at("function").at("name").get<std::string>());
    }
    return names;
}

static unsigned long long file_size_or_zero(const char* path) {
    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &fad)) return 0;
    ULARGE_INTEGER sz;
    sz.LowPart = fad.nFileSizeLow;
    sz.HighPart = fad.nFileSizeHigh;
    return sz.QuadPart;
}

static bool file_absent(const char* path) {
    return GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES;
}

static HMODULE load_winsqlite3() {
    return LoadLibraryExW(L"winsqlite3.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
}

struct SqliteFnProbe {
    bool ready = false;
    bool hex_in_b = false;
    bool hex_in_a = false;
    bool writefile_seen = false;
    bool load_extension_seen = false;
};

static SqliteFnProbe g_fn_probe;

static bool probe_eq(const char* s, const char* lit) {
    return s && std::string(s) == lit;
}

static int __cdecl probe_sqlite_auth(void*, int code, const char* a, const char* b,
                                     const char*, const char*) {
    if (code != 31) return 0;
    if (probe_eq(b, "hex")) g_fn_probe.hex_in_b = true;
    if (probe_eq(a, "hex")) g_fn_probe.hex_in_a = true;
    if (probe_eq(b, "writefile") || probe_eq(a, "writefile")) {
        g_fn_probe.writefile_seen = true;
        return 1;
    }
    if (probe_eq(b, "load_extension") || probe_eq(a, "load_extension")) {
        g_fn_probe.load_extension_seen = true;
        return 1;
    }
    return 0;
}

static SqliteFnProbe probe_sqlite_function_args() {
    g_fn_probe = SqliteFnProbe{};
    const HMODULE mod = load_winsqlite3();
    if (!mod) return g_fn_probe;
    using open_fn = int(__cdecl*)(const char*, void**, int, const char*);
    using exec_fn = int(__cdecl*)(void*, const char*, void*, void*, char**);
    using close_fn = int(__cdecl*)(void*);
    using free_fn = void(__cdecl*)(void*);
    using auth_fn = int(__cdecl*)(
        void*, int(__cdecl*)(void*, int, const char*, const char*, const char*, const char*),
        void*);
    const auto open = reinterpret_cast<open_fn>(GetProcAddress(mod, "sqlite3_open_v2"));
    const auto exec = reinterpret_cast<exec_fn>(GetProcAddress(mod, "sqlite3_exec"));
    const auto close = reinterpret_cast<close_fn>(GetProcAddress(mod, "sqlite3_close"));
    const auto sql_free = reinterpret_cast<free_fn>(GetProcAddress(mod, "sqlite3_free"));
    const auto set_auth = reinterpret_cast<auth_fn>(GetProcAddress(mod, "sqlite3_set_authorizer"));
    if (!open || !exec || !close || !set_auth) return g_fn_probe;
    void* db = nullptr;
    if (open(":memory:", &db, 2 | 4, nullptr) != 0 || !db) return g_fn_probe;
    g_fn_probe.ready = true;
    set_auth(db, probe_sqlite_auth, nullptr);
    auto run = [&](const char* sql) {
        char* err = nullptr;
        exec(db, sql, nullptr, nullptr, &err);
        if (err && sql_free) sql_free(err);
    };
    run("SELECT hex(1);");
    run("SELECT writefile('C:/Temp/GitHub/godbrain-sqlite-writefile.txt','pwned');");
    run("SELECT load_extension('x');");
    close(db);
    return g_fn_probe;
}

static bool write_sqlite_fixture(const char* path) {
    DeleteFileA(path);
    const HMODULE mod = load_winsqlite3();
    if (!mod) return false;
    using open_fn = int(__cdecl*)(const char*, void**, int, const char*);
    using exec_fn = int(__cdecl*)(void*, const char*, void*, void*, char**);
    using close_fn = int(__cdecl*)(void*);
    const auto open =
        reinterpret_cast<open_fn>(GetProcAddress(mod, "sqlite3_open_v2"));
    const auto exec =
        reinterpret_cast<exec_fn>(GetProcAddress(mod, "sqlite3_exec"));
    const auto close =
        reinterpret_cast<close_fn>(GetProcAddress(mod, "sqlite3_close"));
    if (!open || !exec || !close) return false;
    void* db = nullptr;
    if (open(path, &db, 2 | 4, nullptr) != 0 || !db) return false;
    char* err = nullptr;
    const int rc = exec(
        db, "CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('hello-sql');",
        nullptr, nullptr, &err);
    close(db);
    return rc == 0;
}

static std::string env_var(const char* name) {
    char buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableA(name, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return "";
    return std::string(buf, n);
}

int main() {
    bool pass = true;
    std::string err;
    const std::string home = env_var("USERPROFILE");
    const std::string appdata = env_var("APPDATA");
    const std::string local = env_var("LOCALAPPDATA");
    const std::string programdata = env_var("ProgramData");
    const std::string programfiles = env_var("ProgramFiles");
    const std::string programfiles_x86 = env_var("ProgramFiles(x86)");
    pass &= expect(!home.empty(), "USERPROFILE set");
    pass &= expect(!local_tools::path_is_granted("C:\\Windows\\System32\\notepad.exe", &err),
                   "windows denied");
    pass &= expect(!local_tools::path_is_granted(
                       "C:\\Temp\\GitHub\\..\\..\\Windows\\System32\\cmd.exe", &err),
                   "dotdot denied");
    pass &= expect(local_tools::path_is_granted(
                       home + "\\Documents\\GitHub\\GodBrain\\AGENTS.md", &err),
                   "repo granted");
    pass &= expect(local_tools::path_is_granted("C:\\Temp\\GitHub", &err), "temp github granted");
    pass &= expect(local_tools::path_is_granted(home + "\\Desktop", &err),
                   "profile desktop granted");
    pass &= expect(local_tools::path_is_granted("%USERPROFILE%\\Desktop", &err),
                   "env profile desktop granted");
    pass &= expect(!appdata.empty() && local_tools::path_is_granted(appdata, &err),
                   "APPDATA granted");
    pass &= expect(!local.empty() && local_tools::path_is_granted(local, &err),
                   "LOCALAPPDATA granted");
    pass &= expect(local_tools::path_is_granted("C:\\Tools", &err), "Tools granted");
    pass &= expect(local_tools::path_is_granted("C:\\Tools\\SysInternals\\pslist64.exe", &err),
                   "Tools subdir granted");
    pass &= expect(
        !programdata.empty() && local_tools::path_is_granted(programdata, &err),
        "ProgramData granted");
    pass &= expect(!programfiles.empty() &&
                       local_tools::path_is_granted(programfiles, &err),
                   "ProgramFiles granted");
    pass &= expect(!programfiles.empty() &&
                       local_tools::path_is_granted(programfiles + "\\Git", &err),
                   "ProgramFiles subdir granted");
    pass &= expect(programfiles_x86.empty() ||
                       local_tools::path_is_granted(programfiles_x86, &err),
                   "ProgramFiles x86 granted");
    pass &= expect(local_tools::path_is_granted("%ProgramFiles%\\Git", &err),
                   "env ProgramFiles granted");
    CreateDirectoryA("C:\\Temp\\GitHub", nullptr);
    const char kJunc[] = "C:\\Temp\\GitHub\\godbrain-junc-win";
    RemoveDirectoryA(kJunc);
    const std::string mklink = std::string("cmd.exe /c mklink /J \"") + kJunc +
                               "\" \"C:\\Windows\" >nul 2>nul";
    system(mklink.c_str());
    const bool junc_ok =
        (GetFileAttributesA(kJunc) != INVALID_FILE_ATTRIBUTES);
    if (junc_ok) {
        pass &= expect(!local_tools::path_is_granted(
                           std::string(kJunc) + "\\System32\\cmd.exe", &err),
                       "junction to windows denied");
        RemoveDirectoryA(kJunc);
    }

    const std::string sample =
        "*** TOOL\nname: list_local_dir\npath: C:\\Temp\\GitHub\n*** END\n";
    pass &= expect(local_tools::has_tool_block(sample), "has tool");
    auto calls = local_tools::parse_tool_blocks(sample);
    pass &= expect(calls.size() == 1 && calls[0].name == "list_local_dir", "parse list");

    const std::string write_block =
        "*** TOOL\nname: write_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "<<<<\nhello-tools\n>>>>\n*** END\n";
    CreateDirectoryA("C:\\Temp\\GitHub", nullptr);
    const std::string wres = local_tools::run_tools_from_text(write_block);
    pass &= expect(wres.find("write_local_file ok") != std::string::npos, "write ok");
    pass &= expect(wres.find("before=") != std::string::npos && wres.find("after=") != std::string::npos,
                   "write hashes");
    {
        std::ifstream in("C:\\Temp\\GitHub\\godbrain-tool-test.txt");
        std::string body;
        std::getline(in, body);
        pass &= expect(body == "hello-tools", "wrote bytes");
    }
    pass &= expect(GetFileAttributesA("C:\\Temp\\GitHub\\godbrain-tool-test.txt.gb-tmp") ==
                       INVALID_FILE_ATTRIBUTES,
                   "write left no tmp");

    const char kAppend[] = "C:\\Temp\\GitHub\\godbrain-tool-append.txt";
    const std::string append_seed =
        "*** TOOL\nname: write_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-append.txt\n"
        "<<<<\nalpha\n>>>>\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(append_seed).find("write_local_file ok") !=
                       std::string::npos,
                   "append seed");
    const std::string append_block =
        "*** TOOL\nname: write_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-append.txt\n"
        "args: append\n<<<<\nbeta\n>>>>\n*** END\n";
    const std::string ares = local_tools::run_tools_from_text(append_block);
    pass &= expect(ares.find("write_local_file ok") != std::string::npos &&
                       ares.find("append") != std::string::npos,
                   "append ok");
    {
        std::ifstream in(kAppend);
        std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        pass &= expect(all == "alpha\nbeta\n", "append kept dest");
    }
    HANDLE lock = CreateFileA(kAppend, GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    pass &= expect(lock != INVALID_HANDLE_VALUE, "append lock open");
    if (lock != INVALID_HANDLE_VALUE) {
        const std::string locked =
            "*** TOOL\nname: write_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-append.txt\n"
            "args: append\n<<<<\ngamma\n>>>>\n*** END\n";
        const std::string lres = local_tools::run_tools_from_text(locked);
        pass &= expect(lres.find("dest unread") != std::string::npos, "append unread");
        CloseHandle(lock);
        std::ifstream in2(kAppend);
        std::string all2((std::istreambuf_iterator<char>(in2)), std::istreambuf_iterator<char>());
        pass &= expect(all2 == "alpha\nbeta\n", "append unread left dest");
    }
    DeleteFileA(kAppend);

    const std::string deny =
        "*** TOOL\nname: write_local_file\npath: C:\\Windows\\Temp\\nope.txt\n"
        "<<<<\nx\n>>>>\n*** END\n";
    const std::string dres = local_tools::run_tools_from_text(deny);
    pass &= expect(dres.find("denied") != std::string::npos, "windows write denied");

    const std::string unknown =
        "*** TOOL\nname: run_mfit\npath: C:\\Temp\\GitHub\\x.bin\n*** END\n";
    const std::string ures = local_tools::run_tools_from_text(unknown);
    pass &= expect(ures.find("unknown tool") != std::string::npos, "mfit unknown");

    const std::string kill =
        "*** TOOL\nname: pskill64\nargs: explorer\n*** END\n";
    const std::string kres = local_tools::run_tools_from_text(kill);
    pass &= expect(kres.find("never allowed") != std::string::npos, "pskill denied");

    const std::string psexec =
        "*** TOOL\nname: run_sysint\nexe: psexec64\nargs: -s cmd\n*** END\n";
    const std::string pres = local_tools::run_tools_from_text(psexec);
    pass &= expect(pres.find("never allowed") != std::string::npos, "psexec denied");

    const std::string args_block =
        "*** TOOL\nname: run_reg\nargs: query HKCU\\Environment /v TEMP\n*** END\n";
    auto parsed = local_tools::parse_tool_blocks(args_block);
    pass &= expect(parsed.size() == 1 && parsed[0].name == "run_reg" &&
                       parsed[0].args.find("HKCU") != std::string::npos,
                   "parse args");
    const std::string rres = local_tools::run_tools_from_text(args_block);
    pass &= expect(rres.find("run_reg query") != std::string::npos, "reg query");
    pass &= expect(rres.find("denied") == std::string::npos, "reg query allowed");

    const std::string mutate_reg =
        "*** TOOL\nname: run_reg\nargs: add HKCU\\Software\\GodBrainToolTest /f\n*** END\n";
    bool mutate_ok = true;
    const std::string mres = local_tools::execute_calls(
        local_tools::parse_tool_blocks(mutate_reg), &mutate_ok);
    pass &= expect(mres.find("YOLO required") != std::string::npos, "reg add needs yolo");
    pass &= expect(!mutate_ok, "reg add denial is not ok");

    const char* kSqlDb = "C:\\Temp\\GitHub\\godbrain-sqlite-contain.db";
    const char* kSqlAttach = "C:\\Temp\\GitHub\\godbrain-sqlite-attach.db";
    const char* kSqlWrite = "C:\\Temp\\GitHub\\godbrain-sqlite-writefile.txt";
    const char* kSqlShell = "C:\\Temp\\GitHub\\godbrain-sqlite-shell.txt";
    const char* kRegFile = "C:\\Temp\\GitHub\\godbrain-reg-export.reg";
    const char* kRegOutside = "C:\\Windows\\Temp\\godbrain-reg-export.reg";
    DeleteFileA(kSqlAttach);
    DeleteFileA(kSqlWrite);
    DeleteFileA(kSqlShell);
    DeleteFileA(kRegFile);
    DeleteFileA(kRegOutside);
    pass &= expect(write_sqlite_fixture(kSqlDb), "sqlite fixture");
    const SqliteFnProbe fn_probe = probe_sqlite_function_args();
    pass &= expect(fn_probe.ready, "sqlite probe loaded");
    pass &= expect(fn_probe.hex_in_b && !fn_probe.hex_in_a,
                   "sqlite function name is the second authorizer arg");
    const std::string sql_read =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: SELECT v FROM t\n*** END\n";
    const std::string sql_read_res = local_tools::run_tools_from_text(sql_read);
    pass &= expect(sql_read_res.find("hello-sql") != std::string::npos,
                   "sqlite select");
    pass &= expect(sql_read_res.find("exit=") == std::string::npos,
                   "sqlite select launches no shell");
    const std::string sql_write =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: INSERT INTO t VALUES ('nope')\n*** END\n";
    const std::string sql_write_res = local_tools::run_tools_from_text(sql_write);
    pass &= expect(sql_write_res.find("denied") != std::string::npos,
                   "sqlite insert denied");
    const std::string sql_after = local_tools::run_tools_from_text(sql_read);
    pass &= expect(sql_after.find("hello-sql") != std::string::npos &&
                       sql_after.find("nope") == std::string::npos,
                   "sqlite insert wrote nothing");
    const std::string sql_attach =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: ATTACH DATABASE 'C:/Temp/GitHub/godbrain-sqlite-attach.db' AS extra\n*** END\n";
    const std::string sql_attach_res = local_tools::run_tools_from_text(sql_attach);
    pass &= expect(sql_attach_res.find("denied: attach") != std::string::npos,
                   "sqlite attach denied");
    pass &= expect(file_absent(kSqlAttach), "sqlite attach created nothing");
    const std::string sql_fn =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: SELECT writefile('C:/Temp/GitHub/godbrain-sqlite-writefile.txt','pwned')\n*** END\n";
    const std::string sql_fn_res = local_tools::run_tools_from_text(sql_fn);
    if (fn_probe.writefile_seen) {
        pass &= expect(sql_fn_res.find("denied: writefile") != std::string::npos,
                       "sqlite writefile denied");
    } else {
        pass &= expect(sql_fn_res.find("no such function") != std::string::npos,
                       "sqlite writefile absent");
    }
    pass &= expect(file_absent(kSqlWrite), "sqlite writefile created nothing");
    const std::string sql_load =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: SELECT load_extension('x')\n*** END\n";
    const std::string sql_load_res = local_tools::run_tools_from_text(sql_load);
    if (fn_probe.load_extension_seen) {
        pass &= expect(sql_load_res.find("denied: load_extension") != std::string::npos,
                       "sqlite load_extension denied");
    } else {
        pass &= expect(sql_load_res.find("no such function") != std::string::npos,
                       "sqlite load_extension absent");
    }
    const std::string sql_small =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: SELECT length(randomblob(8))\n*** END\n";
    const std::string sql_small_res = local_tools::run_tools_from_text(sql_small);
    pass &= expect(sql_small_res.find("\n8\n") != std::string::npos, "sqlite small blob");
    const std::string sql_huge =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: SELECT randomblob(500000000)\n*** END\n";
    const std::string sql_huge_res = local_tools::run_tools_from_text(sql_huge);
    pass &= expect(sql_huge_res.size() < 4096, "sqlite huge blob stays small");
    pass &= expect(sql_huge_res.find("too big") != std::string::npos,
                   "sqlite huge blob rejected");
    if (sql_huge_res.size() >= 4096 ||
        sql_huge_res.find("too big") == std::string::npos) {
        std::cerr << "HUGE " << sql_huge_res.substr(0, 400) << std::endl;
    }
    const std::string sql_dot =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: .shell cmd /c echo pwned\n*** END\n";
    const std::string sql_dot_res = local_tools::run_tools_from_text(sql_dot);
    pass &= expect(sql_dot_res.find("denied: dot command") != std::string::npos,
                   "sqlite dot command denied");
    pass &= expect(file_absent(kSqlShell), "sqlite shell created nothing");
    const std::string sql_pragma =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: PRAGMA writable_schema=ON\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(sql_pragma).find("denied") !=
                       std::string::npos,
                   "sqlite pragma setter denied");
    const std::string sql_info =
        std::string("*** TOOL\nname: run_sqlite3\npath: ") + kSqlDb +
        "\nsql: PRAGMA table_info(t)\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(sql_info).find("v") !=
                       std::string::npos,
                   "sqlite table_info");
    const std::string sql_out =
        "*** TOOL\nname: run_sqlite3\npath: C:\\Windows\\Temp\\nope.db\n"
        "sql: SELECT 1\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(sql_out).find("denied") !=
                       std::string::npos,
                   "sqlite outside jail denied");

    const std::string reg_export =
        std::string("*** TOOL\nname: run_reg\nargs: export HKCU\\Environment ") +
        kRegFile + "\n*** END\n";
    const std::string reg_off = local_tools::run_tools_from_text(reg_export);
    pass &= expect(reg_off.find("YOLO required") != std::string::npos,
                   "reg export needs yolo");
    pass &= expect(file_absent(kRegFile), "reg export without yolo wrote nothing");
    local_tools::set_yolo_minutes(1);
    const std::string reg_outside =
        std::string("*** TOOL\nname: run_reg\nargs: export HKCU\\Environment ") +
        kRegOutside + "\n*** END\n";
    const std::string reg_out_res = local_tools::run_tools_from_text(reg_outside);
    pass &= expect(reg_out_res.find("denied") != std::string::npos,
                   "reg export outside jail denied");
    pass &= expect(file_absent(kRegOutside), "reg export outside wrote nothing");
    const std::string reg_flag =
        std::string("*** TOOL\nname: run_reg\nargs: export HKCU\\Environment ") +
        kRegFile + " /f\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(reg_flag).find("denied") !=
                       std::string::npos,
                   "reg export rejects unknown flags");
    pass &= expect(file_absent(kRegFile), "bad reg export wrote nothing");
    const std::string reg_sam =
        std::string("*** TOOL\nname: run_reg\nargs: export HKLM\\SAM ") + kRegFile +
        "\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(reg_sam).find("SAM") !=
                       std::string::npos,
                   "reg export sam denied");
    pass &= expect(file_absent(kRegFile), "sam export wrote nothing");
    const std::string reg_add =
        "*** TOOL\nname: run_reg\nargs: add HKCU\\Software\\GodBrainToolRegExport "
        "/v Sample /t REG_SZ /d hello-reg /f\n*** END\n";
    const std::string reg_add_res = local_tools::run_tools_from_text(reg_add);
    pass &= expect(reg_add_res.find("exit=0") != std::string::npos, "reg sample key");
    const std::string reg_sample =
        std::string("*** TOOL\nname: run_reg\nargs: export "
                    "HKCU\\Software\\GodBrainToolRegExport ") +
        kRegFile + "\n*** END\n";
    const std::string reg_ok = local_tools::run_tools_from_text(reg_sample);
    pass &= expect(reg_ok.find("exit=0") != std::string::npos, "reg export granted");
    {
        std::ifstream in(kRegFile, std::ios::binary);
        std::string body((std::istreambuf_iterator<char>(in)),
                         std::istreambuf_iterator<char>());
        const char wide_hello[] = {'h', '\0', 'e', '\0', 'l', '\0', 'l', '\0',
                                   'o', '\0', '-', '\0', 'r', '\0', 'e', '\0',
                                   'g', '\0'};
        const bool ascii = body.find("hello-reg") != std::string::npos;
        const bool utf16 =
            body.find(std::string(wide_hello, sizeof(wide_hello))) != std::string::npos;
        pass &= expect(ascii || utf16, "reg export file");
    }
    const std::string reg_del =
        "*** TOOL\nname: run_reg\nargs: delete HKCU\\Software\\GodBrainToolRegExport "
        "/f\n*** END\n";
    const std::string reg_del_res = local_tools::run_tools_from_text(reg_del);
    pass &= expect(reg_del_res.find("exit=0") != std::string::npos,
                   "reg sample key deleted");
    if (reg_del_res.find("exit=0") == std::string::npos) {
        system("reg.exe delete HKCU\\Software\\GodBrainToolRegExport /f >nul 2>nul");
    }
    local_tools::set_yolo_minutes(0);
    DeleteFileA(kSqlDb);
    DeleteFileA(kSqlAttach);
    DeleteFileA(kSqlWrite);
    DeleteFileA(kSqlShell);
    DeleteFileA(kRegFile);
    DeleteFileA(kRegOutside);

    const std::string pwsh_inline =
        "*** TOOL\nname: run_pwsh\n<<<<\nWrite-Output 'desk-ok'\n>>>>\n*** END\n";
    const std::string ires = local_tools::run_tools_from_text(pwsh_inline);
    pass &= expect(ires.find("YOLO required") == std::string::npos, "inline pwsh always");
    pass &= expect(ires.find("desk-ok") != std::string::npos, "inline pwsh output");

    const std::string search_block =
        "*** TOOL\nname: search_local\npath: C:\\Temp\\GitHub\nargs: godbrain-tool-test\n*** END\n";
    const std::string sres = local_tools::run_tools_from_text(search_block);
    pass &= expect(sres.find("godbrain-tool-test") != std::string::npos, "search hits");

    const std::string edit_block =
        "*** TOOL\nname: edit_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "old: hello-tools\n<<<<\nhello-desk\n>>>>\n*** END\n";
    const std::string eres_edit = local_tools::run_tools_from_text(edit_block);
    pass &= expect(eres_edit.find("edit_local_file ok") != std::string::npos, "edit ok");
    pass &= expect(eres_edit.find("before=") != std::string::npos &&
                       eres_edit.find("after=") != std::string::npos,
                   "edit hashes");
    {
        std::ifstream in2("C:\\Temp\\GitHub\\godbrain-tool-test.txt");
        std::string body2;
        std::getline(in2, body2);
        pass &= expect(body2 == "hello-desk", "edit wrote");
    }
    const std::string edit_miss_block =
        "*** TOOL\nname: edit_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "old: not-in-file\n<<<<\nwiped\n>>>>\n*** END\n";
    const std::string edit_miss_res = local_tools::run_tools_from_text(edit_miss_block);
    pass &= expect(edit_miss_res.find("old_text not found") != std::string::npos, "edit miss");
    {
        std::ifstream in3("C:\\Temp\\GitHub\\godbrain-tool-test.txt");
        std::string body3;
        std::getline(in3, body3);
        pass &= expect(body3 == "hello-desk", "miss did not write");
    }
    pass &= expect(GetFileAttributesA("C:\\Temp\\GitHub\\godbrain-tool-test.txt.gb-tmp") ==
                       INVALID_FILE_ATTRIBUTES,
                   "edit left no tmp");

    const std::string elev =
        "*** TOOL\nname: run_elevate\n<<<<\nwhoami\n>>>>\n*** END\n";
    bool elev_ok = true;
    const std::string eres = local_tools::execute_calls(
        local_tools::parse_tool_blocks(elev), &elev_ok);
    pass &= expect(eres.find("YOLO required") != std::string::npos, "elevate needs yolo");
    pass &= expect(!elev_ok, "elevate denial is not ok");
    const std::string acl_need =
        "*** TOOL\nname: acl_takeover\npath: C:\\Temp\\GitHub\\godbrain-acl-test\n"
        "*** END\n";
    bool acl_ok = true;
    const std::string acl_res = local_tools::execute_calls(
        local_tools::parse_tool_blocks(acl_need), &acl_ok);
    pass &= expect(acl_res.find("YOLO required") != std::string::npos,
                   "acl takeover needs yolo");
    pass &= expect(!acl_ok, "acl denial is not ok");
    bool host_ok = true;
    const std::string host_deny = local_tools::execute_calls(
        local_tools::parse_tool_blocks(
            "*** TOOL\nname: run_wevtutil\nargs: cl System\n*** END\n"
            "*** TOOL\nname: run_logman\nargs: start\n*** END\n"
            "*** TOOL\nname: run_schtasks\nargs: /Run /TN GodBrainWatch\n*** END\n"
            "*** TOOL\nname: run_host\nargs: ipconfig /flushdns\n*** END\n"),
        &host_ok);
    pass &= expect(host_deny.find("YOLO required") != std::string::npos, "host mutate needs yolo");
    pass &= expect(!host_ok, "host mutate denial is not ok");

    const std::string gb_del =
        "*** TOOL\nname: run_schtasks\nargs: /Delete /TN GodBrainWatch /F\n*** END\n";
    const std::string gres = local_tools::run_tools_from_text(gb_del);
    pass &= expect(gres.find("YOLO required") != std::string::npos ||
                       gres.find("GodBrain") != std::string::npos,
                   "godbrain task delete blocked");

    char module_path[MAX_PATH];
    GetModuleFileNameA(nullptr, module_path, MAX_PATH);
    std::string module_dir(module_path);
    const size_t module_slash = module_dir.find_last_of("\\/");
    if (module_slash != std::string::npos) module_dir.resize(module_slash);
    char yolo_file[MAX_PATH];
    GetFullPathNameA((module_dir + "\\..\\..\\logs\\tool-yolo.json").c_str(),
                     MAX_PATH, yolo_file, nullptr);
    {
        std::ofstream plant(yolo_file, std::ios::binary | std::ios::trunc);
        plant << "{\"until\":4102444800}";
    }
    pass &= expect(!local_tools::yolo_active(), "planted receipt is not approval");
    const std::string yolo_on = local_tools::set_yolo_minutes(1);
    pass &= expect(local_tools::yolo_active(), "yolo latches");
    pass &= expect(yolo_on.find("kernel exits") != std::string::npos,
                   "yolo says it ends with the kernel");
    pass &= expect(GetFileAttributesA(yolo_file) == INVALID_FILE_ATTRIBUTES,
                   "yolo set deletes the receipt");
    {
        std::ofstream plant(yolo_file, std::ios::binary | std::ios::trunc);
        plant << "{\"until\":1}";
    }
    pass &= expect(local_tools::yolo_active(), "later receipt cannot clear yolo");
    local_tools::set_yolo_minutes(0);
    pass &= expect(!local_tools::yolo_active(), "yolo clear is memory");
    {
        std::ofstream plant(yolo_file, std::ios::binary | std::ios::trunc);
        plant << "{\"until\":4102444800}";
    }
    pass &= expect(!local_tools::yolo_active(), "later receipt cannot enable yolo");
    DeleteFileA(yolo_file);
    local_tools::set_yolo_minutes(1);
    const std::string ti =
        "*** TOOL\nname: run_elevate\n<<<<\nwsudo --ti cmd\n>>>>\n*** END\n";
    pass &= expect(local_tools::yolo_active(), "yolo latches");
    const std::string tres = local_tools::run_tools_from_text(ti);
    pass &= expect(tres.find("TrustedInstaller") != std::string::npos ||
                       tres.find("--ti") != std::string::npos ||
                       tres.find("denied") != std::string::npos,
                   "ti denied even in yolo");
    const std::string tflag =
        "*** TOOL\nname: run_elevate\n<<<<\nwsudo -T cmd\n>>>>\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(tflag).find("denied") !=
                       std::string::npos,
                   "wsudo -T denied on run_elevate");
    const std::string gres2 = local_tools::run_tools_from_text(gb_del);
    pass &= expect(gres2.find("GodBrain") != std::string::npos,
                   "godbrain task delete blocked in yolo");
    pass &= expect(local_tools::run_tools_from_text(
                       "*** TOOL\nname: acl_takeover\npath: C:\\Windows\\System32\n"
                       "*** END\n")
                       .find("denied") != std::string::npos,
                   "acl system32 denied");
    pass &= expect(
        local_tools::run_tools_from_text(
            "*** TOOL\nname: acl_takeover\n"
            "path: C:\\Windows\\System32\\config\\SAM\n*** END\n")
            .find("denied") != std::string::npos,
        "acl SAM denied");
    pass &= expect(local_tools::run_tools_from_text(
                       "*** TOOL\nname: acl_release\n"
                       "path: C:\\Temp\\GitHub\\no-such-acl-key\n*** END\n")
                       .find("denied") != std::string::npos,
                   "acl release without key denied");
    pass &= expect(local_tools::run_tools_from_text(
                       "*** TOOL\nname: acl_takeover\npath: C:\\Tools\n*** END\n")
                       .find("denied") != std::string::npos,
                   "acl Tools root denied");
    pass &= expect(local_tools::run_tools_from_text(
                       "*** TOOL\nname: icacls\npath: C:\\Temp\\GitHub\n*** END\n")
                       .find("unknown tool") != std::string::npos,
                   "bare icacls is not takeover");
    local_tools::set_yolo_minutes(0);

    {
        const auto jail = schema_names(false);
        pass &= expect(jail.count("list_granted_roots") == 1,
                       "file jail advertises roots");
        pass &= expect(jail.count("run_pwsh") == 0, "file jail omits pwsh");
        local_tools::Call roots;
        roots.name = "list_granted_roots";
        bool roots_ok = false;
        const std::string roots_out =
            local_tools::execute_calls({roots}, &roots_ok, &jail);
        pass &= expect(roots_ok, "advertised roots stays ok");
        pass &= expect(roots_out.find("Kernel jail") != std::string::npos,
                       "advertised roots lists the jail");
        pass &= expect(roots_out.find("exit=") == std::string::npos,
                       "advertised roots starts no process");

        char audit_file[MAX_PATH];
        GetFullPathNameA((module_dir + "\\..\\..\\logs\\tool-audit.jsonl").c_str(),
                         MAX_PATH, audit_file, nullptr);
        const unsigned long long before = file_size_or_zero(audit_file);
        local_tools::Call denied;
        denied.name = "run_pwsh";
        denied.content = "Write-Output AUTHORITY_RAN";
        bool denied_ok = true;
        const std::string denied_out =
            local_tools::execute_calls({denied}, &denied_ok, &jail);
        pass &= expect(!denied_ok, "omitted pwsh fails the hop");
        pass &= expect(denied_out.find("not advertised") != std::string::npos,
                       "omitted pwsh is denied");
        pass &= expect(denied_out.find("AUTHORITY_RAN") == std::string::npos,
                       "omitted pwsh does not run");
        pass &= expect(denied_out.find("exit=") == std::string::npos,
                       "omitted pwsh has no process receipt");
        local_tools::Call alias;
        alias.name = "execute_command";
        alias.content = "Write-Output AUTHORITY_RAN";
        bool alias_ok = true;
        const std::string alias_out =
            local_tools::execute_calls({alias}, &alias_ok, &jail);
        pass &= expect(alias_out.find("run_pwsh denied: not advertised") !=
                           std::string::npos,
                       "execute_command follows the pwsh allow");
        pass &= expect(alias_out.find("AUTHORITY_RAN") == std::string::npos,
                       "aliased pwsh does not run");
        pass &= expect(file_size_or_zero(audit_file) == before,
                       "omitted tools write no audit");
        const unsigned long long before_sys = file_size_or_zero(audit_file);
        local_tools::Call sys_alias;
        sys_alias.name = "clockres64";
        bool sys_ok = true;
        const std::string sys_out =
            local_tools::execute_calls({sys_alias}, &sys_ok, &jail);
        pass &= expect(!sys_ok, "file jail rejects clockres64");
        pass &= expect(sys_out.find("run_sysint denied: not advertised") !=
                           std::string::npos,
                       "clockres64 follows the sysint allow");
        pass &= expect(sys_out.find("exit=") == std::string::npos,
                       "file-jail clockres64 starts no process");
        pass &= expect(file_size_or_zero(audit_file) == before_sys,
                       "file-jail clockres64 writes no audit");

        const auto full = schema_names(true);
        pass &= expect(full.count("run_pwsh") == 1, "full schema advertises pwsh");
        local_tools::Call empty_cmd;
        empty_cmd.name = "execute_command";
        bool empty_ok = true;
        const std::string empty_out =
            local_tools::execute_calls({empty_cmd}, &empty_ok, &full);
        pass &= expect(empty_out.find("command body required") != std::string::npos,
                       "advertised empty pwsh stops before launch");
        pass &= expect(empty_out.find("exit=") == std::string::npos,
                       "advertised empty pwsh starts no process");
        pass &= expect(empty_out.find("not advertised") == std::string::npos,
                       "advertised empty pwsh is in the schema");
        local_tools::Call sys_full;
        sys_full.name = "clockres64";
        sys_full.args = "\n";
        bool sys_full_ok = true;
        const std::string sys_full_out =
            local_tools::execute_calls({sys_full}, &sys_full_ok, &full);
        pass &= expect(sys_full_out.find("args must be one line") != std::string::npos,
                       "full schema accepts clockres64");
        pass &= expect(sys_full_out.find("not advertised") == std::string::npos,
                       "advertised clockres64 is not an omit");
        pass &= expect(sys_full_out.find("exit=") == std::string::npos,
                       "newline clockres64 starts no process");

        const std::unordered_set<std::string> none;
        bool none_ok = true;
        const std::string none_out =
            local_tools::execute_calls({roots}, &none_ok, &none);
        pass &= expect(none_out.find("not advertised") != std::string::npos,
                       "empty schema denies every model tool");
        pass &= expect(none_out.find("Kernel jail") == std::string::npos,
                       "empty schema does not list roots");
    }

    const std::string pwsh_ti =
        "*** TOOL\nname: run_pwsh\n<<<<\nwsudo -T cmd\n>>>>\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(pwsh_ti).find("denied") !=
                       std::string::npos,
                   "wsudo -T denied on run_pwsh");
    const std::string pingt =
        "*** TOOL\nname: run_pwsh\n<<<<\n'ping -t is not ti'\n>>>>\n*** END\n";
    const std::string pingr = local_tools::run_tools_from_text(pingt);
    pass &= expect(pingr.find("denied") == std::string::npos &&
                       pingr.find("ping -t is not ti") != std::string::npos,
                   "ping -t is not TI deny");
    {
        char mod[MAX_PATH];
        GetModuleFileNameA(NULL, mod, MAX_PATH);
        std::string dir(mod);
        const size_t slash = dir.find_last_of("\\/");
        if (slash != std::string::npos) dir.resize(slash);
        char plant[MAX_PATH];
        GetFullPathNameA((dir + "\\..\\..\\logs\\acl\\plant.txt").c_str(), MAX_PATH,
                         plant, nullptr);
        const std::string wacl =
            std::string("*** TOOL\nname: write_local_file\npath: ") + plant +
            "\n<<<<\nplanted\n>>>>\n*** END\n";
        pass &= expect(local_tools::run_tools_from_text(wacl).find("denied") !=
                           std::string::npos,
                       "acl key dir not mouth-writable");
        pass &= expect(
            local_tools::run_tools_from_text(
                "*** TOOL\nname: write_local_file\n"
                "path: C:\\Tools\\TeamM2\\wsudo.exe\n<<<<\nx\n>>>>\n*** END\n")
                .find("denied") != std::string::npos,
            "wsudo.exe not mouth-writable");
    }

    const std::string clock =
        "*** TOOL\nname: clockres64\n*** END\n";
    const std::string cres = local_tools::run_tools_from_text(clock);
    pass &= expect(cres.find("run_sysint clockres") != std::string::npos, "clockres runs");
    pass &= expect(cres.find("denied") == std::string::npos, "clockres not denied");

    const std::string who =
        "*** TOOL\nname: whoami\n*** END\n";
    const std::string wres2 = local_tools::run_tools_from_text(who);
    pass &= expect(wres2.find("run_host whoami") != std::string::npos, "whoami host");

    const std::string mkdir =
        "*** TOOL\nname: create_local_dir\npath: C:\\Temp\\GitHub\\godbrain-tool-dir\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(mkdir).find("create_local_dir ok") !=
                       std::string::npos,
                   "mkdir");

    const std::string info =
        "*** TOOL\nname: get_file_info\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n*** END\n";
    const std::string iinfo = local_tools::run_tools_from_text(info);
    pass &= expect(iinfo.find("bytes=") != std::string::npos, "file info");

    const std::string tail =
        "*** TOOL\nname: read_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "args: offset=-1 limit=1\n*** END\n";
    const std::string tres_tail = local_tools::run_tools_from_text(tail);
    pass &= expect(tres_tail.find("hello-desk") != std::string::npos, "tail read");

    const std::string mv =
        "*** TOOL\nname: move_local_file\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "dest: C:\\Temp\\GitHub\\godbrain-tool-dir\\moved.txt\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(mv).find("move_local_file ok") !=
                       std::string::npos,
                   "move");
    const std::string mvback =
        "*** TOOL\nname: move_file\npath: C:\\Temp\\GitHub\\godbrain-tool-dir\\moved.txt\n"
        "dest: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(mvback).find("move_local_file ok") !=
                       std::string::npos,
                   "move alias");

    const std::string py =
        "*** TOOL\nname: run_python\n<<<<\nprint('py-ok')\n>>>>\n*** END\n";
    const std::string pyres = local_tools::run_tools_from_text(py);
    pass &= expect(pyres.find("py-ok") != std::string::npos, "python inline");
    pass &= expect(pyres.find("exit=0") != std::string::npos, "python exit=0");

    const std::string pyfail =
        "*** TOOL\nname: run_python\n<<<<\nimport sys\nsys.exit(7)\n>>>>\n*** END\n";
    bool fail_ok = true;
    const std::string pyfailr = local_tools::execute_calls(
        local_tools::parse_tool_blocks(pyfail), &fail_ok);
    pass &= expect(pyfailr.find("exit=7") != std::string::npos, "python exit=7");
    pass &= expect(!fail_ok, "execute_calls all_ok false on exit 7");

    bool miss_ok = true;
    const std::string miss_block =
        "*** TOOL\nname: search_local\npath: C:\\Temp\\GitHub\\godbrain-tool-test.txt\n"
        "args: content:zzzx-no-match-gb124\n*** END\n";
    const std::string missr = local_tools::execute_calls(
        local_tools::parse_tool_blocks(miss_block), &miss_ok);
    pass &= expect(miss_ok, "search_local no-match does not fail hop");

    const std::string js =
        "*** TOOL\nname: run_node\n<<<<\nconsole.log('node-ok')\n>>>>\n*** END\n";
    const std::string jsres = local_tools::run_tools_from_text(js);
    pass &= expect(jsres.find("node-ok") != std::string::npos, "node inline");

    const std::string gemma_tc =
        "<|tool_call>_call:list_granted_roots{}<tool_call|>";
    const std::string gemma_res = local_tools::run_tools_from_text(gemma_tc);
    pass &= expect(local_tools::has_tool_block(gemma_tc) &&
                       gemma_res.find("list_granted_roots") !=
                           std::string::npos &&
                       gemma_res.find("not Mongo") != std::string::npos,
                   "gemma tool_call text runs");

    const std::string killp =
        "*** TOOL\nname: kill_process\nargs: 1\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(killp).find("denied") !=
                       std::string::npos,
                   "kill denied");

    const auto defs = local_tools::openai_tool_defs();
    pass &= expect(defs.is_array() && defs.size() >= 8, "openai tool defs");
    const std::string rw =
        "Do you have read and write access to " + home +
        "\\Documents\\GitHub\\GodBrain";
    pass &= expect(local_tools::looks_like_local_fs_ask(rw), "rw path is local-fs");
    pass &= expect(!local_tools::looks_like_host_inspect(rw), "rw path not host inspect");
    pass &= expect(!local_tools::use_full_tool_defs(rw), "rw path files-only");
    const auto files = local_tools::openai_tool_defs_for(rw);
    pass &= expect(files.is_array() && files.size() == 11, "files hop 11 tools");
    bool files_has_sysint = false;
    bool files_has_info = false;
    bool files_has_roots = false;
    bool files_has_map = false;
    bool files_has_snap = false;
    for (const auto& t : files) {
        const std::string n = t["function"].value("name", "");
        if (n == "run_sysint") files_has_sysint = true;
        if (n == "get_file_info") files_has_info = true;
        if (n == "list_granted_roots") files_has_roots = true;
        if (n == "repo_map") files_has_map = true;
        if (n == "host_snap") files_has_snap = true;
    }
    pass &= expect(!files_has_sysint, "files hop no sysint");
    pass &= expect(files_has_info, "files hop has get_file_info");
    pass &= expect(files_has_roots, "files hop has list_granted_roots");
    pass &= expect(files_has_map, "files hop has repo_map");
    pass &= expect(files_has_snap, "files hop has host_snap");
    const auto host_defs =
        local_tools::openai_tool_defs_for("run_sysint handle64 on CS2");
    pass &= expect(host_defs.size() > files.size(), "host inspect full tools");
    pass &= expect(!local_tools::looks_like_local_fs_ask("what is 2+2"),
                   "math is not local-fs");
    pass &= expect(
        local_tools::looks_like_local_fs_ask("what are the authorized paths"),
        "authorized paths is local-fs");
    pass &= expect(
        local_tools::looks_like_fs_refuse(
            "I do not have access to your local file system "
            "(C:\\Users\\autismo\\Documents\\GitHub\\GodBrain)"),
        "fs refuse detected");
    pass &= expect(!local_tools::looks_like_fs_refuse("get_file_info ok bytes=12"),
                   "tool result is not fs refuse");
    pass &= expect(!local_tools::looks_like_fs_refuse("I cannot access the GPU"),
                   "cannot access GPU is not fs refuse");
    {
        const std::string probe = local_tools::answer_fs_ask(
            "I do not have access to " + home +
            "\\Documents\\GitHub\\GodBrain");
        pass &= expect((probe.find("get_file_info") != std::string::npos ||
                        probe.find("list_local_dir") != std::string::npos) &&
                           probe.find("denied") == std::string::npos &&
                           probe.find("repo that needs") == std::string::npos,
                       "fs refuse probe hits repo");
        const std::string longq =
            "Can you find anything apparent in " + home +
            "\\Documents\\GitHub\\GodBrain repo that needs fixing for you "
            "to become Jarvis?";
        const std::string longp = local_tools::answer_fs_ask(longq);
        pass &= expect(longp.find("repo that needs") == std::string::npos &&
                           longp.find("GodBrain") != std::string::npos &&
                           longp.find("missing") == std::string::npos,
                       "path stops at GodBrain not English tail");
        pass &= expect(local_tools::looks_like_local_fs_ask(longq),
                       "jarvis repo ask is local-fs");
        pass &= expect(!local_tools::looks_like_list_only_ask(longq),
                       "jarvis repo ask is not list-only");
        const std::string rails = local_tools::read_repo_rails(longq);
        pass &= expect(rails.find("read_local_file") != std::string::npos &&
                           rails.find("AGENTS.md") != std::string::npos &&
                           rails.find("Heal-GodBrain.ps1") != std::string::npos,
                       "rails read AGENTS and Heal");
        const std::string blurb = local_tools::jarvis_rails_blurb();
        pass &= expect(blurb.find("one loop") != std::string::npos &&
                           blurb.find("copilot-instructions") != std::string::npos &&
                           blurb.find("temp_hermes") != std::string::npos,
                       "jarvis blurb names leftovers");
        const std::string agread = local_tools::run_tools_from_text(
            std::string("*** TOOL\nname: read_local_file\npath: ") + home +
            "\\Documents\\GitHub\\GodBrain\\AGENTS.md\n*** END\n");
        pass &= expect(agread.find("kernel rails") != std::string::npos &&
                           agread.find("one loop") != std::string::npos &&
                           agread.size() < 2500,
                       "AGENTS.md read is blurb not a dump");
        const std::string miss =
            "search_local C:\\Temp\\GitHub name q=GodBrain repo hits=0 "
            "scanned=400\n";
        const std::string padded =
            local_tools::complete_fs_listing(longq, miss);
        pass &= expect(padded.find("search_local") != std::string::npos &&
                           padded.find("list_local_dir") != std::string::npos &&
                           padded.find("GodBrain") != std::string::npos &&
                           padded.find("repo that needs") == std::string::npos,
                       "missed Temp hop still lists named repo");
        const std::string already =
            "list_local_dir " + home +
            "\\Documents\\GitHub\\GodBrain depth=1\n";
        pass &= expect(local_tools::complete_fs_listing(longq, already) ==
                           already,
                       "complete_fs_listing is idempotent");
        pass &= expect(local_tools::complete_fs_listing("what is 2+2", miss) ==
                           miss,
                       "non-fs hop is not padded");
        const std::string map = local_tools::analysis_observe(longq);
        int nlines = 0;
        for (char ch : map) {
            if (ch == '\n') ++nlines;
        }
        pass &= expect(map.find("Repo map") != std::string::npos &&
                           map.find("list_local_dir") == std::string::npos &&
                           map.find("AGENTS.md") != std::string::npos &&
                           map.find("README.md") != std::string::npos &&
                           map.find("copilot-instructions") != std::string::npos &&
                           map.find("temp_hermes") != std::string::npos &&
                           nlines >= 12 && map.size() > 800,
                       "analysis observe is a writeup not 10 dir rows");
        pass &= expect(local_tools::analysis_observe("list " + home +
                                                     "\\Documents\\GitHub\\GodBrain")
                           .empty(),
                       "list-only ask is not a repo_map");
        const std::string chg = local_tools::changed_context(
            home + "\\Documents\\GitHub\\GodBrain");
        pass &= expect(chg.find("Changed") != std::string::npos &&
                           (chg.find("mouth-one-fs-hop") != std::string::npos ||
                            chg.find("git") != std::string::npos ||
                            chg.find("Recent") != std::string::npos),
                       "changed_context has git");
        const std::string snap = local_tools::host_snap();
        pass &= expect(snap.find("Host snap") != std::string::npos &&
                           snap.find("Process tree") != std::string::npos &&
                           snap.find("pid=") != std::string::npos &&
                           snap.find("list_local_dir") == std::string::npos &&
                           snap.find("Live stack") != std::string::npos &&
                           snap.size() > 200,
                       "host_snap is FS+process feed not a dir dump");
        const std::string clip = local_tools::host_snap_clip(1400);
        pass &= expect(clip.find("Live stack") == std::string::npos &&
                           clip.find("Process tree") != std::string::npos,
                       "chat clip is process+FS without live-stack rails");
        pass &= expect(
            snap.find("godbrain-kernel") != std::string::npos ||
                snap.find("llama-server") != std::string::npos ||
                snap.find("rag-service") != std::string::npos,
            "host_snap names a live mouth/kernel process");
        const std::string stack = local_tools::live_stack_blurb();
        pass &= expect(stack.find("one generate slot") != std::string::npos &&
                           stack.find("8084") != std::string::npos &&
                           stack.find("second vector") != std::string::npos &&
                           stack.find("same slot") != std::string::npos,
                       "live stack names mouth, RAG, one slot");
        pass &= expect(local_tools::looks_like_jarvis_need_ask(
                           "what else do you still need to be Jarvis"),
                       "jarvis need ask");
        pass &= expect(!local_tools::looks_like_jarvis_need_ask(
                           "No tools. What is 2+2?"),
                       "2+2 is not a need ask");
    }
    {
        const std::string roots = local_tools::run_tools_from_text(
            "*** TOOL\nname: list_granted_roots\n*** END\n");
        pass &= expect(roots.find("list_granted_roots") != std::string::npos &&
                           roots.find("not Mongo") != std::string::npos &&
                           (roots.find("C:\\Tools") != std::string::npos ||
                            roots.find("C:\\Users") != std::string::npos),
                       "list_granted_roots prints jail");
    }
    pass &= expect(local_tools::looks_like_local_fs_ask("list C:\\Temp\\GitHub"),
                   "list granted temp is local-fs");
    pass &= expect(local_tools::looks_like_list_only_ask("list C:\\Temp\\GitHub"),
                   "list temp is list-only");
    pass &= expect(
        local_tools::looks_like_list_only_ask("do you have r/w to the repo"),
        "rw repo is list-only");
    pass &= expect(
        local_tools::looks_like_list_only_ask("what are the authorized paths"),
        "authorized paths is list-only");
    pass &= expect(!local_tools::looks_like_list_only_ask("what is 2+2"),
                   "math is not list-only");
    pass &= expect(
        local_tools::looks_like_local_fs_ask("do you have r/w to the repo"),
        "rw repo is local-fs");
    pass &= expect(
        local_tools::looks_like_local_fs_ask("is the tool jail granted"),
        "jail granted is local-fs");
    {
        const std::string jail =
            local_tools::complete_fs_listing("is the tool jail granted", "");
        pass &= expect(jail.find("list_granted_roots") != std::string::npos &&
                           jail.find("not Mongo") != std::string::npos &&
                           !jail.empty(),
                       "jail grant with no path lists roots");
    }
    pass &= expect(
        !local_tools::looks_like_local_fs_ask("is the local mouth ready"),
        "ready is not local-fs");
    pass &= expect(
        !local_tools::looks_like_local_fs_ask("please read the Heal file"),
        "read Heal file is not local-fs");
    pass &= expect(
        !local_tools::looks_like_local_fs_ask("C:\\Windows\\System32"),
        "system32 is not local-fs");
    pass &= expect(local_tools::looks_like_local_fs_ask("list C:\\Tools\\SysInternals"),
                   "tools subdir is local-fs");
    pass &= expect(
        local_tools::looks_like_local_fs_ask("list C:\\Program Files\\Git"),
        "program files path is local-fs");
    pass &= expect(local_tools::looks_like_local_fs_ask(
                       "read %ProgramFiles(x86)%\\Steam\\steam.exe"),
                   "env programfiles x86 is local-fs");
    pass &= expect(local_tools::looks_like_local_fs_ask(
                       "read %USERPROFILE%\\Desktop\\notes.txt"),
                   "env profile path is local-fs");
    pass &= expect(
        !local_tools::looks_like_local_fs_ask("C:\\Windows\\Temp\\GitHub"),
        "windows temp github suffix is not local-fs");
    pass &= expect(!local_tools::looks_like_local_fs_ask(
                       "https://github.com/users/autismo/GodBrain"),
                   "github url is not local-fs");
    pass &= expect(
        !local_tools::looks_like_local_fs_ask("Does Heal have write access to Tcpip?"),
        "write access without place is not local-fs");
    pass &= expect(local_tools::looks_like_no_tools("No tools.\nWhat is this PC?"),
                   "no tools prefix");
    pass &= expect(local_tools::looks_like_no_tools("no tools: advise"),
                   "no tools colon");
    pass &= expect(!local_tools::looks_like_no_tools("please use no tools if possible"),
                   "no tools not mid-sentence");
    nlohmann::json tcs = nlohmann::json::array();
    tcs.push_back({
        {"id", "c1"},
        {"type", "function"},
        {"function",
         {{"name", "list_local_dir"},
          {"arguments", "{\"path\":\"C:\\\\Temp\\\\GitHub\"}"}}},
    });
    auto from_oai = local_tools::calls_from_openai(tcs);
    pass &= expect(from_oai.size() == 1 && from_oai[0].name == "list_local_dir" &&
                       from_oai[0].path.find("Temp") != std::string::npos,
                   "calls_from_openai");

    if (!pass) return 1;
    std::cout << "local_tools_test ok" << std::endl;
    return 0;
}
