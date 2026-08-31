#include <iostream>
#include <string>

#include "unused49.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    const std::string essay =
        "To perform the Jarvis work on this desk, the missing component "
        "is the observe-conclude loop.\n\nThe hardware (GPU), the engine "
        "(mouth), the knowledge base (rag/Golden Records";
    const std::string hit = essay + "<unused49><unused49><unused49>";
    const std::string kept = unused49::strip_tail(hit);
    if (!expect(unused49::contains(hit), "tags detected") ||
        !expect(!unused49::is_junk(hit), "essay plus tags is not junk") ||
        !expect(unused49::keep_prefix(hit), "keep the prefix") ||
        !expect(kept.find("observe-conclude") != std::string::npos,
                "prefix keeps conclude") ||
        !expect(kept.find("unused49") == std::string::npos,
                "prefix has no token") ||
        !expect(kept.find("Golden Records") != std::string::npos,
                "prefix keeps last words")) {
        return 1;
    }

    const std::string only = "<unused49><unused49>";
    if (!expect(unused49::is_junk(only), "tags only are junk") ||
        !expect(unused49::strip_tail(only).empty(), "tags only strip empty")) {
        return 1;
    }

    if (!expect(!unused49::contains("2+2 is 4."), "clean text") ||
        !expect(!unused49::is_junk("2+2 is 4."), "clean is not junk")) {
        return 1;
    }

    std::cout << "unused49_test ok" << std::endl;
    return 0;
}
