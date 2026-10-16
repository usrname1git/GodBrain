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
    std::ifstream input("contracts\\rag_search_v2_fixture.json");
    if (!input) {
        input.open("..\\..\\contracts\\rag_search_v2_fixture.json");
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
            fixture.at("contract_version") == "godbrain-rag-search-v2",
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
    std::string coli_notes;
    if (!expect(
            godbrain_rag::render_coli_notes(response, coli_notes, error),
            "coli notes were not rendered") ||
        !expect(
            coli_notes.find("citation[") == std::string::npos &&
                coli_notes.find("note[1].snippet=") != std::string::npos,
            "coli notes must be snippets only")) {
        return 1;
    }
    std::string bounded;
    if (!expect(
            godbrain_rag::compose_prompt_context(coli_notes, "", "", bounded, error) &&
                bounded.size() <= godbrain_rag::kContextBytes &&
                bounded.find("Reference text.", 161) != std::string::npos &&
                bounded.find(godbrain_rag::kUntrustedEnd) != std::string::npos &&
                bounded.find(godbrain_rag::kUntrustedEnd) == bounded.rfind(godbrain_rag::kUntrustedEnd),
            "bounded context lost the real snippet or admitted a forged delimiter")) return 1;
    for (size_t padding = 0; padding < 12; ++padding) {
        json large = fixture.at("response");
        std::string value = std::string(600 + padding, 'x') + "FACT_AFTER_THE_OLD_CAP ";
        for (int index = 0; index < 400; ++index) value += "\xF0\x9F\x98\x80[\\\n";
        large["results"][0]["snippet"] = value;
        if (!expect(
                godbrain_rag::render_coli_notes(large, coli_notes, error) &&
                    godbrain_rag::compose_prompt_context(
                        coli_notes, "", std::string(1200, 'p'), bounded, error) &&
                    bounded.size() <= godbrain_rag::kContextBytes &&
                    bounded.size() > 3900 &&
                    bounded.find("FACT_AFTER_THE_OLD_CAP") != std::string::npos &&
                    bounded.find("context_truncated=true") != std::string::npos &&
                    bounded.compare(bounded.size() - std::string(godbrain_rag::kUntrustedEnd).size() - 1,
                                    std::string(godbrain_rag::kUntrustedEnd).size(),
                                    godbrain_rag::kUntrustedEnd) == 0,
                "bounded context lost evidence, exceeded 4 KiB or cut its closing frame")) return 1;
        const size_t snippet_start = bounded.find(".snippet=") + 9;
        const size_t snippet_end = bounded.find('\n', snippet_start);
        const std::string encoded = bounded.substr(snippet_start, snippet_end - snippet_start);
        if (!expect(!json::parse('"' + encoded + '"', nullptr, false).is_discarded(),
                    "budget clipping split a UTF-8 code point or sanitizer escape")) return 1;
    }
    const std::string begin = std::string(godbrain_rag::kUntrustedBegin) + '\n';
    const std::string end = std::string(godbrain_rag::kUntrustedEnd) + '\n';
    const std::string local_block = begin + "session[1].status=candidate\n"
        "session[1].content=LOCAL_CONTINUITY\n" + end;
    if (!expect(
            godbrain_rag::compose_prompt_context("", local_block, "", bounded, error) &&
                bounded.find("LOCAL_CONTINUITY") != std::string::npos,
            "local-only continuity could not reach the bounded context") ||
        !expect(
            godbrain_rag::compose_prompt_context("", "", "pointer only", bounded, error) &&
                bounded.empty(),
            "an optional pointer fabricated nonempty evidence context")) return 1;
    for (const std::string invalid : {
             std::string("unframed"), begin + "status=verified\n" + end,
             begin + "missing_equals\n" + end,
             begin + "note[1].snippet=" + "\xC3\x28" + "\n" + end,
             begin + "note[1].snippet=" + godbrain_rag::kUntrustedEnd + "\n" + end}) {
        if (!expect(
                !godbrain_rag::compose_prompt_context(invalid, "", "", bounded, error) &&
                    bounded.empty() && !error.empty(),
                "malformed, metadata-only or invalid UTF-8 context was accepted")) return 1;
    }
    if (!expect(
            !godbrain_rag::compose_prompt_context(
                local_block, "", "", bounded, error, 160) && bounded.empty(),
            "the old 160-byte limit could masquerade as usable evidence") ||
        !expect(
            godbrain_rag::utf8_prefix(
                std::string(1199, 'p') + "\xF0\x9F\x98\x80" + "tail", 1200).size() == 1199,
            "bounded session-pointer reading split UTF-8")) return 1;
    const size_t first_end = context.find(godbrain_rag::kUntrustedEnd);
    if (!expect(
            first_end != std::string::npos &&
                context.find(godbrain_rag::kUntrustedEnd, first_end + 1) ==
                    std::string::npos,
            "retrieved delimiter was not escaped")) {
        return 1;
    }
    const std::string preserved_unicode =
        "Svenska "
        "\xC3\xA5\xC3\xA4\xC3\xB6 "
        "\xF0\x9F\x98\x80 "
        "\xE4\xB8\xAD\xE6\x96\x87";
    std::string sanitized;
    if (!expect(
            godbrain_rag::sanitize_value(preserved_unicode, sanitized) &&
                sanitized == preserved_unicode,
            "valid Swedish, emoji, or CJK UTF-8 was not preserved") ||
        !expect(
            godbrain_rag::sanitize_value(
                std::string("before") + "\xC2\x85" + "after",
                sanitized) &&
                sanitized == "before\\u0085after",
            "U+0085 was not escaped by code point") ||
        !expect(
            !godbrain_rag::sanitize_value(
                std::string("invalid") + "\xC2" + "x",
                sanitized),
            "invalid UTF-8 was accepted by the sanitizer")) {
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
    Client invalid_utf8([&](const std::string&) {
        std::string body = valid_body;
        body.insert(body.find("\"snippet\":\"") + 11, 1, '\xC2');
        return HttpResult{true, 200, "application/json", body};
    });
    if (!expect(
            !invalid_utf8.search(
                fixture.at("request").at("query").get<std::string>(),
                response,
                error),
            "invalid UTF-8 response did not fail closed")) {
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
    json missing_embedding = fixture.at("response");
    missing_embedding.erase("embedding");
    Client hybrid_without_embedding([&](const std::string&) {
        return HttpResult{
            true, 200, "application/json", missing_embedding.dump()};
    });
    if (!expect(
            !hybrid_without_embedding.search(
                fixture.at("request").at("query").get<std::string>(),
                response,
                error),
            "hybrid response without embedding metadata did not fail closed")) {
        return 1;
    }
    json mismatched_embedding = fixture.at("response");
    mismatched_embedding["embedding"]["vector_backend"] =
        "unbounded-vector-backend";
    Client hybrid_with_mismatched_embedding([&](const std::string&) {
        return HttpResult{
            true, 200, "application/json", mismatched_embedding.dump()};
    });
    if (!expect(
            !hybrid_with_mismatched_embedding.search(
                fixture.at("request").at("query").get<std::string>(),
                response,
                error),
            "hybrid response with mismatched vector metadata did not fail closed")) {
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

    const json graph_body = {
        {"generation", "gen-1"},
        {"projection_version", "hybrid-v1"},
        {"projection_schema", "rag-document-v2"},
        {"count", 1},
        {"truncated", false},
        {"links_truncated", false},
        {"nodes",
         json::array(
             {json{
                 {"node_id", "0123456789abcdef01234567"},
                 {"stable_id", "claim:auth"},
                 {"kind", "claim"},
                 {"sector", "security"},
                 {"status", "candidate"},
                 {"confidence", 0.9},
                 {"label", "Bearer authentication"}}})},
        {"links",
         json::array({json{
             {"source", "0123456789abcdef01234567"},
             {"target", "0123456789abcdef01234568"},
             {"kind", "same_source"}}})}};
    Client graph_client(
        [](const std::string&) { return HttpResult{}; },
        [&](const std::string& path) {
            if (path.find("/v1/graph?limit=") != 0) return HttpResult{};
            return HttpResult{true, 200, "application/json", graph_body.dump()};
        });
    json graph;
    if (!expect(
            graph_client.graph(250, graph, error),
            "valid graph response was rejected")) {
        return 1;
    }
    const json mapped = godbrain_rag::galaxy_graph(graph);
    if (!expect(
            mapped.at("nodes").at(0).at("group") == "security" &&
                mapped.at("nodes").at(0).at("id") == "0123456789abcdef01234567" &&
                mapped.at("nodes").at(0).at("stable_id") == "claim:auth" &&
                mapped.at("nodes").at(0).at("status") == "candidate" &&
                mapped.at("links").size() == 1 &&
                mapped.at("links").at(0).at("kind") == "same_source",
            "graph was not mapped to the Galaxy contract")) {
        return 1;
    }
    if (!expect(
            !graph_client.graph(501, graph, error) &&
                error == godbrain_rag::kErrGraphLimit,
            "oversized graph limit was accepted")) {
        return 1;
    }

    const json document_body = {
        {"node_id", "0123456789abcdef01234567"},
        {"stable_id", "claim:auth"},
        {"node_version", "v1"},
        {"kind", "claim"},
        {"sector", "security"},
        {"status", "candidate"},
        {"confidence", 0.9},
        {"schema_version", "claim-v1"},
        {"content", "Bearer authentication protects privileged actions."},
        {"label", "Bearer authentication protects privileged actions."}};
    Client document_client(
        [](const std::string&) { return HttpResult{}; },
        [&](const std::string& path) {
            if (path.find("/v1/document?id=") != 0) return HttpResult{};
            if (path.find("missing") != std::string::npos) {
                return HttpResult{
                    true, 404, "application/json",
                    "{\"error\":\"document not found\"}"};
            }
            return HttpResult{true, 200, "application/json", document_body.dump()};
        });
    json document;
    if (!expect(
            document_client.document("claim:auth", document, error),
            "valid document response was rejected")) {
        return 1;
    }
    const json node = godbrain_rag::galaxy_node(document);
    if (!expect(
            node.at("title") ==
                    "Bearer authentication protects privileged actions." &&
                node.at("type") == "claim" &&
                node.at("id") == "0123456789abcdef01234567" &&
                node.at("stable_id") == "claim:auth" &&
                node.at("status") == "candidate" &&
                node.at("sector") == "security" &&
                node.at("tags").size() == 2,
            "document was not mapped to the Galaxy node contract")) {
        return 1;
    }
    if (!expect(
            !document_client.document("missing", document, error) &&
                error == godbrain_rag::kErrDocumentNotFound,
            "missing document did not fail closed")) {
        return 1;
    }
    if (!expect(
            !document_client.document("", document, error) &&
                error == godbrain_rag::kErrDocumentIDRequired,
            "empty document id was accepted")) {
        return 1;
    }

    json skill_body = {{"query", "display rollback"}, {"count", 1}, {"skills", json::array({{
        {"name", "display-rollback"}, {"content", "Inspect the saved layout before rollback."},
        {"origin_node_id", "0123456789abcdef01234567"}, {"origin_hash", std::string(64, 'a')},
        {"verification_profile", "desk-v1"}, {"untrusted", true}
    }})}};
    int skill_posts = 0;
    Client skill_client(godbrain_rag::default_transport, godbrain_rag::default_get_transport,
        [&](const std::string& body) {
            ++skill_posts;
            const json request = json::parse(body);
            if (request != json({{"query", "display rollback"}, {"limit", 3}})) return HttpResult{};
            return HttpResult{true, 200, "application/json", skill_body.dump()};
        });
    if (!expect(skill_client.skills("display rollback", 3, response, error), "valid skill references rejected")) return 1;
    const json original_skill_body = skill_body;
    for (const char* field : {"untrusted", "origin_hash", "verification_profile", "content"}) {
        skill_body = original_skill_body;
        if (std::string(field) == "untrusted") skill_body["skills"][0][field] = false;
        else if (std::string(field) == "content") skill_body["skills"][0][field] = std::string(8193, 'x');
        else skill_body["skills"][0][field] = "invalid";
        if (!expect(!skill_client.skills("display rollback", 3, response, error), "bad skill accepted")) return 1;
    }
    skill_body = original_skill_body;
    skill_body["skills"].push_back(skill_body["skills"][0]);
    skill_body["count"] = 2;
    if (!expect(!skill_client.skills("display rollback", 3, response, error), "duplicate skill accepted")) return 1;
    skill_body = original_skill_body;
    skill_body["query"] = "another query";
    if (!expect(!skill_client.skills("display rollback", 3, response, error), "wrong skill query accepted")) return 1;
    const int before_invalid = skill_posts;
    if (!expect(!skill_client.skills(std::string(513, 'x'), 3, response, error) &&
                    skill_posts == before_invalid, "invalid skill query reached transport")) return 1;
    skill_body = {{"query", "display rollback"}, {"count", 0}, {"skills", json::array()}};
    if (!expect(skill_client.skills("display rollback", 3, response, error), "empty skill matches treated as failure")) return 1;
    Client failed_skills(godbrain_rag::default_transport, godbrain_rag::default_get_transport,
        [](const std::string&) { return HttpResult{true, 503, "application/json", "{}"}; });
    if (!expect(!failed_skills.skills("display rollback", 3, response, error), "unavailable skills silently succeeded")) return 1;
    std::cout << "C++ canonical RAG contract tests passed." << std::endl;
    return 0;
}
