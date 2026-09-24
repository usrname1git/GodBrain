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

    if (!expect(looks_like_fix_job(
                    "panic: nil pointer dereference\n\nfix"),
                "crash plus fix is a fix job") ||
        !expect(!looks_like_fix_job("No tools. What is 2+2?"),
                "no-tools is not a fix job") ||
        !expect(!looks_like_fix_job(
                    "what else do you still need to be Jarvis"),
                "jarvis need is not a fix job") ||
        !expect(!looks_like_fix_job("the prefix is fine"),
                "prefix is not the word fix") ||
        !expect(tools_schema_on_round(true, 0, 8), "fix round 0 has tools") ||
        !expect(tools_schema_on_round(true, 6, 8), "fix round 6 has tools") ||
        !expect(!tools_schema_on_round(true, 7, 8), "fix last round talks")) {
        return 1;
    }

    const std::string crashed = "run_pwsh inline\nexit=1 timeout=0\n";
    const std::string stayed = crashed + "run_pwsh inline\nexit=0 timeout=0\n";
    if (!expect(!fix_test_stayed_up(crashed), "a crash is not stayed up") ||
        !expect(!fix_test_stayed_up("run_pwsh inline\nexit=0 timeout=0\n"),
                "a pass with no earlier crash does not end the job") ||
        !expect(fix_test_stayed_up(stayed), "pass after crash stayed up") ||
        !expect(!fix_test_stayed_up(stayed + "exit=2 timeout=0\n"),
                "a later crash keeps the loop") ||
        !expect(!fix_test_stayed_up(
                    "run_pwsh inline\nexit=1 timeout=0\nexit=0 timeout=1\n"),
                "a timeout is not stayed up")) {
        return 1;
    }

    const std::string fix_mid = flatten_continue_prompt(crashed, false, true);
    const std::string fix_done = flatten_continue_prompt(stayed, false, true);
    if (!expect(fix_mid.find("small repro") != std::string::npos,
                "mid fix asks for a repro") ||
        !expect(fix_mid.find("Do not call tools") == std::string::npos,
                "mid fix still allows tools") ||
        !expect(fix_mid.find("Do not open a PR") != std::string::npos,
                "mid fix refuses a PR") ||
        !expect(fix_done.find("stayed up") != std::string::npos,
                "passing rerun tells the mouth to stop") ||
        !expect(fix_done.find("Do not call tools") != std::string::npos,
                "passing rerun forbids tools") ||
        !expect(fix_done.find("Do not open a PR") != std::string::npos,
                "passing rerun refuses a PR")) {
        return 1;
    }

    std::cout << "tool_round_test ok" << std::endl;
    return 0;
}
