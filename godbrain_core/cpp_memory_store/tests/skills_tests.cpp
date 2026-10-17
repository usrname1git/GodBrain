#include "godbrain/memory_store/json.hpp"
#include "godbrain/memory_store/store.hpp"
#include "rag_engine.hpp"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>

using namespace godbrain::memory;

static void check(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

static std::string text(const Json& object, const char* key) {
    std::string value;
    check(json_string(object, key, &value), std::string("missing fixture field: ") + key);
    return value;
}

static void insert(mongoc_database_t* db, const char* collection, const bson_t* doc) {
    auto* c = mongoc_database_get_collection(db, collection);
    bson_error_t error{};
    const bool ok = mongoc_collection_insert_one(c, doc, nullptr, nullptr, &error);
    mongoc_collection_destroy(c);
    check(ok, std::string("fixture insert: ") + error.message);
}

static void clear(mongoc_database_t* db) {
    bson_error_t error{};
    check(mongoc_database_drop(db, &error), std::string("fixture clear: ") + error.message);
}

static void seed(mongoc_database_t* db, const std::string& mutation,
                 const std::string& name = "display-rollback", int64_t created = 1) {
    bson_oid_t oid;
    bson_oid_init(&oid, nullptr);
    char id[25];
    bson_oid_to_string(&oid, id);
    std::string content = "Steps to rollback the display safely.";
    if (mutation == "pin-expired") content += "\nos_pin=fixture/123.450\n";
    if (mutation == "pin-current") content += "\nos_pin=fixture/123.45\n";
    const std::string profile = mutation.find("broad-") == 0 ? "galaxy-html-v1" :
        mutation == "apply-only" ? "local-edit-apply-v1" :
        mutation == "unknown-profile" ? "unknown" : "desk-v1";
    bson_t node = BSON_INITIALIZER;
    BSON_APPEND_OID(&node, "_id", &oid);
    BSON_APPEND_UTF8(&node, "status", mutation == "stale-origin" ? "stale" :
        mutation == "candidate-origin" ? "candidate" : "verified");
    BSON_APPEND_UTF8(&node, "sector", mutation == "personal-origin" ? "personal" :
        mutation.find("pin-") == 0 ? "windows-sre" : "test");
    BSON_APPEND_UTF8(&node, "version", "v1");
    BSON_APPEND_UTF8(&node, "content", content.c_str());
    if (mutation != "missing-origin") insert(db, "knowledge_nodes", &node);
    bson_destroy(&node);
    bson_t link = BSON_INITIALIZER;
    BSON_APPEND_OID(&link, "node_id", &oid);
    BSON_APPEND_UTF8(&link, "run_id", id);
    if (mutation != "missing-link") insert(db, "run_node_links", &link);
    bson_destroy(&link);
    bson_t run = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&run, "run_id", id);
    BSON_APPEND_UTF8(&run, "status", mutation == "uncommitted" ? "staging" : "committed");
    insert(db, "ingestion_runs", &run);
    bson_destroy(&run);
    bson_t skill = BSON_INITIALIZER;
    BSON_APPEND_UTF8(&skill, "name", name.c_str());
    BSON_APPEND_UTF8(&skill, "origin_node_id", id);
    BSON_APPEND_UTF8(&skill, "origin_version", mutation == "version-mismatch" ? "v2" : "v1");
    const std::string hash = mutation == "hash-mismatch" ? std::string(64, '0') : keccak256_hex(content);
    BSON_APPEND_UTF8(&skill, "origin_hash", hash.c_str());
    BSON_APPEND_UTF8(&skill, "content", mutation == "rewritten-content" ? "Unrelated rewrite." : content.c_str());
    BSON_APPEND_UTF8(&skill, "verification_profile", profile.c_str());
    BSON_APPEND_UTF8(&skill, "verification_run_id", mutation == "missing-promotion-evidence" ? "" : "run-a");
    BSON_APPEND_DATE_TIME(&skill, "created_at", created);
    insert(db, "skills", &skill);
    bson_destroy(&skill);
    const auto evidence = [&](const char* fixture, const char* result, int64_t at, const std::string& p) {
        bson_t verification = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&verification, "run_id", at == 1 ? "run-a" : at == 2 ? "run-b" : "run-c");
        BSON_APPEND_UTF8(&verification, "origin_node_id", id);
        BSON_APPEND_UTF8(&verification, "skill_name", name.c_str());
        BSON_APPEND_UTF8(&verification, "fixture_id", fixture);
        BSON_APPEND_UTF8(&verification, "verification_profile", p.c_str());
        BSON_APPEND_UTF8(&verification, "result", result);
        BSON_APPEND_DATE_TIME(&verification, "created_at", at);
        insert(db, "skill_verification_runs", &verification);
        bson_destroy(&verification);
    };
    if (mutation != "missing-run") evidence("a", "passed", 1, profile);
    if (mutation == "later-fail" || mutation == "later-pass") evidence("a", "failed", 2, profile);
    if (mutation == "later-pass") evidence("a", "passed", 3, profile);
    if (mutation == "broad-two") evidence("b", "passed", 2, profile);
    if (mutation == "broad-stale-fixture") {
        evidence("b", "failed", 2, profile);
        evidence("a", "passed", 3, profile);
    }
    if (mutation == "profile-mismatch") {
        evidence("a", "passed", 2, "galaxy-html-v1");
        evidence("b", "passed", 3, "galaxy-html-v1");
    }
}

int main() {
    const char* uri = std::getenv("MONGODB_TEST_URI");
    if (!uri || !*uri) return 77;
    const std::string test_uri(uri);
    mongoc_init();
    auto* client = mongoc_client_new(uri);
    if (!client) return 1;
    bson_oid_t oid;
    bson_oid_init(&oid, nullptr);
    char suffix[25];
    bson_oid_to_string(&oid, suffix);
    const std::string db_name = std::string("godbrain_cpp_skill_test_") + suffix;
    auto* db = mongoc_client_get_database(client, db_name.c_str());
    int result = 0;
    try {
        std::ifstream input(GODBRAIN_SKILL_FIXTURE);
        check(static_cast<bool>(input), "skill fixture missing");
        std::ostringstream bytes;
        bytes << input.rdbuf();
        Json fixture;
        std::string error;
        check(parse_json(bytes.str(), &fixture, &error), error);
        check(skill_query_terms("one two three four five six seven eight nine ten").size() == 8,
              "query term bound");
        for (const auto& test : fixture.obj.at("ranking").arr) {
            double expected = 0;
            check(json_number(test, "score", &expected), "missing score");
            check(skill_relevance(text(test, "query"), text(test, "name"), text(test, "content")) == expected,
                  "ranking parity: " + text(test, "name"));
        }
        QuerySkillsRequest request;
        request.command = kQuerySkillsCommand;
        request.query = "rollback display";
        request.limit = 25;
        for (const auto& test : fixture.obj.at("eligibility").arr) {
            clear(db);
            const std::string mutation = text(test, "mutation");
            seed(db, mutation);
            QuerySkillsReceiptOut receipt;
            bool expected = false;
            check(json_bool(test, "eligible", &expected), "missing expected eligibility");
            check(store_query_skills(client, db_name, request, &receipt, &error), error);
            check(receipt.skills.size() == (expected ? 1u : 0u), "eligibility parity: " + mutation);
        }
        clear(db);
        seed(db, "fresh", "display-rollback", 1);
        seed(db, "fresh", "display-guide", 2);
        request.limit = 1;
        QuerySkillsReceiptOut receipt;
        check(store_query_skills(client, db_name, request, &receipt, &error), error);
        check(receipt.skills.size() == 1 && receipt.skills[0].name == "display-rollback", "relevance lost to recency");
        request.query = ".*";
        check(store_query_skills(client, db_name, request, &receipt, &error), error);
        check(receipt.skills.empty(), "regex query was not literal");
        RagRebuildReport projection;
        check(rebuild_rag_projection(client, db_name, &projection, &error), error);
        RagEngine engine;
        engine.client = client;
        engine.db_name = db_name;
        HttpRequest lookup;
        lookup.method = "POST";
        lookup.path = "/v1/skills";
        lookup.content_type = "application/json";
        lookup.body = "{\"query\":\"rollback display\",\"limit\":1}";
        const auto response = rag_handle_request(&engine, lookup);
        check(response.status == 200, "canonical skill HTTP query failed: " + response.body);
        Json body;
        check(parse_json(response.body, &body, &error), error);
        double count = 0;
        check(json_number(body, "count", &count) && count == 1 &&
              body.obj.at("skills").arr.size() == 1, "canonical skill HTTP count");
        const auto& hit = body.obj.at("skills").arr.front();
        bool untrusted = false;
        check(text(hit, "name") == "display-rollback" && json_bool(hit, "untrusted", &untrusted) && untrusted &&
              text(hit, "verification_profile") == "desk-v1", "canonical skill HTTP reference contract");
        HttpRequest invalid;
        invalid.method = "POST";
        invalid.path = "/v1/skills";
        invalid.content_type = "application/json";
        invalid.body = "{\"query\":\"display\",\"limit\":1.5}";
        check(rag_handle_request(&engine, invalid).status == 400, "fractional skill limit accepted");
        clear(db);
        seed(db, "pin-expired", "display-expired");
        seed(db, "pin-current", "display-current");
        for (int i = 0; i < 500; ++i) {
            bson_t node = BSON_INITIALIZER;
            bson_oid_t id;
            bson_oid_init(&id, nullptr);
            BSON_APPEND_OID(&node, "_id", &id);
            BSON_APPEND_UTF8(&node, "status", i == 0 ? "stale" : "verified");
            BSON_APPEND_UTF8(&node, "sector", "windows-sre");
            BSON_APPEND_UTF8(&node, "content", "Host fixture\nos_pin=fixture/old\n");
            insert(db, "knowledge_nodes", &node);
            bson_destroy(&node);
        }
        request.query = "rollback display";
        request.limit = 25;
        check(store_query_skills(client, db_name, request, &receipt, &error), error);
        check(receipt.skills.size() == 2, "pin fixtures were not initially eligible");
        check(rebuild_rag_projection(client, db_name, &projection, &error), error);
#ifdef _WIN32
        check(_putenv_s("MONGODB_URI", test_uri.c_str()) == 0 &&
              _putenv_s("MONGODB_DB_NAME", db_name.c_str()) == 0, "test store environment");
#else
        check(setenv("MONGODB_URI", test_uri.c_str(), 1) == 0 &&
              setenv("MONGODB_DB_NAME", db_name.c_str(), 1) == 0, "test store environment");
#endif
        std::unique_ptr<StoreHandle, decltype(&store_close)> store(store_open(&error), store_close);
        check(store != nullptr, error);
        StalePinsRequest sweep;
        sweep.command = kStalePinsCommand;
        sweep.sector = "windows-sre";
        sweep.pin = "fixture/123.45";
        sweep.reasoning = "live fixture pin no longer matches";
        StalePinsReceiptOut swept;
        check(store_stale_pins(store.get(), sweep, &swept, &error), error);
        check(swept.stale == 501, "pin sweep stopped before the complete 501-card mismatch set");
        check(store_query_skills(client, db_name, request, &receipt, &error), error);
        check(receipt.skills.size() == 1 && receipt.skills[0].name == "display-current",
              "out-of-scope origin remained eligible or current origin was withdrawn");
        auto* documents = mongoc_database_get_collection(db, "rag_documents");
        bson_t stale_filter = BSON_INITIALIZER;
        BSON_APPEND_UTF8(&stale_filter, "status", "stale");
        bson_error_t count_error{};
        const auto projected_stale = mongoc_collection_count_documents(
            documents, &stale_filter, nullptr, nullptr, nullptr, &count_error);
        bson_destroy(&stale_filter);
        mongoc_collection_destroy(documents);
        check(projected_stale == 1, "pin invalidation did not synchronize its committed projection");
        check(store_stale_pins(store.get(), sweep, &swept, &error), error);
        check(swept.stale == 501, "pin sweep retry lost already-stale projection repair candidates");
        clear(db);
        std::cout << "PASS skill lookup and pin freshness: parity, current joins, complete sweep and withdrawal\n";
    } catch (const std::exception& error) {
        std::cerr << "FAIL skill lookup: " << error.what() << "\n";
        result = 1;
        bson_error_t cleanup{};
        if (!mongoc_database_drop(db, &cleanup)) std::cerr << "FAIL fixture cleanup: " << cleanup.message << "\n";
    }
    mongoc_database_destroy(db);
    mongoc_client_destroy(client);
    mongoc_cleanup();
    return result;
}
