#pragma once

#include <string>

// Native tool rounds: advertise OpenAI tools on every hop except the last.
// The ledger being non-empty does not drop the schema. CUDA IMA is avoided
// by flatten + never sending role:tool, not by a one-shot tools flag.
inline bool tools_schema_on_round(bool native_tools, int tool_round,
                                  int max_tool_rounds) {
    return native_tools && tool_round >= 0 &&
           (tool_round + 1 < max_tool_rounds);
}

// After flattening the current hop, the next generate is speak-only.
inline bool next_round_speak_only(int tool_round, int max_tool_rounds) {
    return tool_round + 2 >= max_tool_rounds;
}

inline std::string flatten_continue_prompt(const std::string& ledger,
                                           bool speak_only) {
    std::string out = "TOOL_RESULT\n";
    out += ledger;
    if (speak_only) {
        out +=
            "\nObserve is done. Answer Z. Do not call tools. Identities hold: "
            "1+2=3, never 4. Do not dump dir. Do not invent a persona file.";
    } else {
        out +=
            "\nObserve is done. Conclude: if you still need a granted "
            "file, call read_local_file with args limit=40. Else answer "
            "Z. Identities hold: 1+2=3, never 4. Do not dump dir. "
            "Do not invent a persona file. Do not say you should read "
            "AGENTS.md without calling the tool.";
    }
    return out;
}
