#include <iostream>

#include "thinking_cmd.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    if (!expect(parse_thinking_command("enable_thinking: false") == 0,
                "spaced false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking:false") == 0,
                "tight false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("  Enable_Thinking: False \n") == 0,
                "case/trim false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking: true") == 1,
                "spaced true")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking:true") == 1,
                "tight true")) {
        return 1;
    }
    if (!expect(parse_thinking_command("/edit enable_thinking: false") == -1,
                "must not steal /edit")) {
        return 1;
    }
    if (!expect(parse_thinking_command("please enable_thinking: false") == -1,
                "must not steal prose")) {
        return 1;
    }
    if (!expect(parse_thinking_command("") == -1, "empty")) {
        return 1;
    }
    std::cout << "thinking_cmd_test ok" << std::endl;
    return 0;
}
