#pragma once

#include <cctype>
#include <string>

// llama.cpp KV death. Cut at the first unused49 token and keep the prefix
// if it is already a sentence. Do not treat a real essay plus junk tags
// as empty, and do not substitute a directory dump as the answer.
namespace unused49 {

inline std::string ascii_lower(std::string s) {
    for (char& ch : s) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return s;
}

inline std::string trim_copy(const std::string& s) {
    size_t a = 0;
    size_t b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a])) != 0) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1])) != 0) --b;
    return s.substr(a, b - a);
}

inline size_t find_token(const std::string& text) {
    const std::string t = ascii_lower(text);
    const size_t tagged = t.find("<unused49>");
    const size_t bare = t.find("unused49");
    if (tagged == std::string::npos) return bare;
    if (bare == std::string::npos) return tagged;
    return tagged < bare ? tagged : bare;
}

inline bool contains(const std::string& text) {
    return find_token(text) != std::string::npos;
}

inline std::string strip_tail(std::string text) {
    const size_t at = find_token(text);
    if (at == std::string::npos) return trim_copy(text);
    return trim_copy(text.substr(0, at));
}

inline size_t keep_count(const std::string& text) {
    size_t n = 0;
    for (unsigned char c : text) {
        if (std::isspace(c) != 0 || c == '<' || c == '>') continue;
        ++n;
    }
    return n;
}

inline bool is_junk(const std::string& text) {
    if (!contains(text)) return false;
    return keep_count(strip_tail(text)) < 24;
}

inline bool keep_prefix(const std::string& text) {
    return contains(text) && !is_junk(text);
}

}  // namespace unused49
