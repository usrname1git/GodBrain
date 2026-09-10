#include "godbrain/memory_store/store.hpp"
#include "godbrain/memory_store/state_machine.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <sstream>
#include <vector>

#if defined(GODBRAIN_HAVE_MONGOC)
#include "godbrain/memory_store/embedding.hpp"
#include "projector.hpp"
#include <mongoc/mongoc.h>
#endif

#if defined(_WIN32)
#include <rpc.h>
#pragma comment(lib, "rpcrt4.lib")
#endif

namespace godbrain::memory {
namespace {

std::string json_escape_local(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        if (c == '"') o += "\\\"";
        else if (c == '\\') o += "\\\\";
        else o.push_back(static_cast<char>(c));
    }
    return o;
}

std::string utc_now() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#if defined(_WIN32)
    gmtime_s(&tm, &t);
#else
    gmtime_r(&t, &tm);
#endif
    char buf[32];
    std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

int64_t utc_millis() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

#if defined(_WIN32)
std::string new_uuid() {
    UUID u;
    UuidCreate(&u);
    RPC_CSTR s = nullptr;
    UuidToStringA(&u, &s);
    std::string out(reinterpret_cast<char*>(s));
    RpcStringFreeA(&s);
    return out;
}
#else
std::string new_uuid() { return keccak256_hex(utc_now() + std::to_string(utc_millis())); }
#endif

Claim merge_claim(Claim existing, const Claim& incoming) {
    if (incoming.confidence > existing.confidence) existing.confidence = incoming.confidence;
    std::map<std::string, bool> seen;
    std::vector<std::string> merged;
    for (const std::string& span : existing.evidence_spans) {
        if (seen.insert({span, true}).second) merged.push_back(span);
    }
    for (const std::string& span : incoming.evidence_spans) {
        if (seen.insert({span, true}).second) merged.push_back(span);
    }
    existing.evidence_spans = std::move(merged);
    return existing;
}

}  // namespace

std::string store_receipt_json(const StoreReceipt& r) {
    std::ostringstream o;
    o << "{\"run_id\":\"" << json_escape_local(r.run_id) << "\""
      << ",\"record_id\":\"" << json_escape_local(r.record_id) << "\""
      << ",\"version\":\"" << json_escape_local(r.version) << "\""
      << ",\"schema_version\":\"" << json_escape_local(r.schema_version) << "\""
      << ",\"status\":\"" << json_escape_local(r.status) << "\""
      << ",\"insert_count\":" << r.insert_count
      << ",\"update_count\":" << r.update_count
      << ",\"timestamp\":\"" << json_escape_local(r.timestamp) << "\"}\n";
    return o.str();
}

std::string judgment_receipt_json(const JudgmentReceiptOut& r) {
    std::ostringstream o;
    o << "{\"node_id\":\"" << json_escape_local(r.node_id) << "\""
      << ",\"stable_id\":\"" << json_escape_local(r.stable_id) << "\""
      << ",\"from\":\"" << json_escape_local(r.from) << "\""
      << ",\"to\":\"" << json_escape_local(r.to) << "\""
      << ",\"status\":\"" << json_escape_local(r.status) << "\""
      << ",\"timestamp\":\"" << json_escape_local(r.timestamp) << "\"}\n";
    return o.str();
}

std::string skill_run_receipt_json(const SkillRunReceiptOut& r) {
    std::ostringstream o;
    o << "{\"run_id\":\"" << json_escape_local(r.run_id) << "\""
      << ",\"skill_name\":\"" << json_escape_local(r.skill_name) << "\""
      << ",\"origin_node_id\":\"" << json_escape_local(r.origin_node_id) << "\""
      << ",\"result\":\"" << json_escape_local(r.result) << "\""
      << ",\"status\":\"" << json_escape_local(r.status) << "\""
      << ",\"timestamp\":\"" << json_escape_local(r.timestamp) << "\"}\n";
    return o.str();
}

std::string promote_skill_receipt_json(const PromoteSkillReceiptOut& r) {
    std::ostringstream o;
    o << "{\"skill_id\":\"" << json_escape_local(r.skill_id) << "\""
      << ",\"name\":\"" << json_escape_local(r.name) << "\""
      << ",\"origin_node_id\":\"" << json_escape_local(r.origin_node_id) << "\""
      << ",\"status\":\"" << json_escape_local(r.status) << "\""
      << ",\"timestamp\":\"" << json_escape_local(r.timestamp) << "\"}\n";
    return o.str();
}

std::string query_skills_receipt_json(const QuerySkillsReceiptOut& r) {
    std::ostringstream o;
    o << "{\"status\":\"" << json_escape_local(r.status) << "\",\"count\":" << r.count << ",\"skills\":[";
    for (size_t i = 0; i < r.skills.size(); ++i) {
        if (i) o << ",";
        o << "{\"name\":\"" << json_escape_local(r.skills[i].name) << "\""
          << ",\"content\":\"" << json_escape_local(r.skills[i].content) << "\""
          << ",\"origin_node_id\":\"" << json_escape_local(r.skills[i].origin_node_id) << "\""
          << ",\"origin_hash\":\"" << json_escape_local(r.skills[i].origin_hash) << "\"";
        if (!r.skills[i].verification_profile.empty()) {
            o << ",\"verification_profile\":\"" << json_escape_local(r.skills[i].verification_profile) << "\"";
        }
        o << "}";
    }
    o << "],\"timestamp\":\"" << json_escape_local(r.timestamp) << "\"}\n";
    return o.str();
}

#if !defined(GODBRAIN_HAVE_MONGOC)

bool store_available() { return false; }
struct StoreHandle {};
StoreHandle* store_open(std::string* err) {
    if (err) *err = "mongo-c-driver not linked (install C:\\Tools\\mongo-c-driver)";
    return nullptr;
}
void store_close(StoreHandle*) {}
bool store_ingest(StoreHandle*, const DistillationPayload&, StoreReceipt*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}
bool store_set_status(StoreHandle*, const StatusJudgment&, JudgmentReceiptOut*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}
bool store_rebuild(StoreHandle*, std::string*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}
bool store_record_skill_run(StoreHandle*, const RecordSkillRunRequest&, SkillRunReceiptOut*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}
bool store_promote_skill(StoreHandle*, const PromoteSkillRequest&, PromoteSkillReceiptOut*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}
bool store_query_skills(StoreHandle*, const QuerySkillsRequest&, QuerySkillsReceiptOut*, std::string* err) {
    if (err) *err = "mongo-c-driver not linked";
    return false;
}

#else

struct StoreHandle {
    mongoc_client_t* client = nullptr;
    mongoc_database_t* db = nullptr;
    std::string db_name;
};

bool store_available() { return true; }

static void mongoc_once() {
    static bool inited = false;
    if (!inited) {
        mongoc_init();
        inited = true;
    }
}

static mongoc_collection_t* coll(StoreHandle* h, const char* name) {
    return mongoc_client_get_collection(h->client, h->db_name.c_str(), name);
}

static bool bson_ok(bool ok, const bson_error_t& error, std::string* err, const char* what) {
    if (ok) return true;
    if (err) *err = std::string(what) + ": " + error.message;
    return false;
}

static bool iter_utf8(const bson_t* doc, const char* key, std::string* out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key) || !BSON_ITER_HOLDS_UTF8(&it)) return false;
    *out = bson_iter_utf8(&it, nullptr);
    return true;
}

static int64_t reply_matched(const bson_t* reply) {
    bson_iter_t it;
    if (bson_iter_init_find(&it, reply, "matchedCount")) return bson_iter_as_int64(&it);
    return 0;
}

static bool create_unique_index(
    StoreHandle* h,
    const char* name,
    bson_t* keys,
    bson_t* opt,
    std::string* err,
    const char* what) {
    mongoc_collection_t* c = coll(h, name);
    mongoc_index_model_t* models[1] = {mongoc_index_model_new(keys, opt)};
    bson_error_t error{};
    bool ok = mongoc_collection_create_indexes_with_opts(c, models, 1, nullptr, nullptr, &error);
    mongoc_index_model_destroy(models[0]);
    mongoc_collection_destroy(c);
    if (!ok && error.code != 85 && error.code != 86) {
        return bson_ok(false, error, err, what);
    }
    return true;
}

StoreHandle* store_open(std::string* err) {
    const char* uri = std::getenv("MONGODB_URI");
    if (uri == nullptr || uri[0] == '\0') {
        if (err) *err = "MONGODB_URI environment variable is not set";
        return nullptr;
    }
    const char* dbn = std::getenv("MONGODB_DB_NAME");
    if (dbn == nullptr || dbn[0] == '\0') dbn = "godbrain";

    mongoc_once();
    auto* h = new StoreHandle();
    h->db_name = dbn;
    bson_error_t error{};
    mongoc_uri_t* parsed = mongoc_uri_new_with_error(uri, &error);
    if (parsed == nullptr) {
        if (err) *err = std::string("Failed to parse MONGODB_URI: ") + error.message;
        delete h;
        return nullptr;
    }
    h->client = mongoc_client_new_from_uri(parsed);
    mongoc_uri_destroy(parsed);
    if (h->client == nullptr) {
        if (err) *err = "Failed to connect to MongoDB";
        delete h;
        return nullptr;
    }
    mongoc_client_set_appname(h->client, "godbrain-cpp-memory-store");
    h->db = mongoc_client_get_database(h->client, h->db_name.c_str());
    bson_t ping = BSON_INITIALIZER;
    BSON_APPEND_INT32(&ping, "ping", 1);
    bson_t reply = BSON_INITIALIZER;
    bool ok = mongoc_client_command_simple(h->client, "admin", &ping, nullptr, &reply, &error);
    bson_destroy(&ping);
    bson_destroy(&reply);
    if (!ok) {
        if (err) *err = std::string("Failed to ping MongoDB: ") + error.message;
        store_close(h);
        return nullptr;
    }
    EmbeddingRuntime runtime;
    if (!embedding_runtime_from_env(&runtime, err)) {
        store_close(h);
        return nullptr;
    }
    return h;
}

void store_close(StoreHandle* h) {
    if (h == nullptr) return;
    if (h->db) mongoc_database_destroy(h->db);
    if (h->client) mongoc_client_destroy(h->client);
    delete h;
}

static bool ensure_indexes(StoreHandle* h, std::string* err) {
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "source_hash", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true));
        bool ok = create_unique_index(h, "sources", &keys, opt, err, "sources index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "source_hash", 1);
        BSON_APPEND_INT32(&keys, "external_source_id", 1);
        BSON_APPEND_INT32(&keys, "extractor_id", 1);
        BSON_APPEND_INT32(&keys, "extractor_version", 1);
        BSON_APPEND_INT32(&keys, "schema_version", 1);
        BSON_APPEND_INT32(&keys, "document.file_sha256", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true), "name", "source_observation_file_identity");
        bool ok = create_unique_index(h, "source_observations", &keys, opt, err, "source_observations index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "stable_id", 1);
        BSON_APPEND_INT32(&keys, "version", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true));
        bool ok = create_unique_index(h, "knowledge_nodes", &keys, opt, err, "knowledge_nodes index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "run_id", 1);
        BSON_APPEND_INT32(&keys, "node_id", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true));
        bool ok = create_unique_index(h, "run_node_links", &keys, opt, err, "run_node_links index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "source_hash", 1);
        BSON_APPEND_INT32(&keys, "extractor_id", 1);
        BSON_APPEND_INT32(&keys, "extractor_version", 1);
        BSON_APPEND_INT32(&keys, "schema_version", 1);
        bson_t* opt = BCON_NEW(
            "unique", BCON_BOOL(true),
            "partialFilterExpression", "{", "active", BCON_BOOL(true), "}");
        bool ok = create_unique_index(h, "ingestion_runs", &keys, opt, err, "ingestion_runs index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "name", 1);
        bson_t* opt = BCON_NEW("unique", BCON_BOOL(true), "name", "skills_name");
        bool ok = create_unique_index(h, "skills", &keys, opt, err, "skills index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    {
        bson_t keys = BSON_INITIALIZER;
        BSON_APPEND_INT32(&keys, "origin_node_id", 1);
        BSON_APPEND_INT32(&keys, "skill_name", 1);
        BSON_APPEND_INT32(&keys, "created_at", -1);
        BSON_APPEND_INT32(&keys, "_id", -1);
        bson_t* opt = BCON_NEW("name", "skill_runs_origin_name_created");
        bool ok = create_unique_index(h, "skill_verification_runs", &keys, opt, err, "skill_verification_runs index");
        bson_destroy(opt);
        bson_destroy(&keys);
        if (!ok) return false;
    }
    return true;
}

static bool transition_run(
    StoreHandle* h,
    const std::string& run_id,
    const std::string& from,
    const std::string& to,
    const std::string& lease,
    const char* error_msg,
    std::string* err) {
    if (!allowed_run_transition(from, to)) {
        if (err) *err = "invalid ingestion run state transition";
        return false;
    }
    mongoc_collection_t* c = coll(h, "ingestion_runs");
    bson_t query = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&query, "run_id", run_id.c_str());
    BSON_APPEND_UTF8(&query, "status", from.c_str());
    BSON_APPEND_UTF8(&query, "lease_token", lease.c_str());
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "status", to.c_str());
    BSON_APPEND_DATE_TIME(&set, "updated_at", utc_millis());
    if (to == kRunFailed) {
        BSON_APPEND_BOOL(&set, "active", false);
    }
    if (error_msg != nullptr) {
        BSON_APPEND_UTF8(&set, "error_msg", error_msg);
    }
    bson_t update = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&update, "$set", &set);
    bson_t reply = BSON_INITIALIZER;
    bson_error_t error{};
    bool ok = mongoc_collection_update_one(c, &query, &update, nullptr, &reply, &error);
    const int64_t matched = reply_matched(&reply);
    bson_destroy(&query);
    bson_destroy(&set);
    bson_destroy(&update);
    bson_destroy(&reply);
    mongoc_collection_destroy(c);
    if (!ok) return bson_ok(false, error, err, "transition");
    if (matched != 1) {
        if (err) *err = "ingestion run is not in the expected state";
        return false;
    }
    return true;
}

static void fail_created_run(
    StoreHandle* h, const std::string& run_id, const std::string& lease, const char* msg) {
    std::string ignored;
    transition_run(h, run_id, kRunStaging, kRunFailed, lease, msg, &ignored);
}

static bool find_run_doc(
    StoreHandle* h, const bson_t* filter, bson_t** out, std::string* err) {
    mongoc_collection_t* runs = coll(h, "ingestion_runs");
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(runs, filter, nullptr, nullptr);
    const bson_t* found = nullptr;
    bool ok = mongoc_cursor_next(cur, &found);
    bson_error_t error{};
    if (mongoc_cursor_error(cur, &error)) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(runs);
        return bson_ok(false, error, err, "find run");
    }
    if (!ok || found == nullptr) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(runs);
        if (err) *err = "ingestion run not found after upsert";
        return false;
    }
    *out = bson_copy(found);
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(runs);
    return true;
}

bool store_ingest(
    StoreHandle* h, const DistillationPayload& payload, StoreReceipt* receipt, std::string* err) {
    if (h == nullptr || receipt == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    if (!ensure_indexes(h, err)) return false;

    const std::string extractor =
        payload.extractor_id.empty() ? kDefaultExtractorID : payload.extractor_id;
    const std::string& source_hash = payload.provenance.source_hash;
    const int64_t now = utc_millis();

    mongoc_collection_t* runs = coll(h, "ingestion_runs");
    {
        bson_t q = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&q, "source_hash", source_hash.c_str());
        BSON_APPEND_BOOL(&q, "active", true);
        bson_t in_arr = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&in_arr, "0", kRunStaging);
        BSON_APPEND_UTF8(&in_arr, "1", kRunValidated);
        bson_t status_in = BSON_INITIALIZER;
        BSON_APPEND_ARRAY(&status_in, "$in", &in_arr);
        BSON_APPEND_DOCUMENT(&q, "status", &status_in);
        bson_t lt = BSON_INITIALIZER;
        BSON_APPEND_DATE_TIME(&lt, "$lt", now - 5 * 60 * 1000);
        BSON_APPEND_DOCUMENT(&q, "updated_at", &lt);
        bson_t set = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&set, "status", kRunFailed);
        BSON_APPEND_BOOL(&set, "active", false);
        BSON_APPEND_UTF8(&set, "error_msg", "lease_timeout");
        BSON_APPEND_UTF8(&set, "lease_token", "");
        BSON_APPEND_DATE_TIME(&set, "updated_at", now);
        bson_t upd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&upd, "$set", &set);
        bson_error_t error{};
        bool ok = mongoc_collection_update_many(runs, &q, &upd, nullptr, nullptr, &error);
        bson_destroy(&q);
        bson_destroy(&status_in);
        bson_destroy(&in_arr);
        bson_destroy(&lt);
        bson_destroy(&set);
        bson_destroy(&upd);
        if (!ok) {
            mongoc_collection_destroy(runs);
            return bson_ok(false, error, err, "expire leases");
        }
    }

    std::string retry_of;
    {
        bson_t fq = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&fq, "source_hash", source_hash.c_str());
        BSON_APPEND_UTF8(&fq, "extractor_id", extractor.c_str());
        BSON_APPEND_UTF8(&fq, "extractor_version", payload.extractor_version.c_str());
        BSON_APPEND_UTF8(&fq, "schema_version", payload.schema_version.c_str());
        BSON_APPEND_UTF8(&fq, "status", kRunFailed);
        bson_t* opts = BCON_NEW("sort", "{", "created_at", BCON_INT32(-1), "}");
        mongoc_cursor_t* cur = mongoc_collection_find_with_opts(runs, &fq, opts, nullptr);
        const bson_t* found = nullptr;
        if (mongoc_cursor_next(cur, &found)) {
            iter_utf8(found, "run_id", &retry_of);
        }
        mongoc_cursor_destroy(cur);
        bson_destroy(opts);
        bson_destroy(&fq);
    }

    const std::string new_run_id = new_uuid();
    const std::string lease = new_uuid();
    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "source_hash", source_hash.c_str());
    BSON_APPEND_UTF8(&filter, "extractor_id", extractor.c_str());
    BSON_APPEND_UTF8(&filter, "extractor_version", payload.extractor_version.c_str());
    BSON_APPEND_UTF8(&filter, "schema_version", payload.schema_version.c_str());
    BSON_APPEND_BOOL(&filter, "active", true);
    bson_t ne = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&ne, "$ne", kRunFailed);
    BSON_APPEND_DOCUMENT(&filter, "status", &ne);

    bson_t set_on = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set_on, "run_id", new_run_id.c_str());
    BSON_APPEND_UTF8(&set_on, "status", kRunStaging);
    BSON_APPEND_BOOL(&set_on, "active", true);
    BSON_APPEND_UTF8(&set_on, "lease_token", lease.c_str());
    BSON_APPEND_UTF8(&set_on, "source_hash", source_hash.c_str());
    BSON_APPEND_UTF8(&set_on, "extractor_id", extractor.c_str());
    BSON_APPEND_UTF8(&set_on, "extractor_version", payload.extractor_version.c_str());
    BSON_APPEND_UTF8(&set_on, "schema_version", payload.schema_version.c_str());
    BSON_APPEND_UTF8(&set_on, "external_source_id", payload.provenance.source_id.c_str());
    BSON_APPEND_DATE_TIME(&set_on, "created_at", now);
    BSON_APPEND_DATE_TIME(&set_on, "updated_at", now);
    if (!retry_of.empty()) {
        BSON_APPEND_UTF8(&set_on, "retry_of", retry_of.c_str());
    }
    bson_t update = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&update, "$setOnInsert", &set_on);

    mongoc_find_and_modify_opts_t* fm = mongoc_find_and_modify_opts_new();
    mongoc_find_and_modify_opts_set_update(fm, &update);
    mongoc_find_and_modify_opts_set_flags(
        fm,
        static_cast<mongoc_find_and_modify_flags_t>(
            MONGOC_FIND_AND_MODIFY_UPSERT | MONGOC_FIND_AND_MODIFY_RETURN_NEW));
    bson_t reply = BSON_INITIALIZER;
    bson_error_t error{};
    bool ok = mongoc_collection_find_and_modify_with_opts(runs, &filter, fm, &reply, &error);
    mongoc_find_and_modify_opts_destroy(fm);
    bson_destroy(&set_on);
    bson_destroy(&update);
    bson_t* run_doc = nullptr;
    if (!ok && error.code == 11000) {
        bson_destroy(&reply);
        ok = find_run_doc(h, &filter, &run_doc, err);
    } else if (!ok) {
        bson_destroy(&filter);
        bson_destroy(&ne);
        bson_destroy(&reply);
        mongoc_collection_destroy(runs);
        return bson_ok(false, error, err, "StartIngestion");
    } else {
        bson_iter_t it;
        if (bson_iter_init_find(&it, &reply, "value") && BSON_ITER_HOLDS_DOCUMENT(&it)) {
            uint32_t len = 0;
            const uint8_t* data = nullptr;
            bson_iter_document(&it, &len, &data);
            run_doc = bson_new_from_data(data, len);
        }
        bson_destroy(&reply);
    }
    bson_destroy(&filter);
    bson_destroy(&ne);
    mongoc_collection_destroy(runs);
    if (run_doc == nullptr) {
        if (err && err->empty()) *err = "StartIngestion returned no run";
        return false;
    }

    std::string run_id, record_id, run_status, run_lease;
    iter_utf8(run_doc, "run_id", &run_id);
    iter_utf8(run_doc, "status", &run_status);
    iter_utf8(run_doc, "lease_token", &run_lease);
    bson_iter_t idit;
    if (bson_iter_init_find(&idit, run_doc, "_id") && BSON_ITER_HOLDS_OID(&idit)) {
        char oid[25];
        bson_oid_to_string(bson_iter_oid(&idit), oid);
        record_id = oid;
    }
    bson_destroy(run_doc);

    const bool created = (run_id == new_run_id);
    if (!created && (run_status == kRunStaging || run_status == kRunValidated)) {
        if (err) *err = "Concurrent ingestion detected";
        return false;
    }

    {
        mongoc_collection_t* obs = coll(h, "source_observations");
        bson_t oq = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&oq, "source_hash", source_hash.c_str());
        BSON_APPEND_UTF8(&oq, "external_source_id", payload.provenance.source_id.c_str());
        BSON_APPEND_UTF8(&oq, "extractor_id", extractor.c_str());
        BSON_APPEND_UTF8(&oq, "extractor_version", payload.extractor_version.c_str());
        BSON_APPEND_UTF8(&oq, "schema_version", payload.schema_version.c_str());
        bson_t oset = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&oset, "source_hash", source_hash.c_str());
        BSON_APPEND_UTF8(&oset, "external_source_id", payload.provenance.source_id.c_str());
        BSON_APPEND_UTF8(&oset, "extractor_id", extractor.c_str());
        BSON_APPEND_UTF8(&oset, "extractor_version", payload.extractor_version.c_str());
        BSON_APPEND_UTF8(&oset, "schema_version", payload.schema_version.c_str());
        BSON_APPEND_UTF8(&oset, "run_id", run_id.c_str());
        BSON_APPEND_DATE_TIME(&oset, "created_at", now);
        bson_t oupd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&oupd, "$setOnInsert", &oset);
        bson_t oopts = BSON_INITIALIZER;
        BSON_APPEND_BOOL(&oopts, "upsert", true);
        ok = mongoc_collection_update_one(obs, &oq, &oupd, &oopts, nullptr, &error);
        bson_destroy(&oq);
        bson_destroy(&oset);
        bson_destroy(&oupd);
        bson_destroy(&oopts);
        mongoc_collection_destroy(obs);
        if (!ok && error.code != 11000) {
            if (created) fail_created_run(h, run_id, lease, "observation_failed");
            return bson_ok(false, error, err, "source observation");
        }
    }

    const std::string used_lease = created ? lease : std::string();
    int inserts = 0;
    std::string status = "committed";

    if (!created && run_status == kRunCommitted) {
        status = "idempotent_noop";
    } else if (created || run_status == kRunStaging) {
        mongoc_collection_t* sources = coll(h, "sources");
        bson_t src_q = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&src_q, "source_hash", source_hash.c_str());
        bson_t src_set = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&src_set, "source_hash", source_hash.c_str());
        BSON_APPEND_UTF8(&src_set, "source_type", payload.provenance.source_type.c_str());
        BSON_APPEND_UTF8(&src_set, "language", payload.provenance.language.c_str());
        BSON_APPEND_UTF8(&src_set, "content", payload.raw_transcript.c_str());
        BSON_APPEND_DATE_TIME(&src_set, "created_at", now);
        bson_t src_upd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&src_upd, "$setOnInsert", &src_set);
        bson_t src_opts = BSON_INITIALIZER;
        BSON_APPEND_BOOL(&src_opts, "upsert", true);
        ok = mongoc_collection_update_one(sources, &src_q, &src_upd, &src_opts, nullptr, &error);
        bson_destroy(&src_q);
        bson_destroy(&src_set);
        bson_destroy(&src_upd);
        bson_destroy(&src_opts);
        if (!ok) {
            mongoc_collection_destroy(sources);
            fail_created_run(h, run_id, used_lease, "stage source");
            return bson_ok(false, error, err, "stage source");
        }
        bson_oid_t source_oid;
        bool have_source_oid = false;
        bson_t src_fq = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&src_fq, "source_hash", source_hash.c_str());
        mongoc_cursor_t* scur = mongoc_collection_find_with_opts(sources, &src_fq, nullptr, nullptr);
        const bson_t* src_found = nullptr;
        if (mongoc_cursor_next(scur, &src_found)) {
            bson_iter_t sit;
            if (bson_iter_init_find(&sit, src_found, "_id") && BSON_ITER_HOLDS_OID(&sit)) {
                source_oid = *bson_iter_oid(&sit);
                have_source_oid = true;
            }
        }
        mongoc_cursor_destroy(scur);
        bson_destroy(&src_fq);
        mongoc_collection_destroy(sources);
        if (!have_source_oid) {
            fail_created_run(h, run_id, used_lease, "resolve source");
            if (err) *err = "failed to resolve immutable source";
            return false;
        }

        bson_t run_q = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&run_q, "run_id", run_id.c_str());
        BSON_APPEND_UTF8(&run_q, "status", kRunStaging);
        BSON_APPEND_UTF8(&run_q, "lease_token", used_lease.c_str());
        bson_t run_set = BSON_INITIALIZER;
        if (!payload.provenance.prompt_hash.empty()) {
            BSON_APPEND_UTF8(&run_set, "prompt_hash", payload.provenance.prompt_hash.c_str());
        }
        if (!payload.provenance.model_id.empty()) {
            BSON_APPEND_UTF8(&run_set, "model_id", payload.provenance.model_id.c_str());
        }
        if (!payload.provenance.model_hash.empty()) {
            BSON_APPEND_UTF8(&run_set, "model_hash", payload.provenance.model_hash.c_str());
        }
        BSON_APPEND_DOUBLE(&run_set, "llm_temperature", payload.provenance.llm_temperature);
        BSON_APPEND_OID(&run_set, "source_id", &source_oid);
        BSON_APPEND_UTF8(&run_set, "external_source_id", payload.provenance.source_id.c_str());
        BSON_APPEND_DATE_TIME(&run_set, "updated_at", now);
        bson_t run_upd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&run_upd, "$set", &run_set);
        bson_t run_reply = BSON_INITIALIZER;
        mongoc_collection_t* runsc = coll(h, "ingestion_runs");
        ok = mongoc_collection_update_one(runsc, &run_q, &run_upd, nullptr, &run_reply, &error);
        const int64_t run_matched = reply_matched(&run_reply);
        bson_destroy(&run_q);
        bson_destroy(&run_set);
        bson_destroy(&run_upd);
        bson_destroy(&run_reply);
        mongoc_collection_destroy(runsc);
        if (!ok || run_matched != 1) {
            fail_created_run(h, run_id, used_lease, "ingestion lease expired before staging");
            if (err) *err = "ingestion lease expired before staging";
            return false;
        }

        mongoc_collection_t* nodes = coll(h, "knowledge_nodes");
        mongoc_collection_t* links = coll(h, "run_node_links");
        std::map<std::string, bson_oid_t> node_oids;
        std::map<std::string, std::vector<std::string>> spans_by_stable;
        auto upsert_node = [&](const std::string& stable, const bson_t* doc) -> bool {
            bson_t q = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&q, "stable_id", stable.c_str());
            BSON_APPEND_UTF8(&q, "version", "v1");
            bson_t upd = BSON_INITIALIZER;
            BSON_APPEND_DOCUMENT(&upd, "$setOnInsert", doc);
            bson_t opts = BSON_INITIALIZER;
            BSON_APPEND_BOOL(&opts, "upsert", true);
            bool wok = mongoc_collection_update_one(nodes, &q, &upd, &opts, nullptr, &error);
            bson_destroy(&q);
            bson_destroy(&upd);
            bson_destroy(&opts);
            if (!wok) return false;
            bson_t fq = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&fq, "stable_id", stable.c_str());
            BSON_APPEND_UTF8(&fq, "version", "v1");
            mongoc_cursor_t* cur = mongoc_collection_find_with_opts(nodes, &fq, nullptr, nullptr);
            const bson_t* found = nullptr;
            if (mongoc_cursor_next(cur, &found)) {
                bson_iter_t nit;
                if (bson_iter_init_find(&nit, found, "_id") && BSON_ITER_HOLDS_OID(&nit)) {
                    node_oids[stable] = *bson_iter_oid(&nit);
                }
            }
            mongoc_cursor_destroy(cur);
            bson_destroy(&fq);
            return true;
        };

        std::map<std::string, Claim> claims_by_stable;
        for (const Claim& claim : payload.claims) {
            std::string span_err;
            if (!validate_evidence_spans(claim.evidence_spans, payload.raw_transcript, &span_err)) {
                mongoc_collection_destroy(nodes);
                mongoc_collection_destroy(links);
                fail_created_run(h, run_id, used_lease, span_err.c_str());
                if (err) *err = span_err;
                return false;
            }
            const std::string stable = claim_stable_id(claim);
            auto it = claims_by_stable.find(stable);
            if (it == claims_by_stable.end()) claims_by_stable[stable] = claim;
            else it->second = merge_claim(it->second, claim);
        }
        for (const auto& kv : claims_by_stable) {
            const Claim& claim = kv.second;
            bson_t doc = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&doc, "stable_id", kv.first.c_str());
            BSON_APPEND_UTF8(&doc, "version", "v1");
            BSON_APPEND_UTF8(&doc, "kind", "claim");
            BSON_APPEND_UTF8(&doc, "sector", claim.type.c_str());
            BSON_APPEND_UTF8(&doc, "content", claim.content.c_str());
            BSON_APPEND_UTF8(&doc, "schema_version", payload.schema_version.c_str());
            BSON_APPEND_UTF8(&doc, "status", payload.trust_tier.c_str());
            BSON_APPEND_DOUBLE(&doc, "confidence", claim.confidence);
            bson_t spans = BSON_INITIALIZER;
            for (std::size_t i = 0; i < claim.evidence_spans.size(); ++i) {
                char idx[16];
                std::snprintf(idx, sizeof idx, "%zu", i);
                BSON_APPEND_UTF8(&spans, idx, claim.evidence_spans[i].c_str());
            }
            BSON_APPEND_ARRAY(&doc, "evidence_spans", &spans);
            BSON_APPEND_DATE_TIME(&doc, "created_at", now);
            bool uok = upsert_node(kv.first, &doc);
            bson_destroy(&spans);
            bson_destroy(&doc);
            if (!uok) {
                mongoc_collection_destroy(nodes);
                mongoc_collection_destroy(links);
                fail_created_run(h, run_id, used_lease, "stage claim");
                return bson_ok(false, error, err, "stage claim");
            }
            spans_by_stable[kv.first] = claim.evidence_spans;
        }
        for (const std::string& concept_text : payload.core_concepts) {
            const std::string stable = kind_stable_id("concept_", concept_text);
            bson_t doc = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&doc, "stable_id", stable.c_str());
            BSON_APPEND_UTF8(&doc, "version", "v1");
            BSON_APPEND_UTF8(&doc, "kind", "concept");
            BSON_APPEND_UTF8(&doc, "sector", "general");
            BSON_APPEND_UTF8(&doc, "content", concept_text.c_str());
            BSON_APPEND_UTF8(&doc, "schema_version", payload.schema_version.c_str());
            BSON_APPEND_UTF8(&doc, "status", payload.trust_tier.c_str());
            BSON_APPEND_DOUBLE(&doc, "confidence", 1.0);
            BSON_APPEND_DATE_TIME(&doc, "created_at", now);
            bool uok = upsert_node(stable, &doc);
            bson_destroy(&doc);
            if (!uok) {
                mongoc_collection_destroy(nodes);
                mongoc_collection_destroy(links);
                fail_created_run(h, run_id, used_lease, "stage concept");
                return bson_ok(false, error, err, "stage concept");
            }
        }
        for (const std::string& opsec : payload.opsec_candidates) {
            const std::string stable = kind_stable_id("opsec_", opsec);
            bson_t doc = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&doc, "stable_id", stable.c_str());
            BSON_APPEND_UTF8(&doc, "version", "v1");
            BSON_APPEND_UTF8(&doc, "kind", "opsec_candidate");
            BSON_APPEND_UTF8(&doc, "sector", "security");
            BSON_APPEND_UTF8(&doc, "content", opsec.c_str());
            BSON_APPEND_UTF8(&doc, "schema_version", payload.schema_version.c_str());
            BSON_APPEND_UTF8(&doc, "status", payload.trust_tier.c_str());
            BSON_APPEND_DOUBLE(&doc, "confidence", 1.0);
            BSON_APPEND_DATE_TIME(&doc, "created_at", now);
            bool uok = upsert_node(stable, &doc);
            bson_destroy(&doc);
            if (!uok) {
                mongoc_collection_destroy(nodes);
                mongoc_collection_destroy(links);
                fail_created_run(h, run_id, used_lease, "stage opsec");
                return bson_ok(false, error, err, "stage opsec");
            }
        }

        for (const auto& kv : node_oids) {
            bson_t lq = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&lq, "run_id", run_id.c_str());
            BSON_APPEND_OID(&lq, "node_id", &kv.second);
            bson_t lset = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&lset, "run_id", run_id.c_str());
            BSON_APPEND_OID(&lset, "node_id", &kv.second);
            BSON_APPEND_UTF8(&lset, "stable_id", kv.first.c_str());
            BSON_APPEND_UTF8(&lset, "node_version", "v1");
            BSON_APPEND_UTF8(&lset, "attempt_token", used_lease.c_str());
            BSON_APPEND_DATE_TIME(&lset, "created_at", now);
            auto spit = spans_by_stable.find(kv.first);
            if (spit != spans_by_stable.end()) {
                bson_t spans = BSON_INITIALIZER;
                for (std::size_t i = 0; i < spit->second.size(); ++i) {
                    char idx[16];
                    std::snprintf(idx, sizeof idx, "%zu", i);
                    BSON_APPEND_UTF8(&spans, idx, spit->second[i].c_str());
                }
                BSON_APPEND_ARRAY(&lset, "evidence_spans", &spans);
                bson_destroy(&spans);
            }
            bson_t lupd = BSON_INITIALIZER;
            BSON_APPEND_DOCUMENT(&lupd, "$setOnInsert", &lset);
            bson_t lopts = BSON_INITIALIZER;
            BSON_APPEND_BOOL(&lopts, "upsert", true);
            ok = mongoc_collection_update_one(links, &lq, &lupd, &lopts, nullptr, &error);
            bson_destroy(&lq);
            bson_destroy(&lset);
            bson_destroy(&lupd);
            bson_destroy(&lopts);
            if (!ok) {
                mongoc_collection_destroy(nodes);
                mongoc_collection_destroy(links);
                fail_created_run(h, run_id, used_lease, "stage link");
                return bson_ok(false, error, err, "stage link");
            }
            ++inserts;
        }
        mongoc_collection_destroy(nodes);
        mongoc_collection_destroy(links);

        if (!transition_run(h, run_id, kRunStaging, kRunValidated, used_lease, nullptr, err)) {
            return false;
        }
        if (!transition_run(h, run_id, kRunValidated, kRunCommitted, used_lease, nullptr, err)) {
            return false;
        }
    }

    if (!project_committed_run(h->client, h->db_name, run_id, err)) {
        if (err) {
            *err = std::string("Committed ingestion RAG projection failed: ") + *err;
        }
        return false;
    }

    receipt->run_id = run_id;
    receipt->record_id = record_id;
    receipt->version = payload.extractor_version;
    receipt->schema_version = payload.schema_version;
    receipt->status = status;
    receipt->insert_count = inserts;
    receipt->update_count = 0;
    receipt->timestamp = utc_now();
    return true;
}

bool store_set_status(
    StoreHandle* h, const StatusJudgment& judgment, JudgmentReceiptOut* receipt, std::string* err) {
    if (h == nullptr || receipt == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    mongoc_collection_t* nodes = coll(h, "knowledge_nodes");
    bson_t q = BSON_INITIALIZER;
    bson_oid_t oid;
    if (judgment.id.size() == 24 && bson_oid_is_valid(judgment.id.c_str(), 24)) {
        bson_oid_init_from_string(&oid, judgment.id.c_str());
        BSON_APPEND_OID(&q, "_id", &oid);
    } else {
        BSON_APPEND_UTF8(&q, "stable_id", judgment.id.c_str());
    }
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(nodes, &q, nullptr, nullptr);
    const bson_t* found = nullptr;
    if (!mongoc_cursor_next(cur, &found)) {
        mongoc_cursor_destroy(cur);
        bson_destroy(&q);
        mongoc_collection_destroy(nodes);
        if (err) *err = "knowledge node not found";
        return false;
    }
    bson_iter_t it;
    std::string from, stable;
    bson_oid_t node_oid;
    if (bson_iter_init_find(&it, found, "status") && BSON_ITER_HOLDS_UTF8(&it)) {
        from = bson_iter_utf8(&it, nullptr);
    }
    if (bson_iter_init_find(&it, found, "stable_id") && BSON_ITER_HOLDS_UTF8(&it)) {
        stable = bson_iter_utf8(&it, nullptr);
    }
    if (bson_iter_init_find(&it, found, "_id") && BSON_ITER_HOLDS_OID(&it)) {
        node_oid = *bson_iter_oid(&it);
    }
    mongoc_cursor_destroy(cur);
    bson_destroy(&q);
    if (!allowed_status_transition(from, judgment.status)) {
        mongoc_collection_destroy(nodes);
        if (err) *err = "status transition is not allowed";
        return false;
    }
    if (from != judgment.status) {
        bson_t uq = BSON_INITIALIZER;
        BSON_APPEND_OID(&uq, "_id", &node_oid);
        BSON_APPEND_UTF8(&uq, "status", from.c_str());
        bson_t set = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&set, "status", judgment.status.c_str());
        bson_t upd = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&upd, "$set", &set);
        bson_t reply = BSON_INITIALIZER;
        bson_error_t error{};
        bool ok = mongoc_collection_update_one(nodes, &uq, &upd, nullptr, &reply, &error);
        const int64_t matched = reply_matched(&reply);
        bson_destroy(&uq);
        bson_destroy(&set);
        bson_destroy(&upd);
        bson_destroy(&reply);
        if (!ok || matched != 1) {
            mongoc_collection_destroy(nodes);
            if (err) *err = "status transition is not allowed";
            return false;
        }
    }
    mongoc_collection_destroy(nodes);

    mongoc_collection_t* judges = coll(h, "node_judgments");
    bson_t jdoc = BSON_INITIALIZER;
    BSON_APPEND_OID(&jdoc, "node_id", &node_oid);
    BSON_APPEND_UTF8(&jdoc, "stable_id", stable.c_str());
    BSON_APPEND_UTF8(&jdoc, "from", from.c_str());
    BSON_APPEND_UTF8(&jdoc, "to", judgment.status.c_str());
    BSON_APPEND_UTF8(&jdoc, "reasoning", normalize_ws(judgment.reasoning).c_str());
    BSON_APPEND_DATE_TIME(&jdoc, "judged_at", utc_millis());
    bson_error_t error{};
    bool jok = mongoc_collection_insert_one(judges, &jdoc, nullptr, nullptr, &error);
    bson_destroy(&jdoc);
    mongoc_collection_destroy(judges);
    if (!jok) return bson_ok(false, error, err, "node_judgments");
    if (!sync_projected_node_status(h->client, h->db_name, node_oid, judgment.status, err)) {
        if (err) *err = std::string("RAG status sync failed: ") + *err;
        return false;
    }

    char oidhex[25];
    bson_oid_to_string(&node_oid, oidhex);
    receipt->node_id = oidhex;
    receipt->stable_id = stable;
    receipt->from = from;
    receipt->to = judgment.status;
    receipt->status = (from == judgment.status) ? "idempotent_noop" : "judged";
    receipt->timestamp = utc_now();
    return true;
}

static std::string trim_store(std::string s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front())) != 0) s.erase(s.begin());
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back())) != 0) s.pop_back();
    return s;
}

static std::string regex_quote_store(const std::string& value) {
    std::string o;
    o.reserve(value.size() * 2);
    for (char c : value) {
        switch (c) {
            case '\\':
            case '.':
            case '+':
            case '*':
            case '?':
            case '(':
            case ')':
            case '[':
            case ']':
            case '{':
            case '}':
            case '|':
            case '^':
            case '$':
                o.push_back('\\');
                o.push_back(c);
                break;
            default:
                o.push_back(c);
        }
    }
    return o;
}

static bool require_passing_skill_run(
    StoreHandle* h,
    const std::string& origin_node_id,
    const std::string& skill_name,
    std::string* run_id,
    std::string* profile,
    std::string* err) {
    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "origin_node_id", origin_node_id.c_str());
    BSON_APPEND_UTF8(&filter, "skill_name", skill_name.c_str());
    bson_t sort = BSON_INITIALIZER;
    BSON_APPEND_INT32(&sort, "created_at", -1);
    BSON_APPEND_INT32(&sort, "_id", -1);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&opts, "sort", &sort);
    BSON_APPEND_INT64(&opts, "limit", 1);
    mongoc_collection_t* c = coll(h, "skill_verification_runs");
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(c, &filter, &opts, nullptr);
    const bson_t* doc = nullptr;
    bool found = mongoc_cursor_next(cur, &doc);
    if (!found) {
        mongoc_cursor_destroy(cur);
        mongoc_collection_destroy(c);
        bson_destroy(&filter);
        bson_destroy(&sort);
        bson_destroy(&opts);
        if (err) *err = "skill has no passing verification run";
        return false;
    }
    std::string result, rid, prof;
    iter_utf8(doc, "result", &result);
    iter_utf8(doc, "run_id", &rid);
    iter_utf8(doc, "verification_profile", &prof);
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(c);
    bson_destroy(&filter);
    bson_destroy(&sort);
    bson_destroy(&opts);
    if (result != kSkillRunPassed) {
        if (err) *err = "latest skill verification run is not passed";
        return false;
    }
    if (skill_profile_apply_only(prof)) {
        if (err) *err = "apply-only verification cannot promote a skill";
        return false;
    }
    if (skill_profile_suite_required(prof)) {
        bson_t sf = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&sf, "origin_node_id", origin_node_id.c_str());
        BSON_APPEND_UTF8(&sf, "skill_name", skill_name.c_str());
        BSON_APPEND_UTF8(&sf, "verification_profile", prof.c_str());
        bson_t ssort = BSON_INITIALIZER;
        BSON_APPEND_INT32(&ssort, "created_at", -1);
        BSON_APPEND_INT32(&ssort, "_id", -1);
        bson_t sopts = BSON_INITIALIZER;
        BSON_APPEND_DOCUMENT(&sopts, "sort", &ssort);
        BSON_APPEND_INT64(&sopts, "limit", 50);
        mongoc_collection_t* sc = coll(h, "skill_verification_runs");
        mongoc_cursor_t* scur = mongoc_collection_find_with_opts(sc, &sf, &sopts, nullptr);
        std::vector<SkillRunLite> runs;
        const bson_t* sdoc = nullptr;
        while (mongoc_cursor_next(scur, &sdoc)) {
            SkillRunLite lite;
            iter_utf8(sdoc, "fixture_id", &lite.fixture_id);
            iter_utf8(sdoc, "result", &lite.result);
            runs.push_back(std::move(lite));
        }
        mongoc_cursor_destroy(scur);
        mongoc_collection_destroy(sc);
        bson_destroy(&sf);
        bson_destroy(&ssort);
        bson_destroy(&sopts);
        if (current_passing_fixture_count(runs) < 2) {
            if (err) *err = "broad skill needs passing runs on two fixtures";
            return false;
        }
    }
    if (run_id) *run_id = rid;
    if (profile) *profile = prof;
    return true;
}

bool store_record_skill_run(
    StoreHandle* h, const RecordSkillRunRequest& request, SkillRunReceiptOut* receipt, std::string* err) {
    if (h == nullptr || receipt == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    if (!validate_record_skill_run(request, err)) return false;
    if (!ensure_indexes(h, err)) return false;
    std::string origin = trim_store(request.origin_node_id);
    std::string fixture = trim_store(request.fixture_id);
    std::string run_id = new_uuid();
    mongoc_collection_t* c = coll(h, "skill_verification_runs");
    bson_t doc = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&doc, "run_id", run_id.c_str());
    BSON_APPEND_UTF8(&doc, "skill_name", request.skill_name.c_str());
    BSON_APPEND_UTF8(&doc, "origin_node_id", origin.c_str());
    BSON_APPEND_UTF8(&doc, "fixture_id", fixture.c_str());
    BSON_APPEND_UTF8(&doc, "suite_id", trim_store(request.suite_id).c_str());
    BSON_APPEND_UTF8(&doc, "verification_profile", request.verification_profile.c_str());
    BSON_APPEND_UTF8(&doc, "verification_version", trim_store(request.verification_version).c_str());
    BSON_APPEND_UTF8(&doc, "environment_hash", trim_store(request.environment_hash).c_str());
    BSON_APPEND_UTF8(&doc, "result", request.result.c_str());
    bson_t checks = BSON_INITIALIZER;
    for (const auto& kv : request.checks) {
        BSON_APPEND_UTF8(&checks, kv.first.c_str(), kv.second.c_str());
    }
    BSON_APPEND_DOCUMENT(&doc, "checks", &checks);
    BSON_APPEND_UTF8(&doc, "artifact_hash", trim_store(request.artifact_hash).c_str());
    BSON_APPEND_UTF8(&doc, "log_excerpt", request.log_excerpt.c_str());
    BSON_APPEND_UTF8(&doc, "reasoning", trim_store(request.reasoning).c_str());
    BSON_APPEND_DATE_TIME(&doc, "created_at", utc_millis());
    bson_error_t error{};
    bool ok = mongoc_collection_insert_one(c, &doc, nullptr, nullptr, &error);
    bson_destroy(&checks);
    bson_destroy(&doc);
    mongoc_collection_destroy(c);
    if (!ok) return bson_ok(false, error, err, "skill_verification_runs");
    receipt->run_id = run_id;
    receipt->skill_name = request.skill_name;
    receipt->origin_node_id = origin;
    receipt->result = request.result;
    receipt->status = "recorded";
    receipt->timestamp = utc_now();
    return true;
}

bool store_promote_skill(
    StoreHandle* h, const PromoteSkillRequest& request, PromoteSkillReceiptOut* receipt, std::string* err) {
    if (h == nullptr || receipt == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    if (!validate_promote_skill(request, err)) return false;
    if (!ensure_indexes(h, err)) return false;
    std::string origin = trim_store(request.origin_node_id);
    bson_t node_q = BSON_INITIALIZER;
    if (origin.size() == 24 && bson_oid_is_valid(origin.c_str(), 24)) {
        bson_oid_t oid;
        bson_oid_init_from_string(&oid, origin.c_str());
        BSON_APPEND_OID(&node_q, "_id", &oid);
    } else {
        BSON_APPEND_UTF8(&node_q, "_id", origin.c_str());
    }
    mongoc_collection_t* nodes = coll(h, "knowledge_nodes");
    mongoc_cursor_t* ncur = mongoc_collection_find_with_opts(nodes, &node_q, nullptr, nullptr);
    const bson_t* node = nullptr;
    if (!mongoc_cursor_next(ncur, &node)) {
        mongoc_cursor_destroy(ncur);
        mongoc_collection_destroy(nodes);
        bson_destroy(&node_q);
        if (err) *err = "knowledge node not found";
        return false;
    }
    bson_oid_t node_oid{};
    bson_iter_t it;
    if (!bson_iter_init_find(&it, node, "_id") || !BSON_ITER_HOLDS_OID(&it)) {
        mongoc_cursor_destroy(ncur);
        mongoc_collection_destroy(nodes);
        bson_destroy(&node_q);
        if (err) *err = "knowledge node not found";
        return false;
    }
    node_oid = *bson_iter_oid(&it);
    std::string status, version, content;
    iter_utf8(node, "status", &status);
    iter_utf8(node, "version", &version);
    iter_utf8(node, "content", &content);
    mongoc_cursor_destroy(ncur);
    mongoc_collection_destroy(nodes);
    bson_destroy(&node_q);

    bson_t link_q = BSON_INITIALIZER;
    BSON_APPEND_OID(&link_q, "node_id", &node_oid);
    mongoc_collection_t* links = coll(h, "run_node_links");
    mongoc_cursor_t* lcur = mongoc_collection_find_with_opts(links, &link_q, nullptr, nullptr);
    std::vector<std::string> run_ids;
    const bson_t* link = nullptr;
    while (mongoc_cursor_next(lcur, &link)) {
        std::string rid;
        if (iter_utf8(link, "run_id", &rid) && !rid.empty()) run_ids.push_back(rid);
    }
    mongoc_cursor_destroy(lcur);
    mongoc_collection_destroy(links);
    bson_destroy(&link_q);
    if (run_ids.empty()) {
        if (err) *err = "origin node is not linked to a committed ingestion run";
        return false;
    }
    bson_t in_arr = BSON_INITIALIZER;
    for (size_t i = 0; i < run_ids.size(); ++i) {
        char idx[16];
        std::snprintf(idx, sizeof idx, "%zu", i);
        BSON_APPEND_UTF8(&in_arr, idx, run_ids[i].c_str());
    }
    bson_t in = BSON_INITIALIZER;
    BSON_APPEND_ARRAY(&in, "$in", &in_arr);
    bson_t run_q = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&run_q, "run_id", &in);
    BSON_APPEND_UTF8(&run_q, "status", "committed");
    mongoc_collection_t* runs = coll(h, "ingestion_runs");
    bson_error_t error{};
    int64_t committed = mongoc_collection_count_documents(runs, &run_q, nullptr, nullptr, nullptr, &error);
    mongoc_collection_destroy(runs);
    bson_destroy(&run_q);
    bson_destroy(&in);
    bson_destroy(&in_arr);
    if (committed < 1) {
        if (err) *err = "origin node is not linked to a committed ingestion run";
        return false;
    }
    if (status != kStatusVerified) {
        if (err) *err = "skill origin node is not verified";
        return false;
    }
    if (version != trim_store(request.origin_version)) {
        if (err) *err = "origin node version mismatch";
        return false;
    }
    std::string expected_hash = keccak256_hex(content);
    if (expected_hash != trim_store(request.origin_hash)) {
        if (err) *err = "skill origin node hash mismatch";
        return false;
    }
    if (!request.content.empty() && request.content != content) {
        if (err) *err = "promoted content must match the origin node";
        return false;
    }
    std::string pass_id, pass_profile;
    if (!require_passing_skill_run(h, origin, request.name, &pass_id, &pass_profile, err)) return false;
    if (!request.verification_profile.empty() && request.verification_profile != pass_profile) {
        if (err) *err = "verification_profile does not match the passing run";
        return false;
    }
    std::string again_id, again_profile;
    if (!require_passing_skill_run(h, origin, request.name, &again_id, &again_profile, err)) return false;
    if (again_id != pass_id) {
        if (err) *err = "latest skill verification run is not passed";
        return false;
    }

    bson_t filter = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&filter, "name", request.name.c_str());
    bson_t set = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set, "version", "v1");
    BSON_APPEND_UTF8(&set, "content", content.c_str());
    BSON_APPEND_UTF8(&set, "origin_node_id", origin.c_str());
    BSON_APPEND_UTF8(&set, "origin_version", trim_store(request.origin_version).c_str());
    BSON_APPEND_UTF8(&set, "origin_hash", trim_store(request.origin_hash).c_str());
    BSON_APPEND_UTF8(&set, "schema_version", request.schema_version.c_str());
    BSON_APPEND_UTF8(&set, "verification_profile", pass_profile.c_str());
    BSON_APPEND_UTF8(&set, "verification_run_id", pass_id.c_str());
    bson_t set_on = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&set_on, "name", request.name.c_str());
    BSON_APPEND_DATE_TIME(&set_on, "created_at", utc_millis());
    bson_t upd = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&upd, "$set", &set);
    BSON_APPEND_DOCUMENT(&upd, "$setOnInsert", &set_on);
    mongoc_find_and_modify_opts_t* fm = mongoc_find_and_modify_opts_new();
    mongoc_find_and_modify_opts_set_update(fm, &upd);
    mongoc_find_and_modify_opts_set_flags(
        fm,
        static_cast<mongoc_find_and_modify_flags_t>(
            MONGOC_FIND_AND_MODIFY_UPSERT | MONGOC_FIND_AND_MODIFY_RETURN_NEW));
    mongoc_collection_t* skills = coll(h, "skills");
    bson_t reply = BSON_INITIALIZER;
    bool ok = mongoc_collection_find_and_modify_with_opts(skills, &filter, fm, &reply, &error);
    mongoc_find_and_modify_opts_destroy(fm);
    std::string skill_id;
    if (!ok && error.code == 11000) {
        bson_destroy(&reply);
        bson_t again_q = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&again_q, "name", request.name.c_str());
        mongoc_cursor_t* acur = mongoc_collection_find_with_opts(skills, &again_q, nullptr, nullptr);
        const bson_t* adoc = nullptr;
        if (mongoc_cursor_next(acur, &adoc) && bson_iter_init_find(&it, adoc, "_id") && BSON_ITER_HOLDS_OID(&it)) {
            char hex[25];
            bson_oid_to_string(bson_iter_oid(&it), hex);
            skill_id = hex;
            ok = true;
        }
        mongoc_cursor_destroy(acur);
        bson_destroy(&again_q);
    } else if (ok) {
        bson_iter_t vit;
        if (bson_iter_init_find(&vit, &reply, "value") && BSON_ITER_HOLDS_DOCUMENT(&vit)) {
            uint32_t len = 0;
            const uint8_t* data = nullptr;
            bson_iter_document(&vit, &len, &data);
            bson_t value_doc;
            if (bson_init_static(&value_doc, data, len) && bson_iter_init_find(&it, &value_doc, "_id") &&
                BSON_ITER_HOLDS_OID(&it)) {
                char hex[25];
                bson_oid_to_string(bson_iter_oid(&it), hex);
                skill_id = hex;
            }
        }
        bson_destroy(&reply);
    } else {
        bson_destroy(&reply);
    }
    mongoc_collection_destroy(skills);
    bson_destroy(&filter);
    bson_destroy(&set);
    bson_destroy(&set_on);
    bson_destroy(&upd);
    if (!ok) return bson_ok(false, error, err, "skills upsert");
    receipt->skill_id = skill_id;
    receipt->name = request.name;
    receipt->origin_node_id = origin;
    receipt->status = "promoted";
    receipt->timestamp = utc_now();
    return true;
}

bool store_query_skills(
    StoreHandle* h, const QuerySkillsRequest& request, QuerySkillsReceiptOut* receipt, std::string* err) {
    if (h == nullptr || receipt == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    if (!validate_query_skills(request, err)) return false;
    int limit = request.limit;
    if (limit <= 0) limit = 5;
    if (limit > 25) limit = 25;
    std::string query = trim_store(request.query);
    bson_t* filter = nullptr;
    bson_t empty = BSON_INITIALIZER;
    if (query.empty()) {
        filter = &empty;
    } else {
        std::string pattern = regex_quote_store(query);
        std::ostringstream fj;
        fj << "{\"$or\":[{\"name\":{\"$regex\":\"" << json_escape_local(pattern)
           << "\",\"$options\":\"i\"}},{\"content\":{\"$regex\":\"" << json_escape_local(pattern)
           << "\",\"$options\":\"i\"}}]}";
        bson_error_t error{};
        filter = bson_new_from_json(
            reinterpret_cast<const uint8_t*>(fj.str().data()), static_cast<ssize_t>(fj.str().size()), &error);
        if (filter == nullptr) {
            bson_destroy(&empty);
            if (err) *err = error.message;
            return false;
        }
    }
    bson_t sort = BSON_INITIALIZER;
    BSON_APPEND_INT32(&sort, "created_at", -1);
    bson_t opts = BSON_INITIALIZER;
    BSON_APPEND_DOCUMENT(&opts, "sort", &sort);
    BSON_APPEND_INT64(&opts, "limit", static_cast<int64_t>(limit));
    mongoc_collection_t* skills = coll(h, "skills");
    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(skills, filter, &opts, nullptr);
    const bson_t* doc = nullptr;
    while (mongoc_cursor_next(cur, &doc)) {
        QuerySkillHit hit;
        iter_utf8(doc, "name", &hit.name);
        iter_utf8(doc, "content", &hit.content);
        if (!iter_utf8(doc, "origin_node_id", &hit.origin_node_id)) {
            bson_iter_t nit;
            if (bson_iter_init_find(&nit, doc, "origin_node_id") && BSON_ITER_HOLDS_OID(&nit)) {
                char hex[25];
                bson_oid_to_string(bson_iter_oid(&nit), hex);
                hit.origin_node_id = hex;
            }
        }
        iter_utf8(doc, "origin_hash", &hit.origin_hash);
        iter_utf8(doc, "verification_profile", &hit.verification_profile);
        if (!hit.name.empty()) receipt->skills.push_back(std::move(hit));
    }
    bson_error_t error{};
    bool cerr = mongoc_cursor_error(cur, &error);
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(skills);
    bson_destroy(&sort);
    bson_destroy(&opts);
    if (filter != &empty) bson_destroy(filter);
    bson_destroy(&empty);
    if (cerr) {
        if (err) *err = error.message;
        return false;
    }
    receipt->status = "ok";
    receipt->count = static_cast<int>(receipt->skills.size());
    receipt->timestamp = utc_now();
    return true;
}

bool store_rebuild(StoreHandle* h, std::string* json_out, std::string* err) {
    if (h == nullptr || json_out == nullptr) {
        if (err) *err = "store not open";
        return false;
    }
    RagRebuildReport report;
    if (!rebuild_rag_projection(h->client, h->db_name, &report, err)) return false;
    *json_out = rag_rebuild_report_json(report);
    return true;
}

#endif

}  // namespace godbrain::memory
