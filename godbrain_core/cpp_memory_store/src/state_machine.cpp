#include "godbrain/memory_store/state_machine.hpp"

namespace godbrain::memory {

bool allowed_run_transition(const std::string& from, const std::string& to) {
    if (from == kRunStaging) return to == kRunValidated || to == kRunFailed;
    if (from == kRunValidated) return to == kRunCommitted || to == kRunFailed;
    return false;
}

}  // namespace godbrain::memory
