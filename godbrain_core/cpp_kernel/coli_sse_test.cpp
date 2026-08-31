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

    std::string think_only;
    std::string spoken;
    godbrain_coli::handle_sse_event(
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"plan \"}}]}",
        think_only,
        on_token,
        on_ping,
        {},
        &spoken);
    godbrain_coli::handle_sse_event(
        "data: {\"choices\":[{\"delta\":{\"content\":\"done.\"}}]}",
        think_only,
        on_token,
        on_ping,
        {},
        &spoken);
    if (!expect(think_only == "plan done." && spoken == "done.",
                "think streams, spoken is content only")) {
        return 1;
    }

    nlohmann::json tools = nlohmann::json::array();
    std::string tool_assembled;
    godbrain_coli::handle_sse_event(
        R"SSE(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"list_local_dir","arguments":"{"}}]}}]})SSE",
        tool_assembled, on_token, on_ping, {}, nullptr, &tools);
    godbrain_coli::handle_sse_event(
        R"SSE(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"path\":\"C:\\Temp\"}"}}]}}]})SSE",
        tool_assembled, on_token, on_ping, {}, nullptr, &tools);
    std::string tool_finish;
    godbrain_coli::handle_sse_event(
        R"SSE(data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]})SSE",
        tool_assembled, on_token, on_ping,
        [&](const std::string& r) { tool_finish = r; }, nullptr, &tools);
    if (!expect(tool_assembled.empty(), "tool_calls are not spoken content")) {
        return 1;
    }
    if (!expect(tool_finish == "tool_calls", "finish_reason tool_calls")) {
        return 1;
    }
    if (!expect(tools.size() == 1 &&
                    tools[0]["function"]["name"] == "list_local_dir" &&
                    tools[0]["id"] == "c1" &&
                    tools[0]["function"]["arguments"].get<std::string>().find(
                        "path") != std::string::npos,
                "tool_calls accumulate by index")) {
        return 1;
    }

    nlohmann::json msg_tools = nlohmann::json::array();
    std::string msg_assembled;
    godbrain_coli::handle_sse_event(
        R"SSE(data: {"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c2","type":"function","function":{"name":"list_granted_roots","arguments":"{}"}}]},"finish_reason":"tool_calls"}]})SSE",
        msg_assembled, on_token, on_ping, {}, nullptr, &msg_tools);
    if (!expect(msg_tools.size() == 1 &&
                    msg_tools[0]["function"]["name"] == "list_granted_roots",
                "tool_calls on message not only delta")) {
        return 1;
    }

    std::cout << "coli_sse_test ok" << std::endl;
    return 0;
}
