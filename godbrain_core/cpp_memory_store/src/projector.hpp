#pragma once

#include "godbrain/memory_store/embedding.hpp"

#include <mongoc/mongoc.h>

#include <cstdint>
#include <string>

namespace godbrain::memory {

bool ensure_rag_indexes(mongoc_client_t* client, const std::string& db_name, std::string* err);
bool project_committed_run(
    mongoc_client_t* client, const std::string& db_name, const std::string& run_id, std::string* err);
bool sync_projected_node_status(
    mongoc_client_t* client,
    const std::string& db_name,
    const bson_oid_t& node_id,
    const std::string& status,
    std::string* err);

struct RagRebuildReport {
    std::string generation;
    std::string previous_generation;
    int64_t committed_runs = 0;
    int64_t committed_nodes = 0;
    int64_t committed_links = 0;
    int64_t projected_nodes = 0;
    int64_t projected_links = 0;
    int64_t projected_embeddings = 0;
    std::string started_at;
    std::string completed_at;
};

std::string rag_rebuild_report_json(const RagRebuildReport& r);
bool rebuild_rag_projection(
    mongoc_client_t* client, const std::string& db_name, RagRebuildReport* report, std::string* err);

struct RagCorpusCounts {
    int64_t committed_runs = 0;
    int64_t committed_nodes = 0;
    int64_t committed_links = 0;
    int64_t projected_nodes = 0;
    int64_t projected_links = 0;
    int64_t projected_embeddings = 0;
};

struct RagMetadataView {
    std::string active_generation;
    std::string building_generation;
    std::string projection_version;
    std::string projection_schema;
    std::string indexer_version;
    bool has_embedding = false;
    EmbeddingIdentity embedding;
};

bool rag_read_metadata(
    mongoc_client_t* client, const std::string& db_name, RagMetadataView* out, std::string* err);
bool rag_corpus_counts(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const EmbeddingIdentity* embedding,
    RagCorpusCounts* counts,
    std::string* err);
bool rag_latest_time(
    mongoc_client_t* client,
    const std::string& db_name,
    const char* collection,
    const bson_t* filter,
    const char* field,
    int64_t* millis_out,
    bool* found,
    std::string* err);

}  // namespace godbrain::memory

