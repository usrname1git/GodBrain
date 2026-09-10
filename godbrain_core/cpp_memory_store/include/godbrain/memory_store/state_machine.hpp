#pragma once

#include <string>

namespace godbrain::memory {

constexpr const char* kRunStaging = "staging";
constexpr const char* kRunValidated = "validated";
constexpr const char* kRunCommitted = "committed";
constexpr const char* kRunFailed = "failed";

// Ingestion DAG only. committed never returns to failed.
bool allowed_run_transition(const std::string& from, const std::string& to);

}  // namespace godbrain::memory
