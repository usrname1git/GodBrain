#pragma once

#include "json.hpp"
#include <string>

using json = nlohmann::json;

namespace memory {
    json save_thought(const json& payload);
    json observe_host();
    json get_recent(int limit);
    json set_status(const json& payload);
    json session_snapshot(int limit);
    bool render_session_context(std::string& context, std::string& error);
}