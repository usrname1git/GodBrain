#pragma once

#include "godbrain/memory_store/protocol.hpp"
#include <cstdint>
#include <string>

struct _mongoc_client_t;

namespace godbrain::memory {
constexpr std::int64_t kEvidenceLeaseMs = 120000;
constexpr std::int64_t kDocumentTtlMs = 86400000;
constexpr std::int64_t kHostTtlMs = 900000;
constexpr int kEvidenceAttempts = 6;
constexpr const char* kEvidenceVersion = "1.0.0";

std::string evidence_binding(const std::string& node, const std::string& version,
                             const std::string& content);
std::int64_t evidence_backoff(int attempts);
bool evidence_window(const std::string& profile, std::int64_t checked, std::int64_t expires,
                     std::int64_t now);
bool evidence_command(_mongoc_client_t* client, const std::string& db,
                      const EvidenceRequest& request, std::string* receipt, std::string* error);
bool evidence_current(_mongoc_client_t* client, const std::string& db, const std::string& node,
                      const std::string& version, const std::string& content, bool* current,
                      std::string* error);
bool evidence_search_pipeline(_mongoc_client_t* client, const std::string& db,
                              const std::string& filter, const std::string& options,
                              std::string* pipeline, std::string* error);
} // namespace godbrain::memory
