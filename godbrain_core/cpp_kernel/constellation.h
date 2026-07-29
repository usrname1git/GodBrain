#pragma once

#include "json.hpp"
#include <string>

using json = nlohmann::json;

namespace constellation {
    // Represents GodBrain's "Spatial Memory Map"
    json load_map();
    json query(const json& payload);
}