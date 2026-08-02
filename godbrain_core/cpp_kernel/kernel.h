#pragma once

#include <string>
#include <vector>
#include <map>
#include "json.hpp" // We assume nlohmann::json is available, as it was in cpp_router

using json = nlohmann::json;

class GodBrainKernel {
private:
    std::map<std::string, std::string> system_state;

    bool validate_sovereignty(const std::string& command_type, const json& payload);

public:
    GodBrainKernel();
    
    // Dispatches a command and returns a JSON response
    json dispatch(const std::string& command_type, const json& payload);
};