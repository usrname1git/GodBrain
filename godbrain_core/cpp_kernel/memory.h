#pragma once

#include "json.hpp"
#include <string>

using json = nlohmann::json;

namespace memory {
    json save_thought(const json& payload);
    json observe_host();
    json promote_claim(const json& payload);
    json stale_mismatched_pins(const std::string& pin, const std::string& reasoning);
    json get_recent(int limit);
    json set_status(const json& payload);
    json session_snapshot(int limit);
    json hydrate_session_from_rag();
    bool render_session_context(std::string& context, std::string& error);
    void note_session(
        const std::string& source_hash,
        const std::string& stable_id,
        const std::string& content,
        const std::string& status = "candidate");
}