#pragma once

#include <cctype>
#include <string>

// Whole-message desk command. Typing this in Galaxy must not reach the mouth.
inline std::string thinking_cmd_compact(const std::string& msg) {
    size_t a = 0;
    size_t b = msg.size();
    while (a < b && std::isspace(static_cast<unsigned char>(msg[a])) != 0) {
        ++a;
    }
    while (b > a && std::isspace(static_cast<unsigned char>(msg[b - 1])) != 0) {
        --b;
    }
    std::string out;
    out.reserve(b - a);
    for (size_t i = a; i < b; ++i) {
        const unsigned char c = static_cast<unsigned char>(msg[i]);
        if (std::isspace(c) != 0) continue;
        out.push_back(static_cast<char>(std::tolower(c)));
    }
    return out;
}

// -1 not a command, 0 off, 1 on
inline int parse_thinking_command(const std::string& msg) {
    const std::string c = thinking_cmd_compact(msg);
    if (c == "enable_thinking:false") return 0;
    if (c == "enable_thinking:true") return 1;
    return -1;
}
