#pragma once

#include <cctype>
#include <filesystem>
#include <fstream>
#include <string>
#include "json.hpp"

struct ThinkingPreference {
    bool enabled = true;
    std::string effort;
    std::string error;
};

inline ThinkingPreference parse_thinking_preference(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    const auto last = value.find_last_not_of(" \t\r\n");
    value = first == std::string::npos ? "" : value.substr(first, last - first + 1);
    for (auto& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (value == "on" || value == "true" || value == "1") return {};
    if (value == "off" || value == "false" || value == "0") return {false, "", ""};
    if (value == "low" || value == "medium" || value == "xhigh") return {true, value, ""};
    return {false, "", "Invalid logs\\thinking.txt; select Default, Off, Low, Medium or High in the Desk."};
}

inline ThinkingPreference read_thinking_preference(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::error_code error;
        if (!std::filesystem::exists(path, error) && !error) return {};
        return {false, "", "Could not read logs\\thinking.txt."};
    }
    std::string value;
    char c;
    while (in.get(c)) {
        value.push_back(c);
        if (value.size() > 64) return {false, "", "logs\\thinking.txt exceeds 64 bytes."};
    }
    if (!in.eof()) return {false, "", "Could not read logs\\thinking.txt."};
    return parse_thinking_preference(value);
}

inline bool configure_thinking_request(
    nlohmann::json& body, const ThinkingPreference& preference, bool force_off,
    const nlohmann::json& models, std::string& error) {
    body.erase("reasoning_effort");
    if (!force_off && !preference.error.empty()) {
        error = preference.error;
        return false;
    }
    body["chat_template_kwargs"] = {{"enable_thinking", !force_off && preference.enabled}};
    if (force_off || !preference.enabled || preference.effort.empty()) return true;
    bool supported = false;
    size_t matching_models = 0;
    if (models.is_object() && models.contains("data") && models["data"].is_array()) {
        for (const auto& model : models["data"]) {
            if (!model.is_object() || !model.contains("id") || model["id"] != body["model"]) continue;
            ++matching_models;
            if (!model.contains("supported_reasoning_efforts") ||
                !model["supported_reasoning_efforts"].is_array()) continue;
            for (const auto& effort : model["supported_reasoning_efforts"]) {
                if (effort.is_string() && effort == preference.effort) supported = true;
            }
        }
    }
    if (!supported || matching_models != 1) {
        error = "The running model does not advertise reasoning effort " + preference.effort +
                ". Select Default or Off in the Desk; no reasoning generation was sent.";
        return false;
    }
    body["reasoning_effort"] = preference.effort;
    return true;
}

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
