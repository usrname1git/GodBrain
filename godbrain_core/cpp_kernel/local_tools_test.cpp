#include "local_tools.h"

#include <fstream>
#include <iostream>
#include <string>

#include <windows.h>

static bool expect(bool ok, const char* msg) {
    if (!ok) std::cerr << "FAIL " << msg << std::endl;
    return ok;
}

int main() {
    bool pass = true;
    std::string err;
    pass &= expect(!local_tools::path_is_granted("C:\\Windows\\System32\\notepad.exe", &err),
                   "windows denied");
    pass &= expect(!local_tools::path_is_granted(
                       "C:\\Temp\\GitHub\\..\\..\\Windows\\System32\\cmd.exe", &err),
                   "dotdot denied");
    pass &= expect(local_tools::path_is_granted(
                       "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\AGENTS.md", &err),
                   "repo granted");
    pass &= expect(local_tools::path_is_granted("C:\\Temp\\GitHub", &err), "temp github granted");
    pass &= expect(local_tools::path_is_granted("C:\\Users\\autismo\\Desktop", &err),
                   "profile desktop granted");

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
                       tres.find("--ti") != std::string::npos,
                   "ti denied even in yolo");
    const std::string gres2 = local_tools::run_tools_from_text(gb_del);
    pass &= expect(gres2.find("GodBrain") != std::string::npos,
                   "godbrain task delete blocked in yolo");
    local_tools::set_yolo_minutes(0);

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

    const std::string killp =
        "*** TOOL\nname: kill_process\nargs: 1\n*** END\n";
    pass &= expect(local_tools::run_tools_from_text(killp).find("denied") !=
                       std::string::npos,
                   "kill denied");

    const auto defs = local_tools::openai_tool_defs();
    pass &= expect(defs.is_array() && defs.size() >= 8, "openai tool defs");
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
