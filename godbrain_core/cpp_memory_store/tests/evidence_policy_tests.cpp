#include "godbrain/memory_store/evidence.hpp"
#include <iostream>
#include <stdexcept>

using namespace godbrain::memory;

static void require(bool ok, const char* why) {
    if (!ok) throw std::runtime_error(why);
}

int main() {
    try {
        const std::int64_t checked = 1000000;
        require(evidence_window("host", checked, checked + kHostTtlMs, checked),
                "host initial window");
        require(evidence_window("host", checked, checked + kHostTtlMs, checked + kHostTtlMs - 1),
                "host last valid millisecond");
        require(!evidence_window("host", checked, checked + kHostTtlMs, checked + kHostTtlMs),
                "host expiry boundary");
        require(!evidence_window("host", checked, checked + kDocumentTtlMs, checked),
                "host cannot borrow documentation lifetime");
        require(!evidence_window("document", checked, checked + kDocumentTtlMs, checked - 1),
                "future proof was accepted");
        require(!evidence_window("unknown", checked, checked + kDocumentTtlMs, checked),
                "unknown checker was accepted");
        require(!evidence_window("host", INT64_MAX - 1, INT64_MAX, INT64_MAX), "clock overflow");
        require(evidence_backoff(1) == 60000 && evidence_backoff(5) == 960000 &&
                    evidence_backoff(6) == kDocumentTtlMs && evidence_backoff(99) == kDocumentTtlMs,
                "bounded recovery backoff");
        const std::string valid = "{\"command\":\"evidence\",\"action\":\"next\"}";
        Route route;
        std::string error;
        require(classify_and_parse(valid, &route, &error) && route.kind == CommandKind::Evidence,
                "evidence next protocol");
        for (const auto& invalid :
             {"{\"command\":\"evidence\",\"action\":\"next\",\"id\":null}",
              "{\"command\":\"evidence\",\"action\":\"next\",\"outcome\":\"fresh\"}",
              "{\"command\":\"evidence\",\"action\":\"next\",\"ttl\":999999}",
              "{\"command\":\"evidence\",\"action\":\"next\"} {}"}) {
            require(!classify_and_parse(invalid, &route, &error), "strict evidence schema");
        }
        std::cout << "evidence policy: fake clock, expiry, backoff and strict framing passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
