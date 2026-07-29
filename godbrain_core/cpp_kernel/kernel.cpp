#include "kernel.h"
#include <iostream>
#include "surgery.h"
#include "telemetry.h"
#include "constellation.h"
#include "memory.h"

GodBrainKernel::GodBrainKernel() {
    // Initialize constellation map or other state
    constellation_map = constellation::load_map();
}

bool GodBrainKernel::validate_sovereignty(const std::string& command_type, const json& payload) {
    if (command_type == "execute_godbrain_script" || command_type == "propose_sovereign_architect_change") {
        if (!payload.contains("reasoning")) {
            std::cout << "[KERNEL SECURITY] High risk command rejected: No reasoning provided." << std::endl;
            return false;
        }
    }
    return true;
}

json GodBrainKernel::dispatch(const std::string& command_type, const json& payload) {
    std::cout << "[KERNEL] Intercepting Command: " << command_type << std::endl;

    if (!validate_sovereignty(command_type, payload)) {
        return {{"status", "error"}, {"message", "Sovereignty check failed: Action exceeds current authority or lacks reasoning."}};
    }

    try {
        json result;
        if (command_type == "execute_godbrain_script") {
            result = surgery::execute_self_command(payload.value("command", ""));
        } else if (command_type == "save_godbrain_thought") {
            result = memory::save_thought(payload);
        } else if (command_type == "query_recent_thoughts") {
            result = memory::get_recent(payload.value("limit", 5));
        } else if (command_type == "query_constellation") {
            result = constellation::query(payload);
        } else if (command_type == "get_system_telemetry") {
            result = telemetry::get_current_state();
        } else if (command_type == "propose_sovereign_architect_change") {
            result = surgery::execute_self_command(payload.value("proposal_script", ""));
        } else {
            return {{"status", "error"}, {"message", "Unknown command: " + command_type}};
        }

        return {{"status", "success"}, {"data", result}};
    } catch (const std::exception& e) {
        std::cout << "[KERNEL ERROR] " << e.what() << std::endl;
        return {{"status", "error"}, {"message", e.what()}};
    }
}
