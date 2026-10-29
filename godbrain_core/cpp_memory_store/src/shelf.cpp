#include "godbrain/memory_store/shelf.hpp"
#include "godbrain/memory_store/json.hpp"
#include "../../cpp_kernel/json.hpp"

#include <chrono>
#include <ctime>
#include <memory>
#include <utility>

#if defined(GODBRAIN_HAVE_MONGOC)
#include <mongoc/mongoc.h>
#endif

namespace godbrain::memory {
namespace {
using J = nlohmann::json;

bool fail(std::string* error, const std::string& message) {
    if (error) *error = message;
    return false;
}

bool text_ok(const std::string& value, size_t cap, bool required) {
    if (value.size() > cap || value.find('\0') != std::string::npos ||
        (required && normalize_ws(value).empty())) return false;
    try {
        (void)J(value).dump();
        return true;
    } catch (const J::exception&) {
        return false;
    }
}

bool id_ok(const std::string& value, size_t cap, bool required) {
    if (!text_ok(value, cap, required)) return false;
    for (unsigned char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' ||
              ch == '.' || ch == ':')) return false;
    }
    return true;
}
}

bool validate_shelf_request(const ShelfRequest& r, std::string* error) {
    if (r.action != "post" && r.action != "read") return fail(error, "shelf action must be post or read");
    if (r.shelf != "discussion" && r.shelf != "research") return fail(error, "shelf must be discussion or research");
    if (r.scope != "technical" && r.scope != "personal") return fail(error, "shelf scope must be technical or personal");
    if (!id_ok(r.host_id, 80, true) || !id_ok(r.thread_id, 128, r.action == "post") ||
        !id_ok(r.exclude_thread_id, 128, false)) {
        return fail(error, "shelf host_id/thread_id is invalid");
    }
    if (r.limit < 1 || r.limit > 20 || !text_ok(r.query, 512, false)) {
        return fail(error, "shelf query or limit is invalid");
    }
    if (!r.thread_id.empty() && !r.exclude_thread_id.empty())
        return fail(error, "thread_id and exclude_thread_id cannot be combined");
    if (r.action == "read") return true;
    if (!id_ok(r.request_id, 128, true) || !text_ok(r.speaker, 128, true) ||
        !text_ok(r.title, 512, r.shelf == "research") ||
        !text_ok(r.text, 32768, true) || r.sources.size() > 16) {
        return fail(error, "shelf post requires request_id, speaker, text and a research title within limits");
    }
    for (const auto& source : r.sources) {
        if (!text_ok(source, 2048, true)) return fail(error, "shelf source reference is invalid");
    }
    return true;
}

bool parse_shelf_request(const Json& root, ShelfRequest* r, std::string* error) {
    static const char* const post_keys[] = {
        "command", "action", "shelf", "host_id", "scope", "thread_id",
        "request_id", "speaker", "title", "text", "sources", nullptr};
    static const char* const read_keys[] = {
        "command", "action", "shelf", "host_id", "scope", "thread_id",
        "query", "limit", "exclude_thread_id", nullptr};
    *r = ShelfRequest{};
    if (!json_string(root, "action", &r->action)) return fail(error, "shelf action must be a string");
    if (!json_reject_unknown_keys(root, r->action == "post" ? post_keys : read_keys, error)) return false;
    for (const auto& field : std::vector<std::pair<const char*, std::string*>>{
             {"shelf", &r->shelf}, {"host_id", &r->host_id}, {"scope", &r->scope},
             {"thread_id", &r->thread_id}, {"request_id", &r->request_id},
             {"exclude_thread_id", &r->exclude_thread_id},
             {"speaker", &r->speaker}, {"title", &r->title}, {"text", &r->text},
             {"query", &r->query}}) {
        if (json_has(root, field.first) && !json_string(root, field.first, field.second)) {
            return fail(error, std::string("shelf field must be a string: ") + field.first);
        }
    }
    if (json_has(root, "limit")) {
        double n = 0;
        if (!json_number(root, "limit", &n) || !(n >= 1 && n <= 20) ||
            n != static_cast<int>(n)) return fail(error, "shelf limit must be an integer from 1 to 20");
        r->limit = static_cast<int>(n);
    }
    if (const auto* sources = json_get(root, "sources")) {
        if (sources->kind != Json::Kind::Array) return fail(error, "shelf sources must be an array of strings");
        for (const auto& source : sources->arr) {
            if (source.kind != Json::Kind::String) return fail(error, "shelf sources must be strings");
            r->sources.push_back(source.str);
        }
    }
    return validate_shelf_request(*r, error);
}

#if defined(GODBRAIN_HAVE_MONGOC)
namespace {
using Collection = std::unique_ptr<mongoc_collection_t, decltype(&mongoc_collection_destroy)>;
using Bson = std::unique_ptr<bson_t, decltype(&bson_destroy)>;
using Cursor = std::unique_ptr<mongoc_cursor_t, decltype(&mongoc_cursor_destroy)>;

Bson bson(const J& value) {
    const std::string encoded = value.dump();
    bson_error_t error{};
    return Bson(bson_new_from_json(reinterpret_cast<const uint8_t*>(encoded.data()),
                                  static_cast<ssize_t>(encoded.size()), &error), bson_destroy);
}

J document_json(const bson_t* document) {
    size_t length = 0;
    char* encoded = bson_as_relaxed_extended_json(document, &length);
    if (!encoded) throw std::runtime_error("shelf BSON could not be decoded");
    std::unique_ptr<char, decltype(&bson_free)> owned(encoded, bson_free);
    return J::parse(encoded, encoded + length);
}

J payload(const ShelfRequest& r) {
    return J{{"shelf", r.shelf}, {"scope", r.scope}, {"host_id", r.host_id},
             {"thread_id", r.thread_id}, {"request_id", r.request_id},
             {"speaker", r.speaker}, {"title", r.title}, {"text", r.text},
             {"sources", r.sources}};
}

std::string record_id(const ShelfRequest& r) {
    return keccak256_hex(std::string("working-shelf-v1\n") + r.shelf + "\n" +
                        r.scope + "\n" + r.host_id + "\n" + r.request_id);
}

bool valid_record(const J& row, const ShelfRequest& query, std::string* error) {
    if (!row.is_object() || row.value("schema_version", "") != "working-shelf-v1" ||
        row.value("trust", "") != "untrusted" || row.value("shelf", "") != query.shelf ||
        row.value("scope", "") != query.scope || row.value("host_id", "") != query.host_id) {
        return fail(error, "shelf record has invalid identity or trust metadata");
    }
    ShelfRequest r;
    r.action = "post";
    r.shelf = row.at("shelf").get<std::string>();
    r.scope = row.at("scope").get<std::string>();
    r.host_id = row.at("host_id").get<std::string>();
    r.thread_id = row.at("thread_id").get<std::string>();
    r.request_id = row.at("request_id").get<std::string>();
    r.speaker = row.at("speaker").get<std::string>();
    r.title = row.at("title").get<std::string>();
    r.text = row.at("text").get<std::string>();
    r.sources = row.at("sources").get<std::vector<std::string>>();
    if (!validate_shelf_request(r, error) ||
        row.at("_id") != record_id(r) ||
        row.at("payload_hash") != keccak256_hex(payload(r).dump()) ||
        row.at("source_hash") != keccak256_hex(r.text) ||
        !row.at("created_at").is_string() || !row.at("saved_ms").is_number_integer()) {
        return fail(error, "shelf record failed content/provenance validation");
    }
    return true;
}

bool find_id(mongoc_collection_t* collection, const std::string& id,
             J* row, std::string* error) {
    auto filter = bson(J{{"_id", id}});
    auto options = bson(J{{"limit", 1}, {"maxTimeMS", 2000}});
    if (!filter || !options) return fail(error, "shelf lookup encoding failed");
    Cursor cursor(mongoc_collection_find_with_opts(collection, filter.get(), options.get(), nullptr),
                  mongoc_cursor_destroy);
    const bson_t* document = nullptr;
    *row = J();
    if (mongoc_cursor_next(cursor.get(), &document)) *row = document_json(document);
    bson_error_t issue{};
    if (mongoc_cursor_error(cursor.get(), &issue)) return fail(error, std::string("shelf lookup: ") + issue.message);
    return true;
}

bool ensure_search_index(mongoc_collection_t* collection, std::string* error) {
    auto keys = bson(J{{"scope", 1}, {"host_id", 1}, {"title", "text"}, {"text", "text"}});
    auto opts = bson(J{{"name", "working_shelf_search_v1"}, {"default_language", "none"}});
    if (!keys || !opts) return fail(error, "shelf index encoding failed");
    mongoc_index_model_t* models[] = {mongoc_index_model_new(keys.get(), opts.get())};
    bson_error_t issue{};
    const bool ok = mongoc_collection_create_indexes_with_opts(collection, models, 1, nullptr, nullptr, &issue);
    mongoc_index_model_destroy(models[0]);
    return ok || fail(error, std::string("shelf index: ") + issue.message);
}
}
#endif

bool shelf_command(_mongoc_client_t* client, const std::string& db_name,
                   const ShelfRequest& r, std::string* output, std::string* error) {
    if (!validate_shelf_request(r, error)) return false;
#if !defined(GODBRAIN_HAVE_MONGOC)
    (void)client;
    (void)db_name;
    (void)output;
    return fail(error, "mongo-c-driver not linked");
#else
    try {
        const char* name = r.shelf == "discussion" ? "discussion_messages" : "research_notes";
        Collection collection(mongoc_client_get_collection(client, db_name.c_str(), name),
                              mongoc_collection_destroy);
        std::unique_ptr<mongoc_read_prefs_t, decltype(&mongoc_read_prefs_destroy)> primary(
            mongoc_read_prefs_new(MONGOC_READ_PRIMARY), mongoc_read_prefs_destroy);
        mongoc_collection_set_read_prefs(collection.get(), primary.get());
        if (r.action == "post") {
            const J body = payload(r);
            const std::string hash = keccak256_hex(body.dump());
            const std::string id = record_id(r);
            J existing;
            if (!find_id(collection.get(), id, &existing, error)) return false;
            const bool existed = !existing.is_null();
            bool idempotent = existed;
            if (!existed) {
                if (!ensure_search_index(collection.get(), error)) return false;
                J row = body;
                const auto now = std::chrono::system_clock::now();
                const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
                const std::time_t seconds = std::chrono::system_clock::to_time_t(now);
                std::tm utc{};
#if defined(_WIN32)
                gmtime_s(&utc, &seconds);
#else
                gmtime_r(&seconds, &utc);
#endif
                char stamp[32]{};
                std::strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &utc);
                row["_id"] = id;
                row["schema_version"] = "working-shelf-v1";
                row["trust"] = "untrusted";
                row["source_hash"] = keccak256_hex(r.text);
                row["payload_hash"] = hash;
                row["created_at"] = stamp;
                row["saved_ms"] = ms;
                auto document = bson(row);
                if (!document) return fail(error, "shelf record encoding failed");
                std::unique_ptr<mongoc_write_concern_t, decltype(&mongoc_write_concern_destroy)> concern(
                    mongoc_write_concern_new(), mongoc_write_concern_destroy);
                mongoc_write_concern_set_w(concern.get(), 1);
                mongoc_write_concern_set_journal(concern.get(), true);
                mongoc_collection_set_write_concern(collection.get(), concern.get());
                bson_error_t issue{};
                if (!mongoc_collection_insert_one(collection.get(), document.get(), nullptr, nullptr, &issue)) {
                    if (issue.code != 11000) return fail(error, std::string("shelf insert: ") + issue.message);
                    idempotent = true;
                }
                if (!find_id(collection.get(), id, &existing, error)) return false;
            }
            if (existing.is_null()) return fail(error, "shelf insert was not confirmed by a primary read");
            if (!valid_record(existing, r, error)) return false;
            if (existing.at("payload_hash") != hash) return fail(error, "shelf request_id was reused with different content");
            *output = J{{"status", "stored"}, {"schema_version", "working-shelf-v1"},
                        {"shelf", r.shelf}, {"trust", "untrusted"}, {"promoted", false},
                        {"idempotent", idempotent}, {"record", existing}}.dump() + "\n";
            return true;
        }
        std::unique_ptr<mongoc_database_t, decltype(&mongoc_database_destroy)> db(
            mongoc_client_get_database(client, db_name.c_str()), mongoc_database_destroy);
        bson_error_t issue{};
        const bool present = mongoc_database_has_collection(db.get(), name, &issue);
        if (!present && issue.code) return fail(error, std::string("shelf collection read: ") + issue.message);
        std::string search_terms = r.query;
        for (char& ch : search_terms)
            if (ch == '-' || ch == '"' || ch == '\\') ch = ' ';
        search_terms = normalize_ws(search_terms);
        if (!r.query.empty() && search_terms.empty())
            return fail(error, "shelf query has no literal search terms");
        J rows = J::array();
        bool more = false;
        if (present) {
            J filter{{"scope", r.scope}, {"host_id", r.host_id}};
            if (!r.thread_id.empty()) filter["thread_id"] = r.thread_id;
            if (!r.exclude_thread_id.empty()) {
                if (!r.thread_id.empty()) return fail(error, "thread_id and exclude_thread_id cannot be combined");
                filter["thread_id"] = J{{"$ne", r.exclude_thread_id}};
            }
            if (!search_terms.empty()) filter["$text"] = J{{"$search", search_terms}};
            auto where = bson(filter);
            auto opts = bson(J{{"limit", r.limit + 1}, {"maxTimeMS", 2000}});
            if (!where || !opts) return fail(error, "shelf query encoding failed");
            bson_t sort;
            bson_append_document_begin(opts.get(), "sort", -1, &sort);
            if (!r.query.empty()) {
                bson_t score;
                bson_append_document_begin(&sort, "score", -1, &score);
                BSON_APPEND_UTF8(&score, "$meta", "textScore");
                bson_append_document_end(&sort, &score);
            }
            BSON_APPEND_INT32(&sort, "saved_ms", -1);
            BSON_APPEND_INT32(&sort, "_id", -1);
            bson_append_document_end(opts.get(), &sort);
            Cursor cursor(mongoc_collection_find_with_opts(collection.get(), where.get(), opts.get(), nullptr),
                          mongoc_cursor_destroy);
            const bson_t* document = nullptr;
            while (mongoc_cursor_next(cursor.get(), &document)) {
                if (rows.size() == static_cast<size_t>(r.limit)) { more = true; break; }
                J row = document_json(document);
                if (!valid_record(row, r, error)) return false;
                rows.push_back(std::move(row));
            }
            if (mongoc_cursor_error(cursor.get(), &issue)) return fail(error, std::string("shelf query: ") + issue.message);
        }
        *output = J{{"status", "ok"}, {"schema_version", "working-shelf-v1"},
                    {"shelf", r.shelf}, {"trust", "untrusted"}, {"promoted", false},
                    {"search", r.query.empty() ? "recent" : "lexical"}, {"more", more},
                    {"records", rows}, {"count", rows.size()}}.dump() + "\n";
        return true;
    } catch (const J::exception& issue) {
        return fail(error, std::string("invalid shelf JSON/record: ") + issue.what());
    }
#endif
}
}
