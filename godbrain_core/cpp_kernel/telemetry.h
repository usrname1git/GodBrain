#pragma once

#include "json.hpp"
#include <string>

using json = nlohmann::json;

namespace telemetry {
    json get_current_state();
    json get_host_inventory();
    json get_tailscale();
    // True when 127.0.0.1:port accepts TCP within timeout_ms. Does not speak a protocol.
    bool tcp_loopback_open(int port, int timeout_ms);
    json get_gpu_memory();
    json plan_colibri_vram();
    // EditionID/CurrentBuild.UBR, e.g. IoTEnterpriseS/26100.8037
    std::string windows_pin();
}