#pragma once

#include <string>

namespace godbrain_pin {

inline bool has_mismatched_os_pin(const std::string& content, const std::string& pin) {
    size_t position = 0;
    while ((position = content.find("os_pin=", position)) != std::string::npos) {
        position += 7;
        const size_t end = content.find_first_of(" \t\r\n\f\v", position);
        const std::string value = content.substr(
            position, end == std::string::npos ? std::string::npos : end - position);
        if (value != pin) return true;
    }
    return false;
}

}
