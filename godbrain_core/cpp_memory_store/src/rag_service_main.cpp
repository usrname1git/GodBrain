#include "godbrain/memory_store/embedding.hpp"
#include "http_loopback.hpp"
#include "projector.hpp"
#include "rag_engine.hpp"

#include <mongoc/mongoc.h>

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace {
std::atomic<bool> g_stop{false};

#if defined(_WIN32)
BOOL WINAPI console_ctrl(DWORD) {
    g_stop.store(true);
    return TRUE;
}
#endif

int parse_port(const char* value, std::string* err) {
    if (value == nullptr || value[0] == '\0') return 8084;
    char* end = nullptr;
    long p = std::strtol(value, &end, 10);
    if (end == value || (end != nullptr && *end != '\0') || p < 1 || p > 65535) {
        if (err) *err = "GODBRAIN_RAG_PORT must be an integer from 1 through 65535";
        return 0;
    }
    return static_cast<int>(p);
}
}  // namespace

int main() {
    std::string err;
    int port = parse_port(std::getenv("GODBRAIN_RAG_PORT"), &err);
    if (port <= 0) {
        std::cerr << "RAG service stopped: " << err << "\n";
        return 1;
    }
    const char* uri = std::getenv("MONGODB_URI");
    if (uri == nullptr || uri[0] == '\0') uri = "mongodb://127.0.0.1:27017";
    const char* dbn = std::getenv("MONGODB_DB_NAME");
    if (dbn == nullptr || dbn[0] == '\0') dbn = "godbrain";

    mongoc_init();
    bson_error_t error{};
    mongoc_uri_t* parsed = mongoc_uri_new_with_error(uri, &error);
    if (parsed == nullptr) {
        std::cerr << "RAG service stopped: failed to connect to MongoDB\n";
        return 1;
    }
    mongoc_client_t* client = mongoc_client_new_from_uri(parsed);
    mongoc_uri_destroy(parsed);
    if (client == nullptr) {
        std::cerr << "RAG service stopped: failed to connect to MongoDB\n";
        return 1;
    }
    mongoc_client_set_appname(client, "godbrain-cpp-rag-service");
    bson_t ping = BSON_INITIALIZER;
    BSON_APPEND_INT32(&ping, "ping", 1);
    bson_t reply = BSON_INITIALIZER;
    if (!mongoc_client_command_simple(client, "admin", &ping, nullptr, &reply, &error)) {
        bson_destroy(&ping);
        bson_destroy(&reply);
        mongoc_client_destroy(client);
        std::cerr << "RAG service stopped: failed to ping MongoDB\n";
        return 1;
    }
    bson_destroy(&ping);
    bson_destroy(&reply);

    godbrain::memory::EmbeddingRuntime runtime;
    if (!godbrain::memory::embedding_runtime_from_env(&runtime, &err)) {
        mongoc_client_destroy(client);
        std::cerr << "RAG service stopped: invalid embedding configuration: " << err << "\n";
        return 1;
    }
    if (!godbrain::memory::ensure_rag_indexes(client, dbn, &err)) {
        mongoc_client_destroy(client);
        std::cerr << "RAG service stopped: failed to ensure RAG indexes: " << err << "\n";
        return 1;
    }

    godbrain::memory::RagEngine engine;
    engine.client = client;
    engine.db_name = dbn;
    engine.runtime = runtime;
    const char* pref = std::getenv("GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION");
    if (pref != nullptr) engine.preferred_schema = pref;

#if defined(_WIN32)
    SetConsoleCtrlHandler(console_ctrl, TRUE);
#endif
    std::cerr << "RAG service listening on 127.0.0.1:" << port << "\n";
    auto handler = [&](const godbrain::memory::HttpRequest& req) {
        return godbrain::memory::rag_handle_request(&engine, req);
    };
    int rc = godbrain::memory::http_serve_loopback(static_cast<uint16_t>(port), handler, &g_stop);
    mongoc_client_destroy(client);
    return rc;
}
