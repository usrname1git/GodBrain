#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "session_context.h"

#include <iostream>

using godbrain_rag::json;
using godbrain_session::Thought;

static void check(bool ok, const char* why) {
    if (!ok) throw std::runtime_error(why);
}

static json document() {
    return {
        {"node_id", "0123456789abcdef01234567"}, {"stable_id", "fixture-origin"},
        {"node_version", "v1"}, {"kind", "claim"}, {"sector", "windows-sre"},
        {"status", "verified"}, {"confidence", 1.0}, {"schema_version", "claim-v1"},
        {"content", "CURRENT_ORIGIN_CONTENT"}, {"label", "Fixture origin"},
    };
}

struct Fixture {
    json current = document();
    int status = 200;
    bool available = true;
    std::string content_type = "application/json";
    std::optional<std::string> raw_body;
    int reads = 0;
    int pin_reads = 0;
    bool pin_fails = false;
    std::string pin = "fixture/123.45";

    godbrain_session::Resolution resolve(const std::vector<Thought>& cached) {
        const godbrain_rag::Client client(
            [](const std::string&) -> godbrain_rag::HttpResult {
                throw std::runtime_error("Session lookup must not POST");
            },
            [&](const std::string& path) {
                check(path.find("/v1/document?id=") == 0, "Noncanonical origin lookup");
                ++reads;
                return godbrain_rag::HttpResult{
                    available, status, content_type, raw_body.value_or(current.dump())};
            });
        return godbrain_session::resolve(cached, client, [&] {
            ++pin_reads;
            if (pin_fails) throw std::runtime_error("Fixture sensor unavailable");
            return pin;
        });
    }
};

static std::string rendered(const godbrain_session::Resolution& resolved) {
    std::string context, error;
    check(godbrain_session::render(resolved, context, error) && error.empty(),
          "Valid session did not render");
    return context;
}

int main() {
    try {
        const Thought original = godbrain_session::rag_note(document());
        const Thought local = godbrain_session::local_note(
            "local-hash", "local-note", "LOCAL_NOTE_CONTINUITY", "verified");
        check(local.status == "candidate", "A local caller invented verified trust");
        Fixture fixture;
        const auto fresh = fixture.resolve({original});
        check(fresh.thoughts.size() == 1 && fresh.omitted.empty() && fixture.reads == 1 &&
                  fixture.pin_reads == 0 &&
                  rendered(fresh).find("CURRENT_ORIGIN_CONTENT") != std::string::npos,
              "Current unpinned origin was not rechecked");
        for (const auto* status : {"candidate", "rejected", "stale", "unknown", "Verified"}) {
            fixture.current["status"] = status;
            const auto result = fixture.resolve({original, local});
            check(result.thoughts.size() == 1 && result.omitted.size() == 1 &&
                      rendered(result).find("CURRENT_ORIGIN_CONTENT") == std::string::npos &&
                      rendered(result).find("LOCAL_NOTE_CONTINUITY") != std::string::npos,
                  "Retired RAG content survived or unrelated local notes were lost");
        }
        for (const auto* field : {"node_id", "stable_id", "node_version", "schema_version",
                                  "kind", "sector", "content"}) {
            fixture.current = document();
            fixture.current[field] = "changed";
            const auto result = fixture.resolve({original});
            check(result.thoughts.empty() && result.omitted.size() == 1 &&
                      rendered(result).empty(), "An origin binding change was accepted");
        }
        for (int status : {404, 503, 500, 400}) {
            fixture.current = document();
            fixture.status = status;
            check(fixture.resolve({original}).thoughts.empty(),
                  "A failed document read used cached content");
        }
        fixture.status = 200;
        fixture.available = false;
        check(rendered(fixture.resolve({original})).empty(),
              "An unreachable service supplied nonempty fallback context");
        check(rendered(fixture.resolve({local})).find("LOCAL_NOTE_CONTINUITY") !=
                  std::string::npos, "Local notes depended on RAG availability");
        fixture.available = true;
        for (const auto* body : {"{", "[]", "{}", R"({"error":"not ready"})"}) {
            fixture.raw_body = body;
            check(fixture.resolve({original}).thoughts.empty(),
                  "Malformed origin response was accepted");
        }
        fixture.raw_body.reset();
        fixture.current["extra"] = true;
        check(fixture.resolve({original}).thoughts.empty(), "Unknown origin fields were accepted");
        fixture.current = document();
        fixture.current.erase("node_version");
        check(fixture.resolve({original}).thoughts.empty(), "Missing identity metadata was accepted");
        fixture.current = document();
        fixture.content_type = "text/html";
        check(fixture.resolve({original}).thoughts.empty(), "HTML origin response was accepted");
        fixture.content_type = "application/json";
        fixture.raw_body = std::string(godbrain_rag::kMaxResponseBytes + 1, ' ');
        check(fixture.resolve({original}).thoughts.empty(), "Oversized origin response was accepted");
        fixture.raw_body.reset();
        fixture.current = document();
        check(fixture.resolve({original}).thoughts.size() == 1 &&
                  original.status == "verified" && original.content == "CURRENT_ORIGIN_CONTENT",
              "Transient failure destroyed the cached identity or prevented recovery");

        auto long_document = document();
        long_document["content"] = std::string(300, 'a') + "ORIGINAL_TAIL";
        const Thought long_origin = godbrain_session::rag_note(long_document);
        fixture.current = long_document;
        fixture.current["content"] = std::string(300, 'a') + "CHANGED_TAIL";
        check(fixture.resolve({long_origin}).thoughts.empty(),
              "Content changed beyond the displayed snippet without invalidating its binding");

        for (const auto* pins : {
                 "os_pin=fixture/123.45\n",
                 "os_pin=fixture/123.45\tos_pin=fixture/123.45",
                 "os_pin=fixture/123.450\n",
                 "os_pin=fixture/123.45\nos_pin=old/1",
                 "os_pin=\n"}) {
            auto host = document();
            host["content"] = std::string(300, 'b') + "\n" + pins;
            const Thought bound = godbrain_session::rag_note(host);
            fixture.current = host;
            const auto result = fixture.resolve({bound});
            const bool mismatch = godbrain_pin::has_mismatched_os_pin(
                host.at("content"), fixture.pin);
            check(result.thoughts.empty() == mismatch,
                  "Host applicability was read from a clipped snippet or matched a pin prefix");
        }
        fixture.current = document();
        fixture.current["content"] = "Host fact\nos_pin=fixture/123.45\n";
        const Thought host = godbrain_session::rag_note(fixture.current);
        fixture.pin_fails = true;
        fixture.pin_reads = 0;
        const auto failed_pin = fixture.resolve({host, host, local});
        check(failed_pin.omitted.size() == 2 && fixture.pin_reads == 1 &&
                  rendered(failed_pin).find("LOCAL_NOTE_CONTINUITY") != std::string::npos,
              "Failed host reads fabricated eligibility, retried per card or erased local notes");
        fixture.pin_fails = false;
        fixture.pin.clear();
        check(fixture.resolve({host}).thoughts.empty(), "Missing live pin was accepted");
        fixture.pin = "fixture/123.45";
        check(fixture.resolve({host}).thoughts.size() == 1,
              "Host-read recovery could not restore an unchanged eligible reference");

        fixture.current = document();
        fixture.current["sector"] = "personal";
        const Thought personal = godbrain_session::rag_note(fixture.current);
        check(fixture.resolve({personal}).thoughts.empty(),
              "Personal RAG content entered technical session context");
        const Thought shelf = godbrain_session::local_note(
            "shelf", "shelf", "PERSONAL_SHELF_ONLY", "candidate", "personal");
        const auto local_only = fixture.resolve({shelf, local});
        check(local_only.thoughts.size() == 2 &&
                  rendered(local_only).find("PERSONAL_SHELF_ONLY") == std::string::npos,
              "Personal operator notes leaked or were removed from the local shelf");

        fixture.current = document();
        Thought judged = godbrain_session::local_note(
            "saved-hash", "fixture-origin", fixture.current.at("content"),
            "candidate", fixture.current.at("sector"));
        godbrain_session::require_origin(judged);
        check(judged.origin == godbrain_session::Origin::Rag &&
                  fixture.resolve({judged}).thoughts.size() == 1,
              "An authorized judgment could not resolve the matching current origin");
        godbrain_session::bind_origin(judged, fixture.resolve({judged}).thoughts.front());
        fixture.current["node_version"] = "v2";
        check(fixture.resolve({judged}).thoughts.empty(),
              "A judged local note did not bind its first observed canonical version");
        fixture.current = document();
        fixture.current["status"] = "stale";
        check(fixture.resolve({judged}).thoughts.empty(),
              "Authorized judgment cached verified trust after origin retirement");
        check(godbrain_session::matches(original, original.lookup_id) &&
                  godbrain_session::matches(judged, "saved-hash") &&
                  !godbrain_session::matches(original, ""),
              "Origin judgments no longer match their stable, node or source identity");
        auto empty_document = document();
        empty_document["content"] = "";
        fixture.current = empty_document;
        check(rendered(fixture.resolve({godbrain_session::rag_note(empty_document)})).empty(),
              "An empty origin made a nonempty fallback wrapper");

        fixture.current = document();
        fixture.reads = 0;
        check(fixture.resolve(std::vector<Thought>(10, original)).thoughts.size() == 3 &&
                  fixture.reads == 3, "Session origin reads exceeded the three-note bound");
        const std::string unicode = std::string(239, 'u') + "\xe2\x82\xac" + "tail";
        const Thought unicode_note = godbrain_session::local_note("u", "u", unicode);
        check(unicode_note.content.size() == 239 &&
                  !rendered(fixture.resolve({unicode_note})).empty(),
              "Snippet clipping split a UTF-8 code point");
        const Thought invalid = godbrain_session::local_note("bad", "bad", "\xc3\x28");
        std::string context = "previous context", error;
        check(!godbrain_session::render(fixture.resolve({invalid}), context, error) &&
                  context.empty() && !error.empty(), "Invalid UTF-8 returned usable context");
        const Thought oversized = godbrain_session::local_note(
            std::string(godbrain_rag::kMaxRenderedContextBytes, 'h'), "large", "note");
        check(!godbrain_session::render(fixture.resolve({oversized}), context, error) &&
                  context.empty(), "Oversized rendered context did not fail closed");
        std::cout << "PASS: session origin freshness, isolation, recovery and bounds\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
