#pragma once

#include "json.hpp"

using json = nlohmann::json;

namespace telemetry {
    json get_current_state();
    json get_host_inventory();
}