#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/snapshot.hpp"

int main() {
    const int protocol = godbrain::memory::run_self_test();
    const int snapshot = godbrain::memory::run_snapshot_self_test();
    return (protocol == 0 && snapshot == 0) ? 0 : 1;
}
