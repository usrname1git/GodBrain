#pragma once

#include "godbrain/memory_store/embedding.hpp"

#include <cstdint>
#include <string>

namespace godbrain::memory {

constexpr int kMaxSearchAttempts = 2;

struct SearchHealthSnap {
    bool ready = false;
    std::string mongo = "unavailable";
    std::string active_generation;
    std::string building_generation;
    std::string projection_version;
    std::string projection_schema;
    std::string indexer_version;
    std::string retrieval_mode = "lexical";
    bool semantic_configured = false;
    bool semantic_available = false;
    bool semantic_required = false;
    std::string degradation;
    bool has_embedding = false;
    EmbeddingIdentity embedding;
    int64_t committed_runs = 0;
    int64_t committed_nodes = 0;
    int64_t committed_links = 0;
    int64_t projected_nodes = 0;
    int64_t projected_links = 0;
    int64_t projected_embeddings = 0;
    bool latest_committed = false;
    bool latest_projected = false;
    bool latest_embedded = false;
    int64_t committed_at = 0;
    int64_t projected_at = 0;
    int64_t embedded_at = 0;
};

enum class BeforeSearch { Proceed, Unready, SemanticUnavailable };
enum class AfterSearch { Accept, Retry };

BeforeSearch search_before_gate(const SearchHealthSnap& before, const std::string& requested_mode);

bool same_search_snapshot(
    const SearchHealthSnap& before,
    const SearchHealthSnap& after,
    const std::string& retrieval,
    bool hybrid,
    const std::string& degradation,
    const EmbeddingIdentity* response_embedding);

AfterSearch search_after_gate(
    const SearchHealthSnap& before,
    const SearchHealthSnap& after,
    const std::string& retrieval,
    bool hybrid,
    const std::string& degradation,
    const EmbeddingIdentity* response_embedding);

int run_snapshot_self_test();

}  // namespace godbrain::memory
