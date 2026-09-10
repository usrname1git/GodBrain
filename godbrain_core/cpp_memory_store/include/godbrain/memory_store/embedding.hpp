#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace godbrain::memory {

constexpr const char* kEmbeddingSchemaVersion = "golden-record-embedding-v1";
constexpr const char* kEmbeddingIndexerVersion = "normalized-input-v1";
constexpr const char* kVectorBackendVersion = "mongodb-bounded-exact-cosine-v1";
constexpr int kMaxEmbeddingDimension = 4096;
constexpr int kMaxEmbeddingInputBytes = 16 * 1024;
constexpr int kMaxEmbeddingRequestBytes = 24 * 1024;
constexpr int kMaxEmbeddingResponseBytes = 1024 * 1024;

struct EmbeddingIdentity {
    std::string provider_kind;
    std::string model_identifier;
    std::string model_revision;
    std::string model_hash;
    int dimension = 0;
    std::string schema_version;
    std::string indexer_version;
    std::string vector_backend;
};

struct EmbeddingRuntime {
    bool configured = false;
    bool required = false;
    EmbeddingIdentity identity;
    std::string endpoint;
    std::string model;
};

bool embedding_identity_valid(const EmbeddingIdentity& id, std::string* err);
bool embedding_identity_equal(const EmbeddingIdentity& a, const EmbeddingIdentity& b);
EmbeddingIdentity embedding_fake_identity(int dimension);

bool embedding_runtime_from_env(EmbeddingRuntime* out, std::string* err);
bool embedding_endpoint_canonical(
    const std::string& raw, std::string* canonical, std::string* host, uint16_t* port, std::string* err);

bool normalize_embedding_input(
    const std::string& input, std::string* normalized, std::string* input_hash, std::string* err);
bool valid_embedding_vector(const std::vector<float>& vector, int dimension);
bool embedding_cosine(const std::vector<float>& left, const std::vector<float>& right, double* out);
bool embedding_embed(
    const EmbeddingRuntime& runtime, const std::string& content, std::vector<float>* vector, std::string* err);
bool embedding_embed_fake(int dimension, const std::string& content, std::vector<float>* vector, std::string* err);
bool sha256_hex(const std::string& bytes, std::string* hex, std::string* err);

int run_embedding_self_test();

}  // namespace godbrain::memory
