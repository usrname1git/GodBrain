#pragma once

#include "json.hpp"
#include <string>

using json = nlohmann::json;

namespace memory {
    json save_thought(const json& payload);
    json get_recent(int limit);
}