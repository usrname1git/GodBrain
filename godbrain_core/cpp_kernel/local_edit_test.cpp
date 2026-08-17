#include <iostream>
#include <string>

#include "local_edit.h"

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

    std::cout << "local_edit_test ok" << std::endl;
    return 0;
}
