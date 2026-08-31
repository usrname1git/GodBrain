#include "local_tools.h"

#include <fstream>
#include <iostream>
#include <string>

#include <windows.h>

static bool expect(bool ok, const char* msg) {
    if (!ok) std::cerr << "FAIL " << msg << std::endl;
    return ok;
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
    {
        std::ifstream in("C:\\Temp\\GitHub\\godbrain-tool-test.txt");
        std::string body;
        std::getline(in, body);
        pass &= expect(body == "hello-tools", "wrote bytes");
    }

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
    const std::string mres = local_tools::run_tools_from_text(mutate_reg);
    pass &= expect(mres.find("YOLO required") != std::string::npos, "reg add needs yolo");

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
    {
        std::ifstream in2("C:\\Temp\\GitHub\\godbrain-tool-test.txt");
        std::string body2;
        std::getline(in2, body2);
        pass &= expect(body2 == "hello-desk", "edit wrote");
    }

    const std::string elev =
        "*** TOOL\nname: run_elevate\n<<<<\nwhoami\n>>>>\n*** END\n";
    const std::string eres = local_tools::run_tools_from_text(elev);
    pass &= expect(eres.find("YOLO required") != std::string::npos, "elevate needs yolo");
    const std::string acl_need =
        "*** TOOL\nname: acl_takeover\npath: C:\\Temp\\GitHub\\godbrain-acl-test\n"
        "*** END\n";
    pass &= expect(local_tools::run_tools_from_text(acl_need).find("YOLO required") !=
                       std::string::npos,
                   "acl takeover needs yolo");

    const std::string gb_del =
        "*** TOOL\nname: run_schtasks\nargs: /Delete /TN GodBrainWatch /F\n*** END\n";
    const std::string gres = local_tools::run_tools_from_text(gb_del);
    pass &= expect(gres.find("YOLO required") != std::string::npos ||
                       gres.find("GodBrain") != std::string::npos,
                   "godbrain task delete blocked");

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
    pass &= expect(files.is_array() && files.size() == 10, "files hop 10 tools");
    bool files_has_sysint = false;
    bool files_has_info = false;
    bool files_has_roots = false;
    bool files_has_map = false;
    for (const auto& t : files) {
        const std::string n = t["function"].value("name", "");
        if (n == "run_sysint") files_has_sysint = true;
        if (n == "get_file_info") files_has_info = true;
        if (n == "list_granted_roots") files_has_roots = true;
        if (n == "repo_map") files_has_map = true;
    }
    pass &= expect(!files_has_sysint, "files hop no sysint");
    pass &= expect(files_has_info, "files hop has get_file_info");
    pass &= expect(files_has_roots, "files hop has list_granted_roots");
    pass &= expect(files_has_map, "files hop has repo_map");
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
