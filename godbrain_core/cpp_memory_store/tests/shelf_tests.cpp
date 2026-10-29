#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/store.hpp"
#include "../../cpp_kernel/json.hpp"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

#if defined(GODBRAIN_HAVE_MONGOC)
#include <mongoc/mongoc.h>
#endif

using J = nlohmann::json;
using namespace godbrain::memory;

namespace {
void check(bool pass, const char* label) {
    if (!pass) throw std::runtime_error(label);
}

void protocol_tests() {
    const J post{{"command", "shelf"}, {"action", "post"}, {"shelf", "research"},
                 {"host_id", "fixture-host"}, {"thread_id", "speaker"},
                 {"request_id", "fixture-post"}, {"title", "Provisional speaker notes"},
                 {"text", "Unverified observation, not a repair instruction."}};
    Route route;
    std::string error;
    check(classify_and_parse(post.dump(), &route, &error) &&
          route.kind == CommandKind::Shelf, "strict shelf post");
    for (const char* field : {"trust", "status", "command_type", "$where", "collection", "created_at"}) {
        J bad = post;
        bad[field] = "verified";
        check(!classify_and_parse(bad.dump(), &route, &error), "caller authority/unknown fields rejected");
    }
    for (const char* field : {"text", "scope", "speaker", "thread_id", "host_id", "sources"}) {
        J bad = post;
        bad[field] = 123;
        check(!classify_and_parse(bad.dump(), &route, &error), "wrong post field type rejected");
    }
    for (const char* shelf : {"verified", "rag_documents", "personal", "$cmd"}) {
        J bad = post;
        bad["shelf"] = shelf;
        check(!classify_and_parse(bad.dump(), &route, &error), "only working shelf names allowed");
    }
    J bad = post;
    bad["text"] = std::string(32769, 'x');
    check(!classify_and_parse(bad.dump(), &route, &error), "oversized text rejected");
    bad["text"] = std::string("before\0after", 12);
    check(!classify_and_parse(bad.dump(), &route, &error), "interior NUL rejected");
    bad["text"] = " \n\t";
    check(!classify_and_parse(bad.dump(), &route, &error), "empty text rejected");
    bad = post;
    bad["title"] = "";
    check(!classify_and_parse(bad.dump(), &route, &error), "research requires a title");
    bad["shelf"] = "discussion";
    check(classify_and_parse(bad.dump(), &route, &error), "discussion does not require curation");
    check(!classify_and_parse(post.dump() + " {}", &route, &error), "one JSON document only");
    J read{{"command", "shelf"}, {"action", "read"}, {"shelf", "research"},
           {"host_id", "fixture-host"}, {"query", "speaker"}};
    check(classify_and_parse(read.dump(), &route, &error), "bounded shelf read");
    for (double n : {-1.0, 0.0, 1.5, 21.0, 1e100}) {
        read["limit"] = n;
        check(!classify_and_parse(read.dump(), &route, &error), "invalid read limit rejected");
    }
    read["limit"] = 20;
    read["text"] = "not a read field";
    check(!classify_and_parse(read.dump(), &route, &error), "read cannot carry a post");
}

#if defined(GODBRAIN_HAVE_MONGOC)
void mongo_tests(const char* uri) {
#if defined(_WIN32)
    check(_putenv_s("MONGODB_URI", uri) == 0 &&
          _putenv_s("MONGODB_DB_NAME", "godbrain_cpp_store_test") == 0, "test environment");
#else
    check(setenv("MONGODB_URI", uri, 1) == 0 &&
          setenv("MONGODB_DB_NAME", "godbrain_cpp_store_test", 1) == 0, "test environment");
#endif
    std::string error;
    StoreHandle* store = store_open(&error);
    check(store != nullptr, "open isolated test database");
    const std::string host = "shelf-fixture-" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());
    mongoc_client_t* client = mongoc_client_new(uri);
    check(client != nullptr, "test cleanup client");
    const auto count = [&](const char* name) {
        auto* collection = mongoc_client_get_collection(client, "godbrain_cpp_store_test", name);
        bson_t filter = BSON_INITIALIZER;
        bson_error_t issue{};
        const auto n = mongoc_collection_count_documents(collection, &filter, nullptr, nullptr, nullptr, &issue);
        bson_destroy(&filter);
        mongoc_collection_destroy(collection);
        check(n >= 0, "count canonical collections");
        return n;
    };
    const char* canonical[] = {"sources", "knowledge_nodes", "ingestion_runs", "rag_documents", "rag_provenance"};
    std::vector<int64_t> before;
    for (const char* name : canonical) before.push_back(count(name));
    const auto run = [&](const ShelfRequest& request) {
        std::string output;
        if (!store_shelf(store, request, &output, &error)) throw std::runtime_error(error);
        return J::parse(output);
    };
    const auto cleanup = [&] {
        for (const char* name : {"discussion_messages", "research_notes"}) {
            auto* collection = mongoc_client_get_collection(client, "godbrain_cpp_store_test", name);
            bson_t filter = BSON_INITIALIZER;
            BSON_APPEND_UTF8(&filter, "host_id", host.c_str());
            bson_error_t issue{};
            const bool ok = mongoc_collection_delete_many(collection, &filter, nullptr, nullptr, &issue);
            bson_destroy(&filter);
            mongoc_collection_destroy(collection);
            check(ok, "remove only this run's fixture records");
        }
    };
    try {
        ShelfRequest post;
        post.action = "post";
        post.shelf = "research";
        post.host_id = host;
        post.thread_id = "speaker";
        post.request_id = "first";
        post.title = "Provisional speaker investigation";
        post.text = "shelfneedlexyz -NoProfile Bluetooth pairing hypothesis, not verified.";
        const J stored = run(post);
        check(stored.at("trust") == "untrusted" && stored.at("promoted") == false &&
              stored.at("record").at("source_hash") == keccak256_hex(post.text), "working receipt and exact source hash");
        check(run(post).at("idempotent") == true, "idempotent retry");
        post.text += " Changed.";
        std::string output;
        check(!store_shelf(store, post, &output, &error), "conflicting retry rejected");
        ShelfRequest read;
        read.action = "read";
        read.shelf = "research";
        read.host_id = host;
        read.query = "shelfneedlexyz";
        check(run(read).at("count") == 1, "full collection indexed research retrieval");
        for (const char* query : {"-NoProfile", "Explain -NoProfile", "\"-NoProfile\"", "\\-NoProfile"}) {
            read.query = query;
            check(run(read).at("count") == 1, "command flags are positive literal shelf search terms");
        }
        read.query = "--- \"\\";
        check(!store_shelf(store, read, &output, &error), "operator-only query must not become an unfiltered read");
        read.query = "shelfneedlexyz";
        read.scope = "personal";
        check(run(read).at("count") == 0, "personal boundary");
        read.scope = "technical";
        read.host_id = host + "-other";
        check(run(read).at("count") == 0, "target host boundary");
        read.host_id = host;
        read.shelf = "discussion";
        check(run(read).at("count") == 0, "shelf boundary");
        post.shelf = "discussion";
        post.request_id = "discussion";
        post.title.clear();
        run(post);
        check(run(read).at("count") == 1, "discussion can persist without judgment");
        read.shelf = "research";
        read.exclude_thread_id = "speaker";
        check(run(read).at("count") == 0, "index thread can be excluded explicitly");
        for (size_t i = 0; i < before.size(); ++i) {
            check(before[i] == count(canonical[i]), "working posts cannot enter the canonical RAG collections");
        }
        cleanup();
    } catch (...) {
        cleanup();
        store_close(store);
        mongoc_client_destroy(client);
        throw;
    }
    store_close(store);
    mongoc_client_destroy(client);
}
#endif
}

int main() {
    try {
        protocol_tests();
#if defined(GODBRAIN_HAVE_MONGOC)
        const char* configured_uri = std::getenv("MONGODB_TEST_URI");
        const std::string uri = configured_uri ? configured_uri : "";
        if (!uri.empty()) mongo_tests(uri.c_str());
        else std::cout << "Mongo shelf integration not run: MONGODB_TEST_URI is unset.\n";
#endif
        std::cout << "PASS working shelf tests\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL working shelves: " << error.what() << '\n';
        return 1;
    }
}
