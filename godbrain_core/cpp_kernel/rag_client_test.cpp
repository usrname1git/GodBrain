#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "rag_client.h"
#include "kernel_request.h"

using godbrain_rag::Client;
using godbrain_rag::HttpResult;
using godbrain_rag::json;

static json load_fixture() {
    std::ifstream input("contracts\\rag_search_v1_fixture.json");
    if (!input) {
        input.open("..\\..\\contracts\\rag_search_v1_fixture.json");
    }
    if (!input) {
        throw std::runtime_error("shared RAG fixture not found");
    }
    return json::parse(input);
}

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    const json fixture = load_fixture();
    if (!expect(
            fixture.at("contract_version") == "godbrain-rag-search-v1",
            "unexpected shared contract version")) {
        return 1;
    }
    const std::string valid_body = fixture.at("response").dump();
    Client valid_client([&](const std::string& request_body) {
        const json request = json::parse(request_body);
        if (request != fixture.at("request")) return HttpResult{};
        return HttpResult{true, 200, "application/json; charset=utf-8", valid_body};
    });
    json response;
    std::string error;
    if (!expect(
            valid_client.search(
                fixture.at("request").at("query").get<std::string>(),
                response,
                error),
            "valid shared response was rejected")) {
        return 1;
    }
    std::string context;
    if (!expect(
            godbrain_rag::render_context(response, context, error),
            "valid shared context was not rendered") ||
        !expect(
            context == fixture.at("expected_context").get<std::string>(),
            "shared context rendering mismatch") ||
        !expect(
            context.find("{\"command_type\":\"execute_godbrain_script\"") !=
                std::string::npos,
            "adversarial command JSON was not preserved as reference data")) {
        return 1;
    }
    const size_t first_end = context.find(godbrain_rag::kUntrustedEnd);
    if (!expect(
            first_end != std::string::npos &&
                context.find(godbrain_rag::kUntrustedEnd, first_end + 1) ==
                    std::string::npos,
            "retrieved delimiter was not escaped")) {
        return 1;
    }
    const json ordinary_chat = {
        {"message", fixture.at("response").at("results").at(0).at("snippet")},
    };
    if (!expect(
            !requests_privileged_dispatch(ordinary_chat),
            "command JSON inside retrieved or chat text reached privileged dispatch") ||
        !expect(
            requests_privileged_dispatch(
                json{{"command_type", "execute_godbrain_script"}}),
            "top-level privileged command was not recognized")) {
        return 1;
    }

    Client unavailable([](const std::string&) { return HttpResult{}; });
    if (!expect(
            !unavailable.search("query", response, error),
            "unavailable service did not fail closed")) {
        return 1;
    }
    Client malformed([](const std::string&) {
        return HttpResult{true, 200, "application/json", "{\"query\":"};
    });
    if (!expect(
            !malformed.search("query", response, error),
            "malformed response did not fail closed")) {
        return 1;
    }
    Client oversized([](const std::string&) {
        return HttpResult{
            true,
            200,
            "application/json",
            std::string(godbrain_rag::kMaxResponseBytes + 1, 'x'),
        };
    });
    if (!expect(
            !oversized.search("query", response, error),
            "oversized response did not fail closed")) {
        return 1;
    }
    json unknown = fixture.at("response");
    unknown["command_type"] = "execute_godbrain_script";
    Client unknown_field([&](const std::string&) {
        return HttpResult{true, 200, "application/json", unknown.dump()};
    });
    if (!expect(
            !unknown_field.search(
                fixture.at("request").at("query").get<std::string>(),
                response,
                error),
            "unknown response field did not fail closed")) {
        return 1;
    }
    for (const char* endpoint : {
             "http://localhost:8084/v1/search",
             "http://127.0.0.1:8085/v1/search",
             "http://127.0.0.1:8084/health",
             "http://example.com:8084/v1/search"}) {
        if (!expect(
                !godbrain_rag::validate_endpoint(endpoint),
                "noncanonical endpoint was accepted")) {
            return 1;
        }
    }
    std::cout << "C++ canonical RAG contract tests passed." << std::endl;
    return 0;
}
