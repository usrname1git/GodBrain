#include "memory.h"
#include <iostream>

namespace memory {
    // Temporary stubs representing the Go Engine interop
    json save_thought(const json& payload) {
        std::cout << "[MEMORY] Routing thought to Go Engine: " << payload.value("content", "empty") << std::endl;
        return {
            {"status", "success"},
            {"memory_id", "stub-1234"}
        };
    }

    json get_recent(int limit) {
        std::cout << "[MEMORY] Fetching recent thoughts (limit " << limit << ")" << std::endl;
        return {
            {"status", "success"},
            {"thoughts", json::array()}
        };
    }
}