#pragma once

#include "json.hpp"

#include <functional>
#include <sstream>
#include <string>

namespace godbrain_coli {

inline void accumulate_tool_calls(nlohmann::json& acc, const nlohmann::json& delta) {
    if (!delta.contains("tool_calls") || !delta["tool_calls"].is_array()) return;
    if (!acc.is_array()) acc = nlohmann::json::array();
    for (const auto& tc : delta["tool_calls"]) {
        int idx = 0;
        if (tc.contains("index") && tc["index"].is_number_integer()) {
            idx = tc["index"].get<int>();
        } else if (tc.contains("index") && tc["index"].is_number()) {
            idx = static_cast<int>(tc["index"].get<double>());
        }
        if (idx < 0) idx = 0;
        while (static_cast<int>(acc.size()) <= idx) {
            acc.push_back({
                {"type", "function"},
                {"function", {{"name", ""}, {"arguments", ""}}},
            });
        }
        auto& slot = acc[idx];
        if (tc.contains("id") && tc["id"].is_string() &&
            !tc["id"].get<std::string>().empty()) {
            slot["id"] = tc["id"];
        }
        if (tc.contains("type") && tc["type"].is_string()) {
            slot["type"] = tc["type"];
        }
        if (tc.contains("function") && tc["function"].is_object()) {
            const auto& fn = tc["function"];
            if (fn.contains("name") && fn["name"].is_string() &&
                !fn["name"].get<std::string>().empty()) {
                slot["function"]["name"] = fn["name"];
            }
            if (fn.contains("arguments")) {
                if (fn["arguments"].is_string()) {
                    slot["function"]["arguments"] =
                        slot["function"].value("arguments", std::string()) +
                        fn["arguments"].get<std::string>();
                } else if (!fn["arguments"].is_null()) {
                    slot["function"]["arguments"] = fn["arguments"].dump();
                }
            }
        }
    }
}

inline void handle_sse_event(
    const std::string& event,
    std::string& assembled,
    const std::function<void(const std::string&)>& on_token,
    const std::function<void()>& on_ping,
    const std::function<void(const std::string&)>& on_finish = {},
    std::string* spoken = nullptr,
    nlohmann::json* tool_calls = nullptr) {
    std::istringstream lines(event);
    std::string line;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, 6, "data: ") != 0) continue;
        const std::string payload = line.substr(6);
        if (payload == "[DONE]") return;
        try {
            const nlohmann::json parsed = nlohmann::json::parse(payload);
            if (!parsed.contains("choices") || !parsed["choices"].is_array() ||
                parsed["choices"].empty()) {
                continue;
            }
            const auto& choice = parsed["choices"].at(0);
            if (choice.contains("finish_reason") &&
                choice["finish_reason"].is_string()) {
                const std::string reason =
                    choice["finish_reason"].get<std::string>();
                if (!reason.empty() && on_finish) on_finish(reason);
            }
            const nlohmann::json delta =
                choice.value("delta", nlohmann::json::object());
            std::string token;
            std::string spoken_token;
            if (delta.contains("content") && delta["content"].is_string()) {
                spoken_token = delta["content"].get<std::string>();
                token = spoken_token;
            }
            // Stream think so Galaxy can show it. Do not treat it as the
            // spoken answer: that would fill next-turn KV with the outline.
            if (token.empty() && delta.contains("reasoning_content") &&
                delta["reasoning_content"].is_string()) {
                token = delta["reasoning_content"].get<std::string>();
            }
            if (tool_calls) {
                accumulate_tool_calls(*tool_calls, delta);
                if (choice.contains("message") &&
                    choice["message"].is_object() &&
                    (!tool_calls->is_array() || tool_calls->empty())) {
                    accumulate_tool_calls(*tool_calls, choice["message"]);
                }
            }
            if (token.empty() && !delta.contains("content") &&
                !delta.contains("reasoning_content")) {
                continue;
            }
            if (token.empty()) {
                if (on_ping) on_ping();
            } else {
                assembled += token;
                if (spoken && !spoken_token.empty()) *spoken += spoken_token;
                if (on_token) on_token(token);
            }
        } catch (const nlohmann::json::exception&) {
        }
    }
}

inline void feed_sse(
    std::string& buf,
    const char* data,
    size_t len,
    std::string& assembled,
    const std::function<void(const std::string&)>& on_token,
    const std::function<void()>& on_ping,
    const std::function<void(const std::string&)>& on_finish = {},
    std::string* spoken = nullptr,
    nlohmann::json* tool_calls = nullptr) {
    buf.append(data, len);
    for (;;) {
        const auto pos = buf.find("\n\n");
        if (pos == std::string::npos) break;
        const std::string event = buf.substr(0, pos);
        buf.erase(0, pos + 2);
        handle_sse_event(
            event, assembled, on_token, on_ping, on_finish, spoken, tool_calls);
    }
}

}  // namespace godbrain_coli
