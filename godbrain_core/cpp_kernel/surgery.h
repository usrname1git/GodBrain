#pragma once

#include <string>

namespace surgery {

struct Outcome {
    bool ok = false;
    int exit_code = -1;
    std::string text;
};

Outcome execute_self_command(const std::string& command);

}