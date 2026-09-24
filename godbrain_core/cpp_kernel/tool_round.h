#pragma once

#include <cctype>
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

inline std::string fix_lower(const std::string& text) {
    std::string out = text;
    for (char& ch : out) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return out;
}

inline bool fix_has_word(const std::string& hay, const char* word) {
    const std::string needle(word);
    std::size_t pos = 0;
    while ((pos = hay.find(needle, pos)) != std::string::npos) {
        const bool left = pos == 0 ||
                          std::isalnum(static_cast<unsigned char>(hay[pos - 1])) == 0;
        const std::size_t end = pos + needle.size();
        const bool right = end >= hay.size() ||
                           std::isalnum(static_cast<unsigned char>(hay[end])) == 0;
        if (left && right) return true;
        pos += needle.size();
    }
    return false;
}

// A pasted crash plus the word fix. Not a Jarvis-need ask, not "No tools."
inline bool looks_like_fix_job(const std::string& msg) {
    const std::string t = fix_lower(msg);
    if (t.size() >= 8 && t.compare(0, 8, "no tools") == 0) return false;
    if (fix_has_word(t, "jarvis")) return false;
    if (t.find("still need") != std::string::npos) return false;
    if (t.find("what do you need") != std::string::npos) return false;
    if (!fix_has_word(t, "fix")) return false;
    return t.find("panic") != std::string::npos ||
           t.find("traceback") != std::string::npos ||
           t.find("stack trace") != std::string::npos ||
           t.find("fatal") != std::string::npos ||
           t.find("exception") != std::string::npos ||
           t.find("segfault") != std::string::npos ||
           t.find("segmentation") != std::string::npos ||
           t.find("error") != std::string::npos ||
           t.find("assert") != std::string::npos ||
           t.find("exit status") != std::string::npos ||
           fix_has_word(t, "crash");
}

// True after a failed run (exit!=0) and a later run that stayed up (exit=0).
inline bool fix_test_stayed_up(const std::string& ledger) {
    int last = -1;
    bool saw_fail = false;
    bool last_timeout = false;
    std::size_t pos = 0;
    while ((pos = ledger.find("exit=", pos)) != std::string::npos) {
        std::size_t i = pos + 5;
        if (i >= ledger.size() ||
            std::isdigit(static_cast<unsigned char>(ledger[i])) == 0) {
            pos += 5;
            continue;
        }
        int val = 0;
        while (i < ledger.size() &&
               std::isdigit(static_cast<unsigned char>(ledger[i])) != 0) {
            val = val * 10 + (ledger[i] - '0');
            ++i;
        }
        if (last > 0) saw_fail = true;
        last = val;
        const std::size_t line_end = ledger.find('\n', pos);
        const std::string line = ledger.substr(
            pos, line_end == std::string::npos ? std::string::npos : line_end - pos);
        last_timeout = line.find("timeout=1") != std::string::npos;
        pos = i;
    }
    return last == 0 && saw_fail && !last_timeout;
}

inline std::string flatten_continue_prompt(const std::string& ledger,
                                           bool speak_only,
                                           bool fix_job = false) {
    std::string out = "TOOL_RESULT\n";
    out += ledger;
    if (fix_job) {
        const bool stayed = fix_test_stayed_up(ledger);
        if (speak_only || stayed) {
            out += stayed ? "\nThe crash test stayed up. "
                          : "\nLast round. ";
            out +=
                "Report the path of the build you ran and what changed. "
                "Do not call tools. Do not start a new project. "
                "Do not open a PR.";
        } else {
            out +=
                "\nOne fix only. Stay on the pasted crash. Read the site, "
                "write a small repro, run it, change the code, run once more. "
                "When the test stays up, stop and report the path. "
                "Do not invent a new project. Do not open a PR.";
        }
        return out;
    }
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
