#include <fstream>
#include <iostream>
#include <string>

#include "local_edit.h"
#include <windows.h>

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    const std::string think_then_apply =
        "I will change the starter.\n"
        "*** APPLY\n"
        "path: Start-GodBrain.ps1\n"
        "<<<<\n"
        "old line\n"
        "====\n"
        "new line\n"
        ">>>>\n"
        "*** END\n";
    auto preview = local_edit::preview_apply_blocks(think_then_apply);
    if (!expect(preview.count == 1, "think then apply count") ||
        !expect(preview.first_path == "Start-GodBrain.ps1", "think then apply path") ||
        !expect(preview.first_old == "old line\n", "think then apply old") ||
        !expect(preview.first_new == "new line\n", "think then apply new")) {
        return 1;
    }

    const std::string messy =
        "plan sludge\n"
        "***APPLY\n"
        "path: `godbrain_core/cpp_kernel/main.cpp`\n"
        "<<<<\n"
        "foo\n"
        "====\n"
        "bar\n"
        ">>>>\n"
        "***END\n";
    preview = local_edit::preview_apply_blocks(messy);
    if (!expect(preview.count == 1, "messy count") ||
        !expect(preview.first_path == "godbrain_core\\cpp_kernel\\main.cpp",
                "messy path strips ticks and slashes")) {
        return 1;
    }

    preview = local_edit::preview_apply_blocks("no blocks here");
    if (!expect(preview.count == 0, "empty text has no blocks")) {
        return 1;
    }

    preview = local_edit::preview_apply_blocks(
        "*** APPLY\npath: Start-GodBrain.ps1\nno markers\n*** END\n");
    if (!expect(preview.count == 0, "missing <<<< is not a hunk")) {
        return 1;
    }

    if (!expect(local_edit::looks_like_edit_request("/edit Start-GodBrain.ps1 add a log"),
                "/edit is an edit") ||
        !expect(!local_edit::looks_like_edit_request("what is the hostname"),
                "chat is not an edit")) {
        return 1;
    }

    if (!expect(local_edit::check_profile_for("scripts\\Show-SystemFlex.ps1") ==
                    "powershell-parse-v1",
                "ps1 profile") ||
        !expect(local_edit::check_profile_for("godbrain_core/cpp_kernel/main.cpp") ==
                    "kernel-file-v1",
                "kernel profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\memory_store\\store.go") ==
                    "memory-store-go-v1",
                "go profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\frontend\\galaxy.html") ==
                    "galaxy-html-static-v1",
                "galaxy profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\cpp_tools\\librarian.cpp") ==
                    "librarian-self-test-v1",
                "librarian profile") ||
        !expect(local_edit::check_profile_for("docs\\architecture\\current.md") ==
                    "local-edit-apply-v1",
                "md stays apply-only")) {
        return 1;
    }

    char exe[MAX_PATH] = {};
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    std::string dir(exe);
    const size_t slash = dir.find_last_of("\\/");
    if (slash != std::string::npos) dir.resize(slash);
    const std::string fixture = dir + "\\local_edit_fixture.txt";
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    const std::string apply =
        "*** APPLY\n"
        "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
        "<<<<\n"
        "EDIT_FIXTURE=old\n"
        "====\n"
        "EDIT_FIXTURE=new\n"
        ">>>>\n"
        "*** END\n";
    auto result = local_edit::maybe_apply(
        "/edit godbrain_core/cpp_kernel/local_edit_fixture.txt flip marker",
        apply,
        {});
    std::string body;
    {
        std::ifstream in(fixture, std::ios::binary);
        body.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    }
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(result.attempted, "apply attempted") ||
        !expect(result.applied, "apply wrote") ||
        !expect(body == "EDIT_FIXTURE=new\n", "fixture became new")) {
        std::cerr << "report=" << result.report << " body=" << body << std::endl;
        return 1;
    }

    std::cout << "local_edit_test ok" << std::endl;
    return 0;
}
