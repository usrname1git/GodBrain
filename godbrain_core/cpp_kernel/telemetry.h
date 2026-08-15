#pragma once

#include "json.hpp"

using json = nlohmann::json;

namespace telemetry {
    json get_current_state();
    json get_host_inventory();
    json get_tailscale();
    json get_gpu_memory();
    json plan_colibri_vram();
}