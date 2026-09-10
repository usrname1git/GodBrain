#pragma once

#include "godbrain/memory_store/embedding.hpp"
#include "http_loopback.hpp"
#include "projector.hpp"

#include <mongoc/mongoc.h>

#include <string>

namespace godbrain::memory {

struct RagEngine {
    mongoc_client_t* client = nullptr;
    std::string db_name;
    EmbeddingRuntime runtime;
    std::string preferred_schema;
};

HttpResponse rag_handle_request(RagEngine* engine, const HttpRequest& req);

}  // namespace godbrain::memory
