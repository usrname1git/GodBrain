#pragma once

#include "json.hpp"

#include <functional>
#include <sstream>
#include <string>

namespace godbrain_coli {

inline void handle_sse_event(
    const std::string& event,
    std::string& assembled,
    const std::function<void(const std::string&)>& on_token,
    const std::function<void()>& on_ping) {
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
            const nlohmann::json delta =
                parsed["choices"].at(0).value("delta", nlohmann::json::object());
            if (!delta.contains("content") || !delta["content"].is_string()) {
                continue;
            }
            const std::string token = delta["content"].get<std::string>();
            if (token.empty()) {
                if (on_ping) on_ping();
            } else {
                assembled += token;
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
    const std::function<void()>& on_ping) {
    buf.append(data, len);
    for (;;) {
        const auto pos = buf.find("\n\n");
        if (pos == std::string::npos) break;
        const std::string event = buf.substr(0, pos);
        buf.erase(0, pos + 2);
        handle_sse_event(event, assembled, on_token, on_ping);
    }
}

}  // namespace godbrain_coli
