#include "godbrain/memory_store/store.hpp"

#include <iostream>
#include <string>

int main() {
    if (!godbrain::memory::store_available()) {
        std::cerr << "RAG rebuild failed: mongo-c-driver not linked\n";
        return 1;
    }
    std::string err;
    godbrain::memory::StoreHandle* store = godbrain::memory::store_open(&err);
    if (store == nullptr) {
        std::cerr << "RAG rebuild failed: " << err << "\n";
        return 1;
    }
    std::string json;
    const bool ok = godbrain::memory::store_rebuild(store, &json, &err);
    godbrain::memory::store_close(store);
    if (!ok) {
        std::cerr << "RAG rebuild failed: " << err << "\n";
        return 1;
    }
    std::cout << json;
    return 0;
}
