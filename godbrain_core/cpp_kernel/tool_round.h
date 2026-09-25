#pragma once

#include <cctype>
#include <cstdlib>
#include <string>
#include <vector>

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
    if (fix_has_word(t, "panic") || fix_has_word(t, "traceback") ||
        fix_has_word(t, "segfault") || fix_has_word(t, "crash")) {
        return true;
    }
    if (t.find("exit status") != std::string::npos ||
        t.find("stack trace") != std::string::npos ||
        t.find("fatal error") != std::string::npos ||
        t.find("segmentation fault") != std::string::npos ||
        t.find("assertion failed") != std::string::npos ||
        t.find("exception:") != std::string::npos) {
        return true;
    }
    std::size_t at = 0;
    while (at < t.size()) {
        while (at < t.size() && (t[at] == ' ' || t[at] == '\t')) ++at;
        if (t.compare(at, 6, "error:") == 0) return true;
        const std::size_t nl = t.find('\n', at);
        if (nl == std::string::npos) break;
        at = nl + 1;
    }
    return false;
}

// A runner header from local_tools, not an exit= buried in stdout.
inline bool fix_runner_header(const std::string& line) {
    return line.rfind("run_pwsh", 0) == 0 || line.rfind("run_python", 0) == 0 ||
           line.rfind("run_node", 0) == 0;
}

// True when the same script file failed and a later run of that file exited 0.
// Inline bodies share one header, so they do not end the job early.
inline bool fix_test_stayed_up(const std::string& ledger) {
    struct Run {
        std::string header;
        int code = 1;
        bool timeout = false;
    };
    std::vector<Run> runs;
    std::size_t pos = 0;
    while (pos < ledger.size()) {
        const std::size_t end = ledger.find('\n', pos);
        const std::string line = ledger.substr(
            pos, end == std::string::npos ? std::string::npos : end - pos);
        const std::size_t next = end == std::string::npos ? ledger.size() : end + 1;
        if (fix_runner_header(line) && next < ledger.size()) {
            const std::size_t exit_end = ledger.find('\n', next);
            const std::string exit_line = ledger.substr(
                next, exit_end == std::string::npos ? std::string::npos : exit_end - next);
            if (exit_line.rfind("exit=", 0) == 0) {
                Run run;
                run.header = line;
                run.code = std::atoi(exit_line.c_str() + 5);
                run.timeout = exit_line.find("timeout=1") != std::string::npos;
                runs.push_back(run);
            }
        }
        if (end == std::string::npos) break;
        pos = end + 1;
    }
    for (std::size_t i = 0; i < runs.size(); ++i) {
        const Run& run = runs[i];
        if (run.code != 0 || run.timeout) continue;
        if (run.header.find(" inline") != std::string::npos) continue;
        for (std::size_t j = 0; j < i; ++j) {
            if (runs[j].header == run.header && runs[j].code != 0) return true;
        }
    }
    return false;
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
