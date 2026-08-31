#include <iostream>

#include "tool_round.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    // Non-YOLO cap 3: hops 0 and 1 keep tools, hop 2 is speak-only.
    if (!expect(tools_schema_on_round(true, 0, 3), "round 0 tools on") ||
        !expect(tools_schema_on_round(true, 1, 3),
                "round 1 tools still on after ledger") ||
        !expect(!tools_schema_on_round(true, 2, 3), "round 2 speak-only") ||
        !expect(!next_round_speak_only(0, 3), "after hop 1 next still tools") ||
        !expect(next_round_speak_only(1, 3), "after hop 2 next is speak-only")) {
        return 1;
    }

    // YOLO cap 8: last round only is speak-only.
    if (!expect(tools_schema_on_round(true, 6, 8), "yolo hop 7 still tools") ||
        !expect(!tools_schema_on_round(true, 7, 8), "yolo last speak-only") ||
        !expect(next_round_speak_only(6, 8), "yolo flatten before last")) {
        return 1;
    }

    if (!expect(!tools_schema_on_round(false, 0, 1), "no native tools") ||
        !expect(!tools_schema_on_round(true, 0, 1),
                "cap 1 is speak-only immediately")) {
        return 1;
    }

    const std::string ledger = "list_local_dir ok\nAGENTS.md";
    const std::string hop = flatten_continue_prompt(ledger, false);
    const std::string last = flatten_continue_prompt(ledger, true);
    if (!expect(hop.find("TOOL_RESULT") == 0, "hop starts TOOL_RESULT") ||
        !expect(hop.find("read_local_file") != std::string::npos,
                "mid hop may read") ||
        !expect(hop.find("Do not call tools") == std::string::npos,
                "mid hop does not forbid tools") ||
        !expect(last.find("read_local_file") == std::string::npos,
                "last hop does not ask for a read") ||
        !expect(last.find("Do not call tools") != std::string::npos,
                "last hop forbids tools") ||
        !expect(last.find(ledger) != std::string::npos, "last keeps ledger")) {
        return 1;
    }

    std::cout << "tool_round_test ok" << std::endl;
    return 0;
}
