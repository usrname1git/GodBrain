#include "godbrain/memory_store/evidence.hpp"
#include "../../cpp_kernel/json.hpp"

#include <algorithm>
#include <chrono>
#include <memory>
#include <stdexcept>
#if defined(GODBRAIN_HAVE_MONGOC)
#include <mongoc/mongoc.h>
#endif

namespace godbrain::memory {
using json = nlohmann::ordered_json;

std::string evidence_binding(const std::string& node, const std::string& version,
                             const std::string& content) {
    return keccak256_hex(node + '\0' + version + '\0' + keccak256_hex(content));
}

std::int64_t evidence_backoff(int attempts) {
    if (attempts >= kEvidenceAttempts) return kDocumentTtlMs;
    return 60000LL << (std::max)(0, (std::min)(attempts - 1, 4));
}

bool evidence_window(const std::string& profile, std::int64_t checked, std::int64_t expires,
                     std::int64_t now) {
    const auto ttl = profile == "host" ? kHostTtlMs : kDocumentTtlMs;
    return (profile == "host" || profile == "document") && checked > 0 && checked <= now &&
           checked <= INT64_MAX - ttl && expires == checked + ttl && expires > now;
}

bool validate_evidence_request(const EvidenceRequest& r, std::string* error) {
    const auto hex = [](const std::string& value) {
        return value.size() == 64 &&
               value.find_first_not_of("0123456789abcdef") == std::string::npos;
    };
    bool valid = r.command == "evidence";
    if (r.action == "next" || r.action == "status") {
        valid = valid && r.id.empty() && r.lease_token.empty() && r.outcome.empty() &&
                r.reason.empty() && r.observed_hash.empty() && r.successor.empty();
    } else if (r.action == "complete") {
        valid = valid && hex(r.id) && r.lease_token.size() == 24 &&
                r.lease_token.find_first_not_of("0123456789abcdef") == std::string::npos &&
                (r.outcome == "fresh" || r.outcome == "changed" || r.outcome == "unavailable" ||
                 r.outcome == "unsupported") &&
                !r.reason.empty() && r.reason.size() <= 128 &&
                r.reason.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_-") ==
                    std::string::npos &&
                (r.observed_hash.empty() || hex(r.observed_hash)) &&
                (r.successor.empty() || (r.outcome == "changed" && hex(r.successor)));
        if (r.outcome == "fresh" || r.outcome == "changed") valid = valid && hex(r.observed_hash);
    } else {
        valid = false;
    }
    if (!valid && error) *error = "invalid evidence command";
    return valid;
}

#if defined(GODBRAIN_HAVE_MONGOC)
namespace {
std::int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

json oid(const std::string& value) {
    return {{"$oid", value}};
}

struct BsonFree {
    void operator()(bson_t* value) const {
        if (value) bson_destroy(value);
    }
};
using Bson = std::unique_ptr<bson_t, BsonFree>;

Bson bson(const json& value) {
    const auto bytes = value.dump();
    bson_error_t error{};
    Bson result(bson_new_from_json(reinterpret_cast<const uint8_t*>(bytes.data()),
                                   static_cast<ssize_t>(bytes.size()), &error));
    if (!result) throw std::runtime_error(std::string("evidence BSON: ") + error.message);
    return result;
}

json decode(const bson_t* value) {
    size_t length = 0;
    char* bytes = bson_as_relaxed_extended_json(value, &length);
    if (!bytes) throw std::runtime_error("evidence BSON decode failed");
    const std::unique_ptr<char, decltype(&bson_free)> owned(bytes, bson_free);
    return json::parse(bytes, bytes + length);
}

struct Database {
    mongoc_client_t* client;
    std::string name;

    json find(const char* collection, const json& filter,
              const json& options = json::object()) const {
        auto query = bson(filter);
        auto bounded_options = options;
        bounded_options["maxTimeMS"] = 3000;
        auto opts = bson(bounded_options);
        const std::unique_ptr<mongoc_collection_t, decltype(&mongoc_collection_destroy)> coll(
            mongoc_client_get_collection(client, name.c_str(), collection),
            mongoc_collection_destroy);
        const std::unique_ptr<mongoc_cursor_t, decltype(&mongoc_cursor_destroy)> cursor(
            mongoc_collection_find_with_opts(coll.get(), query.get(), opts.get(), nullptr),
            mongoc_cursor_destroy);
        json result = json::array();
        const bson_t* row = nullptr;
        while (mongoc_cursor_next(cursor.get(), &row))
            result.push_back(decode(row));
        bson_error_t error{};
        const bool failed = mongoc_cursor_error(cursor.get(), &error);
        if (failed) throw std::runtime_error(std::string("evidence read: ") + error.message);
        return result;
    }

    json aggregate(const char* collection, const json& pipeline) const {
        auto query = bson(json{{"pipeline", pipeline}});
        auto opts = bson(json{{"maxTimeMS", 3000}});
        const std::unique_ptr<mongoc_collection_t, decltype(&mongoc_collection_destroy)> coll(
            mongoc_client_get_collection(client, name.c_str(), collection),
            mongoc_collection_destroy);
        const std::unique_ptr<mongoc_cursor_t, decltype(&mongoc_cursor_destroy)> cursor(
            mongoc_collection_aggregate(coll.get(), MONGOC_QUERY_NONE, query.get(), opts.get(),
                                        nullptr),
            mongoc_cursor_destroy);
        json result = json::array();
        const bson_t* row = nullptr;
        while (mongoc_cursor_next(cursor.get(), &row))
            result.push_back(decode(row));
        bson_error_t error{};
        const bool failed = mongoc_cursor_error(cursor.get(), &error);
        if (failed) throw std::runtime_error(std::string("evidence join: ") + error.message);
        return result;
    }

    json command(const json& input) const {
        auto bounded_input = input;
        bounded_input["maxTimeMS"] = 3000;
        auto query = bson(bounded_input);
        const Bson reply(bson_new());
        bson_error_t error{};
        const bool ok = mongoc_client_command_simple(client, name.c_str(), query.get(), nullptr,
                                                     reply.get(), &error);
        const auto result = decode(reply.get());
        if (!ok) throw std::runtime_error(std::string("evidence write: ") + error.message);
        if (result.contains("writeErrors") && !result["writeErrors"].empty())
            throw std::runtime_error("evidence write rejected: " + result["writeErrors"].dump());
        if (result.contains("writeConcernError"))
            throw std::runtime_error("evidence write concern failed");
        return result;
    }

    void update(const char* collection, const json& filter, const json& change,
                bool upsert = false) const {
        command(json{
            {"update", collection},
            {"updates", json::array({json{{"q", filter}, {"u", change}, {"upsert", upsert}}})}});
    }
};

json committed_source(const Database& db, const std::string& node, const std::string& run = "",
                      const std::string& hash = "") {
    json match = {{"node_id", oid(node)}};
    if (!run.empty()) match["run_id"] = run;
    json run_match = {{"run.status", "committed"}};
    if (!hash.empty()) run_match["run.source_hash"] = hash;
    const auto rows = db.aggregate(
        "run_node_links",
        json::array({json{{"$match", match}},
                     json{{"$lookup",
                           {{"from", "ingestion_runs"},
                            {"localField", "run_id"},
                            {"foreignField", "run_id"},
                            {"as", "run"}}}},
                     json{{"$unwind", "$run"}}, json{{"$match", run_match}},
                     json{{"$sort", {{"run.created_at", -1}, {"run.run_id", 1}}}},
                     json{{"$limit", 1}}, json{{"$replaceRoot", {{"newRoot", "$run"}}}}}));
    return rows.empty() ? json() : rows.front();
}

bool canonical(const Database& db, const json& row) {
    const auto node = db.find("knowledge_nodes", {{"_id", row.at("node_id")}}, {{"limit", 1}});
    if (node.empty()) return false;
    const auto& n = node.front();
    return n.value("status", "") == "verified" && n.value("sector", "") != "personal" &&
           n.value("sector", "") == row.at("sector") &&
           n.value("stable_id", "") == row.at("stable_id") &&
           n.value("version", "") == row.at("node_version") &&
           keccak256_hex(n.value("content", "")) == row.at("content_hash") &&
           !committed_source(db, row.at("node_id").at("$oid").get<std::string>(),
                             row.at("source_run").get<std::string>(),
                             row.at("source_hash").get<std::string>())
                .is_null();
}

void enroll(const Database& db, std::int64_t now) {
    const auto state = db.find("evidence_maintenance", {{"_id", "scan"}}, {{"limit", 1}});
    json filter = {{"status", "verified"}, {"sector", {{"$ne", "personal"}}}};
    if (!state.empty() && state.front().contains("after"))
        filter["_id"] = {{"$gt", state.front().at("after")}};
    const auto nodes = db.find("knowledge_nodes", filter, {{"sort", {{"_id", 1}}}, {"limit", 32}});
    for (const auto& node : nodes) {
        const std::string id = node.at("_id").at("$oid");
        const auto run = committed_source(db, id);
        if (run.is_null()) continue;
        const auto content = node.value("content", "");
        const auto version = node.value("version", "");
        const auto binding = evidence_binding(id, version, content);
        db.update("evidence_checks", {{"_id", binding}},
                  {{"$setOnInsert",
                    {{"node_id", oid(id)},
                     {"node_version", version},
                     {"content_hash", keccak256_hex(content)},
                     {"stable_id", node.value("stable_id", "")},
                     {"sector", node.value("sector", "")},
                     {"source_run", run.at("run_id")},
                     {"source_hash", run.at("source_hash")},
                     {"source_url", run.value("external_source_id", "")},
                     {"state", "pending"},
                     {"profile", "unsupported"},
                     {"attempts", 0},
                     {"next_check_ms", now},
                     {"lease_until_ms", 0},
                     {"checked_at_ms", 0},
                     {"expires_at_ms", 0},
                     {"reason", "awaiting_check"}}}},
                  true);
    }
    if (nodes.empty())
        db.update("evidence_maintenance", {{"_id", "scan"}}, {{"$unset", {{"after", ""}}}}, true);
    else
        db.update("evidence_maintenance", {{"_id", "scan"}},
                  {{"$set", {{"after", nodes.back().at("_id")}}}}, true);
}

std::string profile(const json& source, const json& row) {
    const auto raw = source.value("content", "");
    if (source.value("source_type", "") == "kernel_truth_observation") {
        const auto parsed = json::parse(raw, nullptr, false);
        if (parsed.is_object() && parsed.value("profile", "") == "truth-observation-v1" &&
            parsed.value("checker_version", "") == "1.0.0" && parsed.contains("observation") &&
            parsed["observation"].is_object()) {
            const auto kind = parsed["observation"].value("kind", "");
            if (kind == "document_quote_presence") return "document";
            if (kind == "host_probe_observation") return "host";
        }
        return "unsupported";
    }
    if (raw.rfind("Windows host inventory\nclaim_class=host_fact\n", 0) == 0) return "host";
    const auto url = row.value("source_url", "");
    if (url.rfind("https://learn.microsoft.com/", 0) == 0 ||
        url.rfind("https://support.microsoft.com/", 0) == 0)
        return "document";
    return "unsupported";
}

json next(const Database& db) {
    const auto now = now_ms();
    db.update("evidence_maintenance", {{"_id", "policy"}},
              {{"$setOnInsert", {{"version", kEvidenceVersion}}}}, true);
    const auto policy = db.find("evidence_maintenance", {{"_id", "policy"}}, {{"limit", 1}});
    if (policy.empty() || policy.front().value("version", "") != kEvidenceVersion)
        throw std::runtime_error("unsupported evidence maintenance policy");
    db.command({{"update", "evidence_checks"},
                {"updates", json::array({json{{"q",
                                               {{"lease_token", {{"$exists", true}}},
                                                {"lease_until_ms", {{"$lte", now}}},
                                                {"attempts", {{"$gte", kEvidenceAttempts}}}}},
                                              {"u",
                                               {{"$set",
                                                 {{"state", "exception"},
                                                  {"reason", "worker_interrupted"},
                                                  {"next_check_ms", now + kDocumentTtlMs},
                                                  {"lease_until_ms", 0}}},
                                                {"$unset", {{"lease_token", ""}}}}},
                                              {"multi", true}}})}});
    enroll(db, now);
    db.command(
        {{"createIndexes", "evidence_checks"},
         {"indexes",
          json::array({json{{"name", "evidence_due"},
                            {"key", {{"next_check_ms", 1}, {"lease_until_ms", 1}, {"_id", 1}}}},
                       json{{"name", "evidence_origin"},
                            {"key", {{"node_id", 1}, {"node_version", 1}}}}})}});
    bson_oid_t token;
    bson_oid_init(&token, nullptr);
    char hex[25];
    bson_oid_to_string(&token, hex);
    const auto reply = db.command(
        {{"findAndModify", "evidence_checks"},
         {"query", {{"next_check_ms", {{"$lte", now}}}, {"lease_until_ms", {{"$lte", now}}}}},
         {"sort", {{"next_check_ms", 1}, {"_id", 1}}},
         {"update",
          {{"$set", {{"lease_token", hex}, {"lease_until_ms", now + kEvidenceLeaseMs}}},
           {"$inc", {{"attempts", 1}}}}},
         {"new", true}});
    if (!reply.contains("value") || reply["value"].is_null()) return {{"status", "idle"}};
    auto row = reply["value"];
    const auto sources =
        db.find("sources", {{"source_hash", row.at("source_hash")}}, {{"limit", 1}});
    row["source_type"] = sources.empty() ? "" : sources.front().value("source_type", "");
    row["raw_source"] = sources.empty() ? "" : sources.front().value("content", "");
    row["profile"] = sources.empty() ? "unsupported" : profile(sources.front(), row);
    row["canonical"] = canonical(db, row);
    row["source_valid"] =
        !sources.empty() &&
        keccak256_hex(row.at("raw_source").get<std::string>()) == row.at("source_hash");
    db.update("evidence_checks", {{"_id", row.at("_id")}, {"lease_token", hex}},
              {{"$set", {{"profile", row.at("profile")}}}});
    row["node_id"] = row.at("node_id").at("$oid");
    return {{"status", "leased"}, {"job", row}};
}

json complete(const Database& db, const EvidenceRequest& request) {
    const auto rows = db.find("evidence_checks", {{"_id", request.id}}, {{"limit", 1}});
    if (rows.empty()) throw std::runtime_error("evidence lease not found");
    const auto& row = rows.front();
    auto now = now_ms();
    const json result = {{"outcome", request.outcome},
                         {"reason", request.reason},
                         {"observed_hash", request.observed_hash},
                         {"successor", request.successor}};
    if (row.value("last_token", "") == request.lease_token &&
        nlohmann::json::parse(row.value("last_result", json()).dump()) ==
            nlohmann::json::parse(result.dump()))
        return {{"status", "idempotent_noop"}, {"id", request.id}, {"state", row.at("state")}};
    if (row.value("lease_token", "") != request.lease_token ||
        row.value("lease_until_ms", std::int64_t{0}) <= now ||
        ((request.outcome == "fresh" || request.outcome == "changed") && !canonical(db, row)))
        throw std::runtime_error("evidence lease expired or origin changed");
    const auto kind = row.value("profile", "unsupported");
    if (request.outcome == "fresh" &&
        ((kind != "host" && kind != "document") || request.observed_hash != row.at("source_hash")))
        throw std::runtime_error("unsupported or mismatched evidence cannot be made fresh");
    const bool fresh = request.outcome == "fresh";
    const int attempts = row.value("attempts", 1);
    const auto ttl = kind == "host" ? kHostTtlMs : kDocumentTtlMs;
    const std::string state = fresh                           ? "fresh"
                              : request.outcome == "changed"  ? "changed"
                              : attempts >= kEvidenceAttempts ? "exception"
                                                              : "retry";
    json history = result;
    history.update({{"binding_id", request.id},
                    {"node_id", row.at("node_id")},
                    {"node_version", row.at("node_version")},
                    {"content_hash", row.at("content_hash")},
                    {"source_hash", row.at("source_hash")},
                    {"source_run", row.at("source_run")},
                    {"checked_at_ms", now},
                    {"profile", kind},
                    {"maintenance_version", kEvidenceVersion}});
    db.update("evidence_check_runs", {{"_id", request.lease_token}}, {{"$setOnInsert", history}},
              true);
    const auto saved =
        db.find("evidence_check_runs", {{"_id", request.lease_token}}, {{"limit", 1}});
    if (saved.empty()) throw std::runtime_error("evidence proof was not retained");
    for (const auto& field : history.items()) {
        if (field.key() != "checked_at_ms" && (!saved.front().contains(field.key()) ||
                                               saved.front().at(field.key()) != field.value()))
            throw std::runtime_error("conflicting evidence result for the same lease");
    }
    now = saved.front().at("checked_at_ms").get<std::int64_t>();
    const auto due = fresh                          ? now + ttl / 2
                     : !request.successor.empty()   ? INT64_MAX / 2
                     : request.outcome == "changed" ? now + kDocumentTtlMs
                                                    : now + evidence_backoff(attempts);
    const auto updated = db.command({{"findAndModify", "evidence_checks"},
                                     {"query",
                                      {{"_id", request.id},
                                       {"lease_token", request.lease_token},
                                       {"lease_until_ms", {{"$gt", now_ms()}}}}},
                                     {"update",
                                      {{"$set",
                                        {{"state", state},
                                         {"reason", request.reason},
                                         {"checked_at_ms", now},
                                         {"expires_at_ms", fresh ? now + ttl : 0},
                                         {"next_check_ms", due},
                                         {"lease_until_ms", 0},
                                         {"attempts", fresh ? 0 : attempts},
                                         {"last_token", request.lease_token},
                                         {"last_result", result},
                                         {"maintenance_version", kEvidenceVersion}}},
                                       {"$unset", {{"lease_token", ""}}}}},
                                     {"new", true}});
    if (!updated.contains("value") || updated["value"].is_null())
        throw std::runtime_error("evidence result lost its lease");
    return {{"status", "recorded"},
            {"id", request.id},
            {"state", state},
            {"expires_at_ms", fresh ? now + ttl : 0},
            {"next_check_ms", due},
            {"attempts", fresh ? 0 : attempts},
            {"escalated", state == "exception"}};
}

json status(const Database& db) {
    const auto now = now_ms();
    const auto counts = db.aggregate(
        "evidence_checks",
        json::array(
            {json{{"$group",
                   {{"_id",
                     {{"$cond",
                       json::array(
                           {json{{"$and",
                                  json::array(
                                      {json{{"$eq", json::array({"$state", "fresh"})}},
                                       json{{"$lte", json::array({"$expires_at_ms", now})}}})}},
                            "expired", "$state"})}}},
                    {"count", {{"$sum", 1}}}}}},
             json{{"$sort", {{"_id", 1}}}}}));
    const auto incidents = db.aggregate(
        "evidence_checks",
        json::array({json{{"$match", {{"state", "exception"}}}},
                     json{{"$group",
                           {{"_id", {{"reason", "$reason"}, {"source", "$source_hash"}}},
                            {"count", {{"$sum", 1}}},
                            {"example", {{"$min", "$stable_id"}}}}}},
                     json{{"$sort", {{"count", -1}, {"_id", 1}}}}, json{{"$limit", 8}}}));
    const auto policy = db.find("evidence_maintenance", {{"_id", "policy"}}, {{"limit", 1}});
    if (!policy.empty() && policy.front().value("version", "") != kEvidenceVersion)
        throw std::runtime_error("unsupported evidence maintenance policy");
    return {{"status", "ok"},
            {"enforced", !policy.empty()},
            {"counts", counts},
            {"incidents", incidents},
            {"at_ms", now}};
}
} // namespace
#endif

bool evidence_command(_mongoc_client_t* client, const std::string& db,
                      const EvidenceRequest& request, std::string* receipt, std::string* error) {
    if (!validate_evidence_request(request, error)) return false;
#if defined(GODBRAIN_HAVE_MONGOC)
    try {
        const Database database{client, db};
        *receipt = (request.action == "next"       ? next(database)
                    : request.action == "complete" ? complete(database, request)
                                                   : status(database))
                       .dump() +
                   '\n';
        return true;
    } catch (const std::exception& failure) {
        if (error) *error = failure.what();
        return false;
    }
#else
    (void)client;
    (void)db;
    (void)receipt;
    if (error) *error = "mongo-c-driver not linked";
    return false;
#endif
}

bool evidence_search_pipeline(_mongoc_client_t* client, const std::string& db,
                              const std::string& filter, const std::string& options,
                              std::string* pipeline, std::string* error) {
    pipeline->clear();
#if defined(GODBRAIN_HAVE_MONGOC)
    try {
        const Database database{client, db};
        const auto policy =
            database.find("evidence_maintenance", {{"_id", "policy"}}, {{"limit", 1}});
        if (policy.empty()) return true;
        if (policy.front().value("version", "") != kEvidenceVersion)
            throw std::runtime_error("unsupported evidence maintenance policy");
        const auto now = now_ms();
        const auto window = [](const char* profile, std::int64_t ttl) {
            return json{
                {"$and",
                 json::array({json{{"$eq", json::array({"$profile", profile})}},
                              json{{"$eq", json::array({"$expires_at_ms",
                                                        json{{"$add", json::array({"$checked_at_ms",
                                                                                   ttl})}}})}}})}};
        };
        auto stages = json::array(
            {json{{"$match", json::parse(filter)}},
             json{
                 {"$lookup",
                  {{"from", "evidence_checks"},
                   {"let", {{"node", "$node_id"}, {"version", "$node_version"}}},
                   {"pipeline",
                    json::array(
                        {json{
                             {"$match",
                              {{"state", "fresh"},
                               {"maintenance_version", kEvidenceVersion},
                               {"checked_at_ms", {{"$gt", 0}, {"$lte", now}}},
                               {"expires_at_ms", {{"$gt", now}}},
                               {"$expr",
                                {{"$and",
                                  json::array(
                                      {json{{"$eq", json::array({"$node_id", "$$node"})}},
                                       json{{"$eq", json::array({"$node_version", "$$version"})}},
                                       json{{"$or", json::array({window("host", kHostTtlMs),
                                                                 window("document",
                                                                        kDocumentTtlMs)})}}})}}}}}},
                         json{{"$limit", 1}}})},
                   {"as", "_current_evidence"}}}},
             json{{"$match",
                   {{"$or", json::array({json{{"status", {{"$ne", "verified"}}}},
                                         json{{"sector", "personal"}},
                                         json{{"_current_evidence.0", {{"$exists", true}}}}})}}}},
             json{{"$unset", "_current_evidence"}}});
        const auto opts = json::parse(options);
        if (opts.contains("sort")) stages.push_back({{"$sort", opts.at("sort")}});
        if (opts.contains("limit")) stages.push_back({{"$limit", opts.at("limit")}});
        if (opts.contains("projection")) stages.push_back({{"$project", opts.at("projection")}});
        *pipeline = json{{"pipeline", stages}}.dump();
        return true;
    } catch (const std::exception& failure) {
        if (error) *error = failure.what();
        return false;
    }
#else
    (void)client;
    (void)db;
    (void)filter;
    (void)options;
    if (error) *error = "mongo-c-driver not linked";
    return false;
#endif
}

bool evidence_current(_mongoc_client_t* client, const std::string& db, const std::string& node,
                      const std::string& version, const std::string& content, bool* current,
                      std::string* error) {
    *current = false;
#if defined(GODBRAIN_HAVE_MONGOC)
    try {
        const Database database{client, db};
        const auto policy =
            database.find("evidence_maintenance", {{"_id", "policy"}}, {{"limit", 1}});
        if (policy.empty()) {
            *current = true;
            return true;
        }
        if (policy.front().value("version", "") != kEvidenceVersion)
            throw std::runtime_error("unsupported evidence maintenance policy");
        const auto rows = database.find(
            "evidence_checks", {{"_id", evidence_binding(node, version, content)}}, {{"limit", 1}});
        if (rows.empty()) return true;
        const auto& row = rows.front();
        const auto now = now_ms();
        const auto checked = row.value("checked_at_ms", std::int64_t{0});
        const auto expires = row.value("expires_at_ms", std::int64_t{0});
        const auto kind = row.value("profile", "");
        if (row.value("state", "") != "fresh" ||
            row.value("maintenance_version", "") != kEvidenceVersion ||
            !evidence_window(kind, checked, expires, now))
            return true;
        const auto proof = database.find("evidence_check_runs",
                                         {{"_id", row.value("last_token", "")},
                                          {"binding_id", row.at("_id")},
                                          {"outcome", "fresh"},
                                          {"observed_hash", row.at("source_hash")},
                                          {"checked_at_ms", checked},
                                          {"content_hash", keccak256_hex(content)},
                                          {"source_hash", row.at("source_hash")},
                                          {"source_run", row.at("source_run")},
                                          {"node_version", version},
                                          {"node_id", oid(node)},
                                          {"profile", kind},
                                          {"maintenance_version", kEvidenceVersion}},
                                         {{"limit", 1}});
        *current = !proof.empty() && canonical(database, row);
        return true;
    } catch (const std::exception& failure) {
        if (error) *error = failure.what();
        return false;
    }
#else
    (void)client;
    (void)db;
    (void)node;
    (void)version;
    (void)content;
    if (error) *error = "mongo-c-driver not linked";
    return false;
#endif
}
} // namespace godbrain::memory
