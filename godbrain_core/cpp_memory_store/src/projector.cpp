#include "projector.hpp"
#include "godbrain/memory_store/embedding.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <rpc.h>
#pragma comment(lib, "rpcrt4.lib")
#endif

namespace godbrain::memory {
namespace {

constexpr const char* kDocuments = "rag_documents";
constexpr const char* kProvenance = "rag_provenance";
constexpr const char* kEmbeddings = "rag_embeddings";
constexpr const char* kMetadata = "rag_metadata";
constexpr const char* kMetadataID = "canonical";
constexpr const char* kProjectionVersion = "hybrid-v1";
constexpr const char* kProjectionSchema = "rag-document-v2";
constexpr const char* kIndexerVersion = "mongodb-text-v1";

std::string projector_uuid() {
#if defined(_WIN32)
    UUID u;
    UuidCreate(&u);
    RPC_CSTR s = nullptr;
    UuidToStringA(&u, &s);
    std::string out(reinterpret_cast<char*>(s));
    RpcStringFreeA(&s);
    return out;
#else
    return "live";
#endif
}

mongoc_collection_t* coll(mongoc_client_t* client, const std::string& db, const char* name) {
    return mongoc_client_get_collection(client, db.c_str(), name);
}

bool bson_fail(const bson_error_t& error, std::string* err, const char* what) {
    if (err) *err = std::string(what) + ": " + error.message;
    return false;
}

bool create_index(
    mongoc_client_t* client,
    const std::string& db,
    const char* name,
    bson_t* keys,
    bson_t* opt,
    std::string* err,
    const char* what) {
    mongoc_collection_t* c = coll(client, db, name);
    mongoc_index_model_t* models[1] = {mongoc_index_model_new(keys, opt)};
    bson_error_t error{};
    bool ok = mongoc_collection_create_indexes_with_opts(c, models, 1, nullptr, nullptr, &error);
    mongoc_index_model_destroy(models[0]);
    mongoc_collection_destroy(c);
    if (!ok && error.code != 85 && error.code != 86) return bson_fail(error, err, what);
    return true;
}

bool iter_utf8(const bson_t* doc, const char* key, std::string* out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key) || !BSON_ITER_HOLDS_UTF8(&it)) return false;
    *out = bson_iter_utf8(&it, nullptr);
    return true;
}

bool iter_oid(const bson_t* doc, const char* key, bson_oid_t* out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key) || !BSON_ITER_HOLDS_OID(&it)) return false;
    *out = *bson_iter_oid(&it);
    return true;
}

int64_t iter_date(const bson_t* doc, const char* key, int64_t fallback) {
    bson_iter_t it;
    if (bson_iter_init_find(&it, doc, key) && BSON_ITER_HOLDS_DATE_TIME(&it)) {
        return bson_iter_date_time(&it);
    }
    return fallback;
}

double iter_double(const bson_t* doc, const char* key, double fallback) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return fallback;
    if (BSON_ITER_HOLDS_DOUBLE(&it)) return bson_iter_double(&it);
    if (BSON_ITER_HOLDS_INT32(&it)) return static_cast<double>(bson_iter_int32(&it));
    if (BSON_ITER_HOLDS_INT64(&it)) return static_cast<double>(bson_iter_int64(&it));
    return fallback;
}

void append_array_field(bson_t* dst, const char* key, const bson_t* src, const char* src_key) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, src, src_key) || !BSON_ITER_HOLDS_ARRAY(&it)) return;
    uint32_t len = 0;
    const uint8_t* data = nullptr;
    bson_iter_array(&it, &len, &data);
    bson_t arr;
    if (bson_init_static(&arr, data, len)) {
        BSON_APPEND_ARRAY(dst, key, &arr);
    }
}

bool identity_from_doc(const bson_t* doc, EmbeddingIdentity* out) {
    if (out == nullptr || doc == nullptr) return false;
    *out = EmbeddingIdentity{};
    iter_utf8(doc, "provider_kind", &out->provider_kind);
    iter_utf8(doc, "model_identifier", &out->model_identifier);
    iter_utf8(doc, "model_revision", &out->model_revision);
    iter_utf8(doc, "model_hash", &out->model_hash);
    iter_utf8(doc, "embedding_schema", &out->schema_version);
    iter_utf8(doc, "indexer_version", &out->indexer_version);
    iter_utf8(doc, "vector_backend", &out->vector_backend);
    bson_iter_t it;
    if (bson_iter_init_find(&it, doc, "dimension")) {
        if (BSON_ITER_HOLDS_INT32(&it)) out->dimension = bson_iter_int32(&it);
        else if (BSON_ITER_HOLDS_INT64(&it)) out->dimension = static_cast<int>(bson_iter_int64(&it));
    }
    return embedding_identity_valid(*out, nullptr);
}

bool identity_from_field(const bson_t* meta, const char* key, EmbeddingIdentity* out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, meta, key) || !BSON_ITER_HOLDS_DOCUMENT(&it)) return false;
    uint32_t len = 0;
    const uint8_t* data = nullptr;
    bson_iter_document(&it, &len, &data);
    bson_t sub;
    if (!bson_init_static(&sub, data, len)) return false;
    return identity_from_doc(&sub, out);
}

void append_identity_fields(bson_t* dst, const EmbeddingIdentity& id) {
    BSON_APPEND_UTF8(dst, "provider_kind", id.provider_kind.c_str());
    BSON_APPEND_UTF8(dst, "model_identifier", id.model_identifier.c_str());
    BSON_APPEND_UTF8(dst, "model_revision", id.model_revision.c_str());
    BSON_APPEND_UTF8(dst, "model_hash", id.model_hash.c_str());
    BSON_APPEND_INT32(dst, "dimension", id.dimension);
    BSON_APPEND_UTF8(dst, "embedding_schema", id.schema_version.c_str());
    BSON_APPEND_UTF8(dst, "indexer_version", id.indexer_version.c_str());
    BSON_APPEND_UTF8(dst, "vector_backend", id.vector_backend.c_str());
}

bool read_cached_vector(const bson_t* doc, int dimension, std::vector<float>* out) {
    bson_iter_t it, sub;
    if (!bson_iter_init_find(&it, doc, "vector") || !BSON_ITER_HOLDS_ARRAY(&it) ||
        !bson_iter_recurse(&it, &sub)) {
        return false;
    }
    std::vector<float> v;
    while (bson_iter_next(&sub)) {
        if (BSON_ITER_HOLDS_DOUBLE(&sub)) v.push_back(static_cast<float>(bson_iter_double(&sub)));
        else if (BSON_ITER_HOLDS_INT32(&sub)) v.push_back(static_cast<float>(bson_iter_int32(&sub)));
        else return false;
    }
    if (!valid_embedding_vector(v, dimension)) return false;
    *out = std::move(v);
    return true;
}

int64_t now_millis() {
    return static_cast<int64_t>(std::time(nullptr)) * 1000;
}

}  // namespace

bool ensure_rag_indexes(mongoc_client_t* client, const std::string& db_name, std::string* err) {
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "status", 1);
        BSON_APPEND_INT32(&keys, "updated_at", -1);
        BSON_APPEND_INT32(&keys, "run_id", 1);
        bson_t* opt = BCON_NEW("name", "committed_run_projection");
        bool ok = create_index(client, db_name, "ingestion_runs", &keys, opt, err, "rag ingestion_runs index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "run_id", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        BSON_APPEND_INT32(&keys, "created_at", 1);
        bson_t* opt = BCON_NEW("name", "rag_run_link_scan");
        bool ok = create_index(client, db_name, "run_node_links", &keys, opt, err, "rag run_node_links index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true), "name", "rag_document_identity");
        bool ok = create_index(client, db_name, kDocuments, &keys, opt, err, "rag_documents identity");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_UTF8(&keys, "content", "text");
        BSON_APPEND_UTF8(&keys, "kind", "text");
        BSON_APPEND_UTF8(&keys, "sector", "text");
        BSON_APPEND_UTF8(&keys, "status", "text");
        bson_t* opt = BCON_NEW(
            "name",
            "rag_lexical_text",
            "default_language",
            "none",
            "weights",
            "{",
            "content",
            BCON_INT32(10),
            "kind",
            BCON_INT32(3),
            "sector",
            BCON_INT32(3),
            "status",
            BCON_INT32(1),
            "}");
        bool ok = create_index(client, db_name, kDocuments, &keys, opt, err, "rag_documents text");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_INT32(&keys, "kind", 1);
        BSON_APPEND_INT32(&keys, "status", 1);
        BSON_APPEND_INT32(&keys, "sector", 1);
        BSON_APPEND_INT32(&keys, "schema_version", 1);
        BSON_APPEND_INT32(&keys, "confidence", -1);
        BSON_APPEND_INT32(&keys, "node_created_at", -1);
        BSON_APPEND_INT32(&keys, "stable_id", 1);
        bson_t* opt = BCON_NEW("name", "rag_metadata_rank");
        bool ok = create_index(client, db_name, kDocuments, &keys, opt, err, "rag_documents rank");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        BSON_APPEND_INT32(&keys, "run_id", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true), "name", "rag_provenance_identity");
        bool ok = create_index(client, db_name, kProvenance, &keys, opt, err, "rag_provenance identity");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_INT32(&keys, "run_id", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        bson_t* opt = BCON_NEW("name", "rag_provenance_run");
        bool ok = create_index(client, db_name, kProvenance, &keys, opt, err, "rag_provenance run");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "generation", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        BSON_APPEND_INT32(&keys, "provider_kind", 1);
        BSON_APPEND_INT32(&keys, "model_identifier", 1);
        BSON_APPEND_INT32(&keys, "model_revision", 1);
        BSON_APPEND_INT32(&keys, "model_hash", 1);
        BSON_APPEND_INT32(&keys, "embedding_schema", 1);
        BSON_APPEND_INT32(&keys, "indexer_version", 1);
        BSON_APPEND_INT32(&keys, "dimension", 1);
        BSON_APPEND_INT32(&keys, "vector_backend", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true), "name", "rag_embedding_identity");
        bool ok = create_index(client, db_name, kEmbeddings, &keys, opt, err, "rag_embeddings identity");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }

    EmbeddingRuntime runtime;
    if (!embedding_runtime_from_env(&runtime, err)) return false;

    mongoc_collection_t* meta = coll(client, db_name, kMetadata);
    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "_id", kMetadataID);
    const std::string generation = std::string("live-") + projector_uuid();
    const int64_t now = now_millis();
    bson_t set_on = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set_on, "active_generation", generation.c_str());
    BSON_APPEND_UTF8(&set_on, "projection_version", kProjectionVersion);
    BSON_APPEND_UTF8(&set_on, "projection_schema", kProjectionSchema);
    BSON_APPEND_UTF8(&set_on, "indexer_version", kIndexerVersion);
    BSON_APPEND_DATE_TIME(&set_on, "active_since", now);
    BSON_APPEND_DATE_TIME(&set_on, "updated_at", now);
    bson_t ident = BSON_INITIALIZER;
    if (runtime.configured) {
        BSON_APPEND_UTF8(&ident, "provider_kind", runtime.identity.provider_kind.c_str());
        BSON_APPEND_UTF8(&ident, "model_identifier", runtime.identity.model_identifier.c_str());
        BSON_APPEND_UTF8(&ident, "model_revision", runtime.identity.model_revision.c_str());
        BSON_APPEND_UTF8(&ident, "model_hash", runtime.identity.model_hash.c_str());
        BSON_APPEND_INT32(&ident, "dimension", runtime.identity.dimension);
        BSON_APPEND_UTF8(&ident, "embedding_schema", runtime.identity.schema_version.c_str());
        BSON_APPEND_UTF8(&ident, "indexer_version", runtime.identity.indexer_version.c_str());
        BSON_APPEND_UTF8(&ident, "vector_backend", runtime.identity.vector_backend.c_str());
        BSON_APPEND_DOCUMENT(&set_on, "embedding", &ident);
    }
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$setOnInsert", &set_on);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_BOOL(&opts, "upsert", true);
    bson_error_t error{};
    bool ok = mongoc_collection_update_one(meta, &filter, &upd, &opts, nullptr, &error);
    bson_destroy(&filter);
    bson_destroy(&ident);
    bson_destroy(&set_on);
    bson_destroy(&upd);
    bson_destroy(&opts);
    mongoc_collection_destroy(meta);
    if (!ok && error.code != 11000) return bson_fail(error, err, "rag_metadata seed");
    return true;
}

static bool load_metadata(
    mongoc_client_t* client, const std::string& db_name, bson_t** out, std::string* err) {
    mongoc_collection_t* meta = coll(client, db_name, kMetadata);
    bson_t q = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&q, "_id", kMetadataID);
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(meta, &q, nullptr, nullptr);
    const bson_t* found = nullptr;
    bool ok = mongoc_cursor_next(cur, &found);
    bson_error_t error{};
    if (mongoc_cursor_error(cur, &error)) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(meta);
        bson_destroy(&q);
        return bson_fail(error, err, "rag_metadata");
    }
    if (!ok || found == nullptr) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(meta);
        bson_destroy(&q);
        if (err) *err = "RAG projection metadata is missing";
        return false;
    }
    *out = bson_copy(found);
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(meta);
    bson_destroy(&q);
    return true;
}

static bool upsert_document(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const bson_t* node,
    int64_t projected_at,
    std::string* err) {
    bson_oid_t node_id{};
    if (!iter_oid(node, "_id", &node_id)) {
        if (err) *err = "knowledge node missing _id";
        return false;
    }
    std::string stable, version, kind, sector, status, schema;
    iter_utf8(node, "stable_id", &stable);
    iter_utf8(node, "version", &version);
    iter_utf8(node, "kind", &kind);
    iter_utf8(node, "sector", &sector);
    iter_utf8(node, "status", &status);
    iter_utf8(node, "schema_version", &schema);
    std::string content;
    iter_utf8(node, "content", &content);

    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "generation", generation.c_str());
    BSON_APPEND_OID(&filter, "node_id", &node_id);
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "generation", generation.c_str());
    BSON_APPEND_OID(&set, "node_id", &node_id);
    BSON_APPEND_UTF8(&set, "stable_id", stable.c_str());
    BSON_APPEND_UTF8(&set, "node_version", version.c_str());
    BSON_APPEND_UTF8(&set, "content", content.c_str());
    BSON_APPEND_UTF8(&set, "kind", kind.c_str());
    BSON_APPEND_UTF8(&set, "sector", sector.c_str());
    BSON_APPEND_UTF8(&set, "status", status.c_str());
    BSON_APPEND_DOUBLE(&set, "confidence", iter_double(node, "confidence", 0));
    BSON_APPEND_UTF8(&set, "schema_version", schema.c_str());
    append_array_field(&set, "evidence_spans", node, "evidence_spans");
    BSON_APPEND_DATE_TIME(&set, "node_created_at", iter_date(node, "created_at", projected_at));
    BSON_APPEND_UTF8(&set, "projection_version", kProjectionVersion);
    BSON_APPEND_UTF8(&set, "projection_schema", kProjectionSchema);
    BSON_APPEND_UTF8(&set, "indexer_version", kIndexerVersion);
    BSON_APPEND_DATE_TIME(&set, "projected_at", projected_at);
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_BOOL(&opts, "upsert", true);
    mongoc_collection_t* c = coll(client, db_name, kDocuments);
    bson_error_t error{};
    bool ok = mongoc_collection_update_one(c, &filter, &upd, &opts, nullptr, &error);
    if (!ok && error.code == 11000) {
        bson_destroy(&opts);
        bson_t no_up = BSON_INITIALIZER;
        ok = mongoc_collection_update_one(c, &filter, &upd, &no_up, nullptr, &error);
        bson_destroy(&no_up);
    } else {
        bson_destroy(&opts);
    }
    bson_destroy(&filter);
    bson_destroy(&set);
    bson_destroy(&upd);
    mongoc_collection_destroy(c);
    if (!ok) return bson_fail(error, err, "rag_documents upsert");
    return true;
}

static bool upsert_provenance(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const bson_t* run,
    const bson_t* link,
    const bson_t* node,
    int64_t projected_at,
    std::string* err) {
    bson_oid_t node_id{};
    if (!iter_oid(node, "_id", &node_id)) {
        if (err) *err = "knowledge node missing _id";
        return false;
    }
    std::string run_id, source_hash, ext, extractor, extractor_ver, schema, stable, version;
    iter_utf8(run, "run_id", &run_id);
    iter_utf8(run, "source_hash", &source_hash);
    iter_utf8(run, "external_source_id", &ext);
    iter_utf8(run, "extractor_id", &extractor);
    iter_utf8(run, "extractor_version", &extractor_ver);
    iter_utf8(run, "schema_version", &schema);
    iter_utf8(node, "stable_id", &stable);
    iter_utf8(node, "version", &version);

    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "generation", generation.c_str());
    BSON_APPEND_OID(&filter, "node_id", &node_id);
    BSON_APPEND_UTF8(&filter, "run_id", run_id.c_str());
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "generation", generation.c_str());
    BSON_APPEND_OID(&set, "node_id", &node_id);
    BSON_APPEND_UTF8(&set, "stable_id", stable.c_str());
    BSON_APPEND_UTF8(&set, "node_version", version.c_str());
    BSON_APPEND_UTF8(&set, "run_id", run_id.c_str());
    bson_oid_t source_oid{};
    if (iter_oid(run, "source_id", &source_oid)) {
        BSON_APPEND_OID(&set, "source_id", &source_oid);
    }
    BSON_APPEND_UTF8(&set, "source_hash", source_hash.c_str());
    BSON_APPEND_UTF8(&set, "external_source_id", ext.c_str());
    BSON_APPEND_UTF8(&set, "extractor_id", extractor.c_str());
    BSON_APPEND_UTF8(&set, "extractor_version", extractor_ver.c_str());
    BSON_APPEND_UTF8(&set, "schema_version", schema.c_str());
    append_array_field(&set, "evidence_spans", link, "evidence_spans");
    BSON_APPEND_DATE_TIME(&set, "committed_at", iter_date(run, "updated_at", projected_at));
    BSON_APPEND_DATE_TIME(&set, "projected_at", projected_at);
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_BOOL(&opts, "upsert", true);
    mongoc_collection_t* c = coll(client, db_name, kProvenance);
    bson_error_t error{};
    bool ok = mongoc_collection_update_one(c, &filter, &upd, &opts, nullptr, &error);
    if (!ok && error.code == 11000) {
        bson_destroy(&opts);
        bson_t no_up = BSON_INITIALIZER;
        ok = mongoc_collection_update_one(c, &filter, &upd, &no_up, nullptr, &error);
        bson_destroy(&no_up);
    } else {
        bson_destroy(&opts);
    }
    bson_destroy(&filter);
    bson_destroy(&set);
    bson_destroy(&upd);
    mongoc_collection_destroy(c);
    if (!ok) return bson_fail(error, err, "rag_provenance upsert");
    return true;
}

static bool project_embedding(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const bson_t* node,
    const EmbeddingIdentity& expected,
    const EmbeddingRuntime& runtime,
    int64_t projected_at,
    std::string* err) {
    if (!runtime.configured || !embedding_identity_equal(runtime.identity, expected)) {
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    bson_oid_t node_id{};
    if (!iter_oid(node, "_id", &node_id)) {
        if (err) *err = "knowledge node missing _id";
        return false;
    }
    std::string content, stable, version;
    iter_utf8(node, "content", &content);
    iter_utf8(node, "stable_id", &stable);
    iter_utf8(node, "version", &version);
    std::string normalized, input_hash;
    if (!normalize_embedding_input(content, &normalized, &input_hash, err)) return false;

    bson_t cache = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&cache, "generation", generation.c_str());
    BSON_APPEND_OID(&cache, "node_id", &node_id);
    append_identity_fields(&cache, expected);
    BSON_APPEND_UTF8(&cache, "input_hash", input_hash.c_str());
    mongoc_collection_t* c = coll(client, db_name, kEmbeddings);
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(c, &cache, nullptr, nullptr);
    const bson_t* found = nullptr;
    if (mongoc_cursor_next(cur, &found)) {
        std::vector<float> cached;
        if (read_cached_vector(found, expected.dimension, &cached)) {
            mongoc_cursor_destroy(cur);
            mongoc_collection_destroy(c);
            bson_destroy(&cache);
            return true;
        }
    }
    mongoc_cursor_destroy(cur);
    bson_destroy(&cache);

    std::vector<float> vector;
    if (!embedding_embed(runtime, content, &vector, err)) {
        mongoc_collection_destroy(c);
        return false;
    }

    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "generation", generation.c_str());
    BSON_APPEND_OID(&filter, "node_id", &node_id);
    append_identity_fields(&filter, expected);
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "generation", generation.c_str());
    BSON_APPEND_OID(&set, "node_id", &node_id);
    BSON_APPEND_UTF8(&set, "stable_id", stable.c_str());
    BSON_APPEND_UTF8(&set, "node_version", version.c_str());
    append_identity_fields(&set, expected);
    BSON_APPEND_UTF8(&set, "input_hash", input_hash.c_str());
    bson_t vec = BSON_INITIALIZER;
    for (std::size_t i = 0; i < vector.size(); ++i) {
        char idx[16];
        std::snprintf(idx, sizeof idx, "%zu", i);
        BSON_APPEND_DOUBLE(&vec, idx, static_cast<double>(vector[i]));
    }
    BSON_APPEND_ARRAY(&set, "vector", &vec);
    BSON_APPEND_DATE_TIME(&set, "projected_at", projected_at);
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_BOOL(&opts, "upsert", true);
    bson_error_t error{};
    bool ok = mongoc_collection_update_one(c, &filter, &upd, &opts, nullptr, &error);
    if (!ok && error.code == 11000) {
        bson_destroy(&opts);
        bson_t no_up = BSON_INITIALIZER;
        ok = mongoc_collection_update_one(c, &filter, &upd, &no_up, nullptr, &error);
        bson_destroy(&no_up);
    } else {
        bson_destroy(&opts);
    }
    bson_destroy(&filter);
    bson_destroy(&set);
    bson_destroy(&vec);
    bson_destroy(&upd);
    mongoc_collection_destroy(c);
    if (!ok) return bson_fail(error, err, "rag_embeddings upsert");
    return true;
}

static bool verify_projection(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const std::string& run_id,
    const std::vector<bson_oid_t>& ids,
    const EmbeddingIdentity* embedding,
    std::string* err) {
    if (ids.empty()) return true;
    bson_t in_arr = BSON_INITIALIZER;
    for (std::size_t i = 0; i < ids.size(); ++i) {
        char idx[16];
        std::snprintf(idx, sizeof idx, "%zu", i);
        BSON_APPEND_OID(&in_arr, idx, &ids[i]);
    }
    bson_t in = BSON_INITIALIZER;
    BSON_APPEND_ARRAY(&in, "$in", &in_arr);
    bson_t dq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&dq, "generation", generation.c_str());
    BSON_APPEND_DOCUMENT(&dq, "node_id", &in);
    mongoc_collection_t* docs = coll(client, db_name, kDocuments);
    bson_error_t error{};
    const int64_t document_count =
        mongoc_collection_count_documents(docs, &dq, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(docs);
    bson_t pq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&pq, "generation", generation.c_str());
    BSON_APPEND_UTF8(&pq, "run_id", run_id.c_str());
    BSON_APPEND_DOCUMENT(&pq, "node_id", &in);
    mongoc_collection_t* prov = coll(client, db_name, kProvenance);
    const int64_t provenance_count =
        mongoc_collection_count_documents(prov, &pq, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(prov);
    int64_t embedding_count = 0;
    if (embedding != nullptr) {
        bson_t eq = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&eq, "generation", generation.c_str());
        BSON_APPEND_DOCUMENT(&eq, "node_id", &in);
        append_identity_fields(&eq, *embedding);
        mongoc_collection_t* em = coll(client, db_name, kEmbeddings);
        embedding_count = mongoc_collection_count_documents(em, &eq, nullptr, nullptr, nullptr, &error);
        mongoc_collection_destroy(em);
        bson_destroy(&eq);
    }
    bson_destroy(&in_arr);
    bson_destroy(&in);
    bson_destroy(&dq);
    bson_destroy(&pq);
    const int64_t expected = static_cast<int64_t>(ids.size());
    if (document_count != expected || provenance_count != expected ||
        (embedding != nullptr && embedding_count != expected)) {
        if (err) {
            *err = "RAG projection verification failed: generation " + generation + " run " + run_id;
        }
        return false;
    }
    return true;
}

struct LoadedPair {
    bson_t* link;
    bson_t* node;
    bson_oid_t id;
};

struct LoadedRun {
    bson_t* run = nullptr;
    std::vector<bson_t*> link_docs;
    std::vector<LoadedPair> pairs;
    std::string run_id;
};

void loaded_run_free(LoadedRun* loaded) {
    if (loaded == nullptr) return;
    for (auto& p : loaded->pairs) {
        if (p.node) bson_destroy(p.node);
        p.node = nullptr;
    }
    loaded->pairs.clear();
    for (bson_t* d : loaded->link_docs) bson_destroy(d);
    loaded->link_docs.clear();
    if (loaded->run) bson_destroy(loaded->run);
    loaded->run = nullptr;
}

bool load_committed_run(
    mongoc_client_t* client, const std::string& db_name, const std::string& run_id, LoadedRun* loaded, std::string* err) {
    *loaded = LoadedRun{};
    loaded->run_id = run_id;
    mongoc_collection_t* runs = coll(client, db_name, "ingestion_runs");
    bson_t rq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&rq, "run_id", run_id.c_str());
    BSON_APPEND_UTF8(&rq, "status", "committed");
    mongoc_cursor_t* rcur = mongoc_collection_find_with_opts(runs, &rq, nullptr, nullptr);
    const bson_t* run_found = nullptr;
    if (!mongoc_cursor_next(rcur, &run_found)) {
        mongoc_cursor_destroy(rcur);
        mongoc_collection_destroy(runs);
        bson_destroy(&rq);
        if (err) *err = "ingestion run is not committed";
        return false;
    }
    loaded->run = bson_copy(run_found);
    mongoc_cursor_destroy(rcur);
    mongoc_collection_destroy(runs);
    bson_destroy(&rq);

    mongoc_collection_t* links = coll(client, db_name, "run_node_links");
    bson_t lq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&lq, "run_id", run_id.c_str());
    mongoc_cursor_t* lcur = mongoc_collection_find_with_opts(links, &lq, nullptr, nullptr);
    const bson_t* link_found = nullptr;
    while (mongoc_cursor_next(lcur, &link_found)) {
        loaded->link_docs.push_back(bson_copy(link_found));
    }
    bson_error_t error{};
    if (mongoc_cursor_error(lcur, &error)) {
        mongoc_cursor_destroy(lcur);
        mongoc_collection_destroy(links);
        bson_destroy(&lq);
        loaded_run_free(loaded);
        return bson_fail(error, err, "run_node_links");
    }
    mongoc_cursor_destroy(lcur);
    mongoc_collection_destroy(links);
    bson_destroy(&lq);

    mongoc_collection_t* nodes = coll(client, db_name, "knowledge_nodes");
    bool ok = true;
    for (bson_t* link : loaded->link_docs) {
        bson_oid_t nid{};
        if (!iter_oid(link, "node_id", &nid)) {
            ok = false;
            if (err) *err = "run_node_link missing node_id";
            break;
        }
        bson_t nq = BSON_INITIALIZER;
        BSON_APPEND_OID(&nq, "_id", &nid);
        mongoc_cursor_t* ncur = mongoc_collection_find_with_opts(nodes, &nq, nullptr, nullptr);
        const bson_t* node_found = nullptr;
        if (!mongoc_cursor_next(ncur, &node_found)) {
            mongoc_cursor_destroy(ncur);
            bson_destroy(&nq);
            ok = false;
            if (err) *err = "RAG projection verification failed: unresolved knowledge node";
            break;
        }
        loaded->pairs.push_back(LoadedPair{link, bson_copy(node_found), nid});
        mongoc_cursor_destroy(ncur);
        bson_destroy(&nq);
    }
    mongoc_collection_destroy(nodes);
    if (!ok) {
        loaded_run_free(loaded);
        return false;
    }
    return true;
}

bool project_loaded_into(
    mongoc_client_t* client,
    const std::string& db_name,
    LoadedRun* loaded,
    const std::string& generation,
    const EmbeddingIdentity* want,
    const EmbeddingRuntime& runtime,
    std::string* err) {
    const int64_t projected_at = now_millis();
    std::vector<bson_oid_t> ids;
    for (auto& p : loaded->pairs) {
        if (!upsert_document(client, db_name, generation, p.node, projected_at, err)) return false;
        if (!upsert_provenance(client, db_name, generation, loaded->run, p.link, p.node, projected_at, err)) {
            return false;
        }
        if (want != nullptr) {
            if (!project_embedding(
                    client, db_name, generation, p.node, *want, runtime, projected_at, err)) {
                return false;
            }
        }
        ids.push_back(p.id);
    }
    return verify_projection(client, db_name, generation, loaded->run_id, ids, want, err);
}

bool project_committed_run(
    mongoc_client_t* client, const std::string& db_name, const std::string& run_id, std::string* err) {
    if (!ensure_rag_indexes(client, db_name, err)) return false;
    LoadedRun loaded;
    if (!load_committed_run(client, db_name, run_id, &loaded, err)) return false;

    bson_t* meta = nullptr;
    if (!load_metadata(client, db_name, &meta, err)) {
        loaded_run_free(&loaded);
        return false;
    }
    std::string active, building;
    iter_utf8(meta, "active_generation", &active);
    iter_utf8(meta, "building_generation", &building);
    EmbeddingIdentity active_id{};
    EmbeddingIdentity building_id{};
    const bool active_embed = identity_from_field(meta, "embedding", &active_id);
    const bool building_embed = identity_from_field(meta, "building_embedding", &building_id);
    bson_destroy(meta);
    EmbeddingRuntime runtime;
    if (!embedding_runtime_from_env(&runtime, err)) {
        loaded_run_free(&loaded);
        return false;
    }
    if (active.empty()) {
        loaded_run_free(&loaded);
        if (err) *err = "RAG projection metadata is missing";
        return false;
    }

    std::vector<std::string> generations;
    generations.push_back(active);
    if (!building.empty() && building != active) generations.push_back(building);
    std::sort(generations.begin(), generations.end());

    bool ok = true;
    for (const std::string& generation : generations) {
        const EmbeddingIdentity* want = nullptr;
        if (generation == active && active_embed) want = &active_id;
        else if (generation == building && building_embed) want = &building_id;
        if (!project_loaded_into(client, db_name, &loaded, generation, want, runtime, err)) {
            ok = false;
            break;
        }
    }
    loaded_run_free(&loaded);
    return ok;
}

bool sync_projected_node_status(
    mongoc_client_t* client,
    const std::string& db_name,
    const bson_oid_t& node_id,
    const std::string& status,
    std::string* err) {
    bson_t* meta = nullptr;
    if (!load_metadata(client, db_name, &meta, err)) {
        if (err && *err == "RAG projection metadata is missing") {
            err->clear();
            return true;
        }
        return false;
    }
    std::string active, building;
    iter_utf8(meta, "active_generation", &active);
    iter_utf8(meta, "building_generation", &building);
    bson_destroy(meta);
    std::vector<std::string> generations;
    if (!active.empty()) generations.push_back(active);
    if (!building.empty()) generations.push_back(building);
    if (generations.empty()) return true;

    bson_t in_arr = BSON_INITIALIZER;
    for (std::size_t i = 0; i < generations.size(); ++i) {
        char idx[16];
        std::snprintf(idx, sizeof idx, "%zu", i);
        BSON_APPEND_UTF8(&in_arr, idx, generations[i].c_str());
    }
    bson_t in = BSON_INITIALIZER;
    BSON_APPEND_ARRAY(&in, "$in", &in_arr);
    bson_t q = BSON_INITIALIZER;
    BSON_APPEND_OID(&q, "node_id", &node_id);
    BSON_APPEND_DOCUMENT(&q, "generation", &in);
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "status", status.c_str());
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    mongoc_collection_t* docs = coll(client, db_name, kDocuments);
    bson_error_t error{};
    bool ok = mongoc_collection_update_many(docs, &q, &upd, nullptr, nullptr, &error);
    mongoc_collection_destroy(docs);
    bson_destroy(&in_arr);
    bson_destroy(&in);
    bson_destroy(&q);
    bson_destroy(&set);
    bson_destroy(&upd);
    if (!ok) return bson_fail(error, err, "RAG status sync");
    return true;
}

std::string iso_utc_millis(int64_t ms) {
    std::time_t s = static_cast<std::time_t>(ms / 1000);
    int milli = static_cast<int>(ms % 1000);
    if (milli < 0) milli = 0;
    std::tm tm{};
#if defined(_WIN32)
    gmtime_s(&tm, &s);
#else
    gmtime_r(&s, &tm);
#endif
    char buf[48];
    std::snprintf(
        buf,
        sizeof buf,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        milli);
    return buf;
}

std::string rag_rebuild_report_json(const RagRebuildReport& r) {
    std::ostringstream o;
    o << "{\"generation\":\"" << r.generation << "\""
      << ",\"previous_generation\":\"" << r.previous_generation << "\""
      << ",\"counts\":{"
      << "\"committed_runs\":" << r.committed_runs
      << ",\"committed_nodes\":" << r.committed_nodes
      << ",\"committed_links\":" << r.committed_links
      << ",\"projected_nodes\":" << r.projected_nodes
      << ",\"projected_links\":" << r.projected_links
      << ",\"projected_embeddings\":" << r.projected_embeddings
      << "},\"started_at\":\"" << r.started_at << "\""
      << ",\"completed_at\":\"" << r.completed_at << "\"}\n";
    return o.str();
}

int64_t aggregate_count(mongoc_collection_t* c, bson_t* pipeline, std::string* err) {
    mongoc_cursor_t* cur = mongoc_collection_aggregate(c, MONGOC_QUERY_NONE, pipeline, nullptr, nullptr);
    const bson_t* doc = nullptr;
    int64_t n = 0;
    if (mongoc_cursor_next(cur, &doc)) {
        bson_iter_t it;
        if (bson_iter_init_find(&it, doc, "count")) n = bson_iter_as_int64(&it);
    }
    bson_error_t error{};
    if (mongoc_cursor_error(cur, &error)) {
        mongoc_cursor_destroy(cur);
        bson_fail(error, err, "aggregate count");
        return -1;
    }
    mongoc_cursor_destroy(cur);
    return n;
}

bool corpus_counts(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const EmbeddingIdentity* embedding,
    RagRebuildReport* report,
    std::string* err) {
    mongoc_collection_t* runs = coll(client, db_name, "ingestion_runs");
    bson_t committed = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&committed, "status", "committed");
    bson_error_t error{};
    report->committed_runs =
        mongoc_collection_count_documents(runs, &committed, nullptr, nullptr, nullptr, &error);
    bson_error_t pipe_err{};
    bson_t* nodes_pipe = bson_new_from_json(
        reinterpret_cast<const uint8_t*>(
            "[{\"$match\":{\"status\":\"committed\"}},"
            "{\"$lookup\":{\"from\":\"run_node_links\",\"localField\":\"run_id\","
            "\"foreignField\":\"run_id\",\"as\":\"links\"}},"
            "{\"$unwind\":\"$links\"},"
            "{\"$group\":{\"_id\":\"$links.node_id\"}},"
            "{\"$count\":\"count\"}]"),
        -1,
        &pipe_err);
    if (nodes_pipe == nullptr) {
        mongoc_collection_destroy(runs);
        bson_destroy(&committed);
        return bson_fail(pipe_err, err, "committed nodes pipeline");
    }
    report->committed_nodes = aggregate_count(runs, nodes_pipe, err);
    bson_destroy(nodes_pipe);
    bson_t* links_pipe = bson_new_from_json(
        reinterpret_cast<const uint8_t*>(
            "[{\"$match\":{\"status\":\"committed\"}},"
            "{\"$lookup\":{\"from\":\"run_node_links\",\"localField\":\"run_id\","
            "\"foreignField\":\"run_id\",\"as\":\"links\"}},"
            "{\"$unwind\":\"$links\"},"
            "{\"$count\":\"count\"}]"),
        -1,
        &pipe_err);
    if (links_pipe == nullptr) {
        mongoc_collection_destroy(runs);
        bson_destroy(&committed);
        return bson_fail(pipe_err, err, "committed links pipeline");
    }
    report->committed_links = aggregate_count(runs, links_pipe, err);
    bson_destroy(links_pipe);
    mongoc_collection_destroy(runs);
    bson_destroy(&committed);
    if (report->committed_nodes < 0 || report->committed_links < 0) return false;

    mongoc_collection_t* docs = coll(client, db_name, kDocuments);
    bson_t gq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&gq, "generation", generation.c_str());
    report->projected_nodes =
        mongoc_collection_count_documents(docs, &gq, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(docs);
    mongoc_collection_t* prov = coll(client, db_name, kProvenance);
    report->projected_links =
        mongoc_collection_count_documents(prov, &gq, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(prov);
    bson_t eq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&eq, "generation", generation.c_str());
    if (embedding != nullptr) append_identity_fields(&eq, *embedding);
    mongoc_collection_t* em = coll(client, db_name, kEmbeddings);
    report->projected_embeddings =
        mongoc_collection_count_documents(em, &eq, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(em);
    bson_destroy(&gq);
    bson_destroy(&eq);
    return true;
}

bool cleanup_retired_generations(
    mongoc_client_t* client, const std::string& db_name, int64_t grace_ms, std::string* err) {
    bson_t* meta = nullptr;
    if (!load_metadata(client, db_name, &meta, err)) return false;
    std::string active, building;
    iter_utf8(meta, "active_generation", &active);
    iter_utf8(meta, "building_generation", &building);
    const int64_t cutoff = now_millis() - grace_ms;
    std::vector<std::string> drop;
    bson_iter_t it, arr;
    if (bson_iter_init_find(&it, meta, "retired_generations") && BSON_ITER_HOLDS_ARRAY(&it) &&
        bson_iter_recurse(&it, &arr)) {
        while (bson_iter_next(&arr)) {
            if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
            uint32_t len = 0;
            const uint8_t* data = nullptr;
            bson_iter_document(&arr, &len, &data);
            bson_t rec;
            if (!bson_init_static(&rec, data, len)) continue;
            std::string gen;
            iter_utf8(&rec, "generation", &gen);
            const int64_t at = iter_date(&rec, "retired_at", 0);
            if (gen.empty() || gen == active || gen == building || at >= cutoff) continue;
            drop.push_back(gen);
        }
    }
    bson_destroy(meta);
    for (const std::string& gen : drop) {
        bson_t q = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&q, "generation", gen.c_str());
        bson_error_t error{};
        mongoc_collection_t* docs = coll(client, db_name, kDocuments);
        bool ok = mongoc_collection_delete_many(docs, &q, nullptr, nullptr, &error);
        mongoc_collection_destroy(docs);
        if (!ok) {
            bson_destroy(&q);
            return bson_fail(error, err, "cleanup rag_documents");
        }
        mongoc_collection_t* prov = coll(client, db_name, kProvenance);
        ok = mongoc_collection_delete_many(prov, &q, nullptr, nullptr, &error);
        mongoc_collection_destroy(prov);
        if (!ok) {
            bson_destroy(&q);
            return bson_fail(error, err, "cleanup rag_provenance");
        }
        mongoc_collection_t* em = coll(client, db_name, kEmbeddings);
        ok = mongoc_collection_delete_many(em, &q, nullptr, nullptr, &error);
        mongoc_collection_destroy(em);
        bson_destroy(&q);
        if (!ok) return bson_fail(error, err, "cleanup rag_embeddings");
        mongoc_collection_t* md = coll(client, db_name, kMetadata);
        bson_t mq = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&mq, "_id", kMetadataID);
        bson_t pull_inner = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&pull_inner, "generation", gen.c_str());
        bson_t pull = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&pull, "retired_generations", &pull_inner);
        bson_t upd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&upd, "$pull", &pull);
        ok = mongoc_collection_update_one(md, &mq, &upd, nullptr, nullptr, &error);
        bson_destroy(&mq);
        bson_destroy(&pull_inner);
        bson_destroy(&pull);
        bson_destroy(&upd);
        mongoc_collection_destroy(md);
        if (!ok) return bson_fail(error, err, "cleanup retired_generations");
    }
    return true;
}

void abort_rebuild(mongoc_client_t* client, const std::string& db_name, const std::string& generation) {
    mongoc_collection_t* meta = coll(client, db_name, kMetadata);
    bson_t q = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&q, "_id", kMetadataID);
    BSON_APPEND_UTF8(&q, "building_generation", generation.c_str());
    const int64_t now = now_millis();
    bson_t unset = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&unset, "building_generation", "");
    BSON_APPEND_UTF8(&unset, "building_embedding", "");
    BSON_APPEND_UTF8(&unset, "build_started_at", "");
    bson_t retired = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&retired, "generation", generation.c_str());
    BSON_APPEND_DATE_TIME(&retired, "retired_at", now);
    bson_t push = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&push, "retired_generations", &retired);
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_DATE_TIME(&set, "updated_at", now);
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$unset", &unset);
    BSON_APPEND_DOCUMENT(&upd, "$push", &push);
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    mongoc_collection_update_one(meta, &q, &upd, nullptr, nullptr, nullptr);
    bson_destroy(&q);
    bson_destroy(&unset);
    bson_destroy(&retired);
    bson_destroy(&push);
    bson_destroy(&set);
    bson_destroy(&upd);
    mongoc_collection_destroy(meta);
}

bool rebuild_rag_projection(
    mongoc_client_t* client, const std::string& db_name, RagRebuildReport* report, std::string* err) {
    if (report == nullptr) {
        if (err) *err = "rebuild report is required";
        return false;
    }
    *report = RagRebuildReport{};
    report->started_at = iso_utc_millis(now_millis());
    if (!ensure_rag_indexes(client, db_name, err)) return false;
    if (!cleanup_retired_generations(client, db_name, 30 * 1000, err)) return false;

    bson_t* meta = nullptr;
    if (!load_metadata(client, db_name, &meta, err)) return false;
    std::string previous;
    iter_utf8(meta, "active_generation", &previous);
    bson_destroy(meta);
    if (previous.empty()) {
        if (err) *err = "RAG projection metadata is missing";
        return false;
    }

    EmbeddingRuntime runtime;
    if (!embedding_runtime_from_env(&runtime, err)) return false;
    const std::string generation = std::string("rebuild-") + projector_uuid();
    report->generation = generation;
    report->previous_generation = previous;
    const int64_t started = now_millis();

    mongoc_collection_t* metac = coll(client, db_name, kMetadata);
    bson_t query = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&query, "_id", kMetadataID);
    bson_t or_arr = BSON_INITIALIZER;
    bson_t c0 = BSON_INITIALIZER;
    bson_t exists = BSON_INITIALIZER;
    BSON_APPEND_BOOL(&exists, "$exists", false);
    BSON_APPEND_DOCUMENT(&c0, "building_generation", &exists);
    bson_t c1 = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&c1, "building_generation", "");
    BSON_APPEND_DOCUMENT(&or_arr, "0", &c0);
    BSON_APPEND_DOCUMENT(&or_arr, "1", &c1);
    BSON_APPEND_ARRAY(&query, "$or", &or_arr);

    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "building_generation", generation.c_str());
    BSON_APPEND_DATE_TIME(&set, "build_started_at", started);
    BSON_APPEND_DATE_TIME(&set, "updated_at", started);
    bson_t ident = BSON_INITIALIZER;
    bson_t unset = BSON_INITIALIZER;
    if (runtime.configured) {
        append_identity_fields(&ident, runtime.identity);
        BSON_APPEND_DOCUMENT(&set, "building_embedding", &ident);
    } else {
        BSON_APPEND_UTF8(&unset, "building_embedding", "");
    }
    bson_t update = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&update, "$set", &set);
    if (!runtime.configured) BSON_APPEND_DOCUMENT(&update, "$unset", &unset);

    mongoc_find_and_modify_opts_t* fm = mongoc_find_and_modify_opts_new();
    mongoc_find_and_modify_opts_set_update(fm, &update);
    mongoc_find_and_modify_opts_set_flags(fm, MONGOC_FIND_AND_MODIFY_RETURN_NEW);
    bson_t reply = BSON_INITIALIZER;
    bson_error_t error{};
    bool ok = mongoc_collection_find_and_modify_with_opts(metac, &query, fm, &reply, &error);
    mongoc_find_and_modify_opts_destroy(fm);
    bson_destroy(&query);
    bson_destroy(&or_arr);
    bson_destroy(&c0);
    bson_destroy(&exists);
    bson_destroy(&c1);
    bson_destroy(&set);
    bson_destroy(&ident);
    bson_destroy(&unset);
    bson_destroy(&update);
    mongoc_collection_destroy(metac);
    if (!ok) {
        bson_destroy(&reply);
        return bson_fail(error, err, "acquire rebuild lease");
    }
    bson_iter_t vit;
    const bool got_value =
        bson_iter_init_find(&vit, &reply, "value") && BSON_ITER_HOLDS_DOCUMENT(&vit);
    bson_destroy(&reply);
    if (!got_value) {
        if (err) *err = "RAG projection rebuild is already in progress";
        return false;
    }

    const EmbeddingIdentity* want = runtime.configured ? &runtime.identity : nullptr;
    bool switched = false;
    auto fail_abort = [&](const char* why) -> bool {
        abort_rebuild(client, db_name, generation);
        if (err && err->empty() && why) *err = why;
        return false;
    };

    mongoc_collection_t* runs = coll(client, db_name, "ingestion_runs");
    bson_t rq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&rq, "status", "committed");
    bson_t ropts = BSON_INITIALIZER;
    bson_t sort = BSON_INITIALIZER;
    BSON_APPEND_INT32(&sort, "run_id", 1);
    BSON_APPEND_DOCUMENT(&ropts, "sort", &sort);
    for (int attempt = 0; attempt < 3; ++attempt) {
        mongoc_cursor_t* rcur = mongoc_collection_find_with_opts(runs, &rq, &ropts, nullptr);
        std::vector<std::string> run_ids;
        const bson_t* run_doc = nullptr;
        while (mongoc_cursor_next(rcur, &run_doc)) {
            std::string id;
            if (iter_utf8(run_doc, "run_id", &id) && !id.empty()) run_ids.push_back(id);
        }
        if (mongoc_cursor_error(rcur, &error)) {
            mongoc_cursor_destroy(rcur);
            bson_destroy(&rq);
            bson_destroy(&sort);
            bson_destroy(&ropts);
            mongoc_collection_destroy(runs);
            bson_fail(error, err, "list committed runs");
            return fail_abort(nullptr);
        }
        mongoc_cursor_destroy(rcur);
        for (const std::string& run_id : run_ids) {
            LoadedRun loaded;
            if (!load_committed_run(client, db_name, run_id, &loaded, err)) {
                bson_destroy(&rq);
                bson_destroy(&sort);
            bson_destroy(&ropts);
                mongoc_collection_destroy(runs);
                loaded_run_free(&loaded);
                return fail_abort(nullptr);
            }
            const bool pok =
                project_loaded_into(client, db_name, &loaded, generation, want, runtime, err);
            loaded_run_free(&loaded);
            if (!pok) {
                bson_destroy(&rq);
                bson_destroy(&sort);
            bson_destroy(&ropts);
                mongoc_collection_destroy(runs);
                return fail_abort(nullptr);
            }
        }
        if (!corpus_counts(client, db_name, generation, want, report, err)) {
            bson_destroy(&rq);
            bson_destroy(&sort);
            bson_destroy(&ropts);
            mongoc_collection_destroy(runs);
            return fail_abort(nullptr);
        }
        if (report->committed_nodes == report->projected_nodes &&
            report->committed_links == report->projected_links &&
            (want == nullptr || report->committed_nodes == report->projected_embeddings)) {
            break;
        }
        if (attempt == 2) {
            bson_destroy(&rq);
            bson_destroy(&sort);
            bson_destroy(&ropts);
            mongoc_collection_destroy(runs);
            if (err) {
                *err = "RAG projection verification failed: committed vs projected mismatch";
            }
            return fail_abort(nullptr);
        }
    }
    bson_destroy(&rq);
    bson_destroy(&sort);
    bson_destroy(&ropts);
    mongoc_collection_destroy(runs);

    const int64_t completed = now_millis();
    mongoc_collection_t* act = coll(client, db_name, kMetadata);
    bson_t aq = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&aq, "_id", kMetadataID);
    BSON_APPEND_UTF8(&aq, "active_generation", previous.c_str());
    BSON_APPEND_UTF8(&aq, "building_generation", generation.c_str());
    bson_t aset = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&aset, "active_generation", generation.c_str());
    BSON_APPEND_UTF8(&aset, "projection_version", kProjectionVersion);
    BSON_APPEND_UTF8(&aset, "projection_schema", kProjectionSchema);
    BSON_APPEND_UTF8(&aset, "indexer_version", kIndexerVersion);
    BSON_APPEND_DATE_TIME(&aset, "active_since", completed);
    BSON_APPEND_DATE_TIME(&aset, "last_rebuild_at", completed);
    BSON_APPEND_DATE_TIME(&aset, "updated_at", completed);
    bson_t aident = BSON_INITIALIZER;
    bson_t aunset = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&aunset, "building_generation", "");
    BSON_APPEND_UTF8(&aunset, "building_embedding", "");
    BSON_APPEND_UTF8(&aunset, "build_started_at", "");
    if (runtime.configured) {
        append_identity_fields(&aident, runtime.identity);
        BSON_APPEND_DOCUMENT(&aset, "embedding", &aident);
    } else {
        BSON_APPEND_UTF8(&aunset, "embedding", "");
    }
    bson_t retired = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&retired, "generation", previous.c_str());
    BSON_APPEND_DATE_TIME(&retired, "retired_at", completed);
    bson_t apush = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&apush, "retired_generations", &retired);
    bson_t aupd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&aupd, "$set", &aset);
    BSON_APPEND_DOCUMENT(&aupd, "$unset", &aunset);
    BSON_APPEND_DOCUMENT(&aupd, "$push", &apush);
    bson_t areply = BSON_INITIALIZER;
    ok = mongoc_collection_update_one(act, &aq, &aupd, nullptr, &areply, &error);
    int64_t matched = 0;
    bson_iter_t mit;
    if (bson_iter_init_find(&mit, &areply, "matchedCount")) matched = bson_iter_as_int64(&mit);
    bson_destroy(&aq);
    bson_destroy(&aset);
    bson_destroy(&aident);
    bson_destroy(&aunset);
    bson_destroy(&retired);
    bson_destroy(&apush);
    bson_destroy(&aupd);
    bson_destroy(&areply);
    mongoc_collection_destroy(act);
    if (!ok || matched != 1) {
        if (err && !ok) bson_fail(error, err, "activate generation");
        else if (err) *err = "RAG generation changed during rebuild; refusing to switch";
        return fail_abort(nullptr);
    }
    switched = true;
    (void)switched;
    report->completed_at = iso_utc_millis(completed);
    if (!cleanup_retired_generations(client, db_name, 30 * 1000, err)) return false;
    return true;
}

bool rag_read_metadata(
    mongoc_client_t* client, const std::string& db_name, RagMetadataView* out, std::string* err) {
    if (out == nullptr) return false;
    *out = RagMetadataView{};
    bson_t* meta = nullptr;
    if (!load_metadata(client, db_name, &meta, err)) return false;
    iter_utf8(meta, "active_generation", &out->active_generation);
    iter_utf8(meta, "building_generation", &out->building_generation);
    iter_utf8(meta, "projection_version", &out->projection_version);
    iter_utf8(meta, "projection_schema", &out->projection_schema);
    iter_utf8(meta, "indexer_version", &out->indexer_version);
    out->has_embedding = identity_from_field(meta, "embedding", &out->embedding);
    bson_destroy(meta);
    return true;
}

bool rag_corpus_counts(
    mongoc_client_t* client,
    const std::string& db_name,
    const std::string& generation,
    const EmbeddingIdentity* embedding,
    RagCorpusCounts* counts,
    std::string* err) {
    if (counts == nullptr) return false;
    RagRebuildReport report;
    if (!corpus_counts(client, db_name, generation, embedding, &report, err)) return false;
    counts->committed_runs = report.committed_runs;
    counts->committed_nodes = report.committed_nodes;
    counts->committed_links = report.committed_links;
    counts->projected_nodes = report.projected_nodes;
    counts->projected_links = report.projected_links;
    counts->projected_embeddings = report.projected_embeddings;
    return true;
}

bool rag_latest_time(
    mongoc_client_t* client,
    const std::string& db_name,
    const char* collection,
    const bson_t* filter,
    const char* field,
    int64_t* millis_out,
    bool* found,
    std::string* err) {
    if (found) *found = false;
    mongoc_collection_t* c = mongoc_client_get_collection(client, db_name.c_str(), collection);
    bson_t sort = BSON_INITIALIZER;
    BSON_APPEND_INT32(&sort, field, -1);
    bson_t proj = BSON_INITIALIZER;
    BSON_APPEND_INT32(&proj, field, 1);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&opts, "sort", &sort);
    BSON_APPEND_DOCUMENT(&opts, "projection", &proj);
    BSON_APPEND_INT32(&opts, "limit", 1);
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(c, filter, &opts, nullptr);
    const bson_t* doc = nullptr;
    bool ok = mongoc_cursor_next(cur, &doc);
    bson_error_t error{};
    if (mongoc_cursor_error(cur, &error)) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(c);
        bson_destroy(&sort);
        bson_destroy(&proj);
        bson_destroy(&opts);
        return bson_fail(error, err, "latest time");
    }
    if (ok && doc != nullptr && millis_out != nullptr) {
        bson_iter_t it;
        if (bson_iter_init_find(&it, doc, field) && BSON_ITER_HOLDS_DATE_TIME(&it)) {
            *millis_out = bson_iter_date_time(&it);
            if (found) *found = true;
        }
    }
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(c);
    bson_destroy(&sort);
    bson_destroy(&proj);
    bson_destroy(&opts);
    return true;
}

}  // namespace godbrain::memory

