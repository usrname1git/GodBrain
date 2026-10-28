#pragma once
#include <string>

namespace tool_evidence {
inline bool append(std::string& ledger, std::string& output, bool analysis,
                   std::string& error) {
    constexpr size_t full_limit = 256 * 1024;
    constexpr size_t ordinary_limit = 12000;
    if (analysis) {
        if (output.find("[truncated 256KiB]") != std::string::npos ||
            output.size() > full_limit ||
            ledger.size() + output.size() + (ledger.empty() ? 0 : 1) > full_limit) {
            error = "Error: complete source evidence exceeds the bounded tool "
                    "ledger. Use Desk Ask's Review complete file for "
                    "token-budgeted parts. No partial-file analysis was generated.";
            return false;
        }
    } else if (output.size() > ordinary_limit) {
        output.resize(ordinary_limit);
        output += "\n[truncated tool output; use Review complete file for source review]";
    }
    if (!ledger.empty()) ledger += "\n";
    ledger += output;
    if (!analysis && ledger.size() > ordinary_limit) {
        ledger.resize(ordinary_limit);
        ledger += "\n[truncated tool ledger; use Review complete file for source review]";
    }
    return true;
}
}
