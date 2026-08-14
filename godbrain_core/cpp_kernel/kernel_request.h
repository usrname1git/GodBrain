#pragma once

#include "json.hpp"

inline bool requests_privileged_dispatch(const nlohmann::json& payload) {
    return payload.is_object() && payload.contains("command_type");
}
