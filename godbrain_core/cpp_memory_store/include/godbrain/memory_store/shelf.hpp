#pragma once

#include "godbrain/memory_store/protocol.hpp"

struct _mongoc_client_t;

namespace godbrain::memory {
bool shelf_command(_mongoc_client_t* client, const std::string& db_name,
                   const ShelfRequest& request, std::string* output,
                   std::string* error);
}
