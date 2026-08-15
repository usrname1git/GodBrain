#include <iostream>
#include <string>

#include "coli_sse.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    std::string assembled;
    int pings = 0;
    std::string last_token;
    auto on_token = [&](const std::string& token) { last_token = token; };
    auto on_ping = [&]() { ++pings; };

    godbrain_coli::handle_sse_event(
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}",
        assembled,
        on_token,
        on_ping);
    if (!expect(assembled == "Hi" && last_token == "Hi", "token event")) {
        return 1;
    }

    godbrain_coli::handle_sse_event(
        "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}",
        assembled,
        on_token,
        on_ping);
    if (!expect(pings == 1 && assembled == "Hi", "empty delta is ping")) {
        return 1;
    }

    std::string finish;
    godbrain_coli::handle_sse_event(
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}",
        assembled, on_token, on_ping,
        [&](const std::string& reason) { finish = reason; });
    if (!expect(finish == "length", "finish_reason length")) {
        return 1;
    }

    godbrain_coli::handle_sse_event("data: [DONE]", assembled, on_token, on_ping);
    if (!expect(assembled == "Hi" && pings == 1, "[DONE] is a no-op")) {
        return 1;
    }

    godbrain_coli::handle_sse_event("data: not-json\n", assembled, on_token, on_ping);
    if (!expect(assembled == "Hi", "malformed JSON is ignored")) {
        return 1;
    }

    std::string buf;
    std::string streamed;
    const std::string partial =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Ab\"}}]}\n";
    godbrain_coli::feed_sse(
        buf, partial.data(), partial.size(), streamed, on_token, on_ping);
    if (!expect(streamed.empty() && !buf.empty(), "partial SSE stays buffered")) {
        return 1;
    }
    const char nl[] = "\n";
    godbrain_coli::feed_sse(buf, nl, 1, streamed, on_token, on_ping);
    if (!expect(streamed == "Ab" && buf.empty(), "split event assembles")) {
        return 1;
    }

    std::cout << "coli_sse_test ok" << std::endl;
    return 0;
}
