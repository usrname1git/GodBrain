#define WIN32_LEAN_AND_MEAN
#include "truth_assertion.h"
#include <windows.h>

#include <iostream>
#include <map>
#include <set>
#include <vector>

using godbrain_truth::json;

static void check(bool ok, const char* why) {
    if (!ok) throw std::runtime_error(why);
}

template <class Call> static void rejects(Call call) {
    try {
        call();
    } catch (const std::exception&) {
        return;
    }
    throw std::runtime_error("Expected assertion failure");
}

static json doc_request() {
    return {{"class", "doc_fact"},
            {"text", "UNSUPPORTED: this procedure fixes every host."},
            {"learn_url", "https://learn.microsoft.com/en-us/fixture?q=one#section"},
            {"quote", "This documentation contains a fixture sentence."}};
}

static json host_request(const std::string& kind = "service",
                         const std::string& expect = "running") {
    return {{"class", "host_fact"},
            {"text", "UNSUPPORTED: this host is always healthy."},
            {"probe",
             {{"kind", kind},
              {"name", "FixtureService"},
              {"path", "SOFTWARE\\Fixture"},
              {"expect", expect}}}};
}

struct Fixture {
    std::vector<std::string> calls;
    std::vector<json> notes;
    std::vector<json> documents;
    std::vector<json> judgments;
    godbrain_truth::Document page{
        "<html><p>This documentation contains a fixture sentence.</p></html>",
        "text/html; charset=utf-8", true};
    godbrain_truth::Observation observed{true, "running", {{"service_state", 4}}};
    std::string pin = "Core/26100.0";
    std::optional<std::string> pin_after_probe;
    bool fail_pin_recheck = false;
    int pin_reads = 0;
    std::string fail;
    bool noop = false;
    bool persist = false;
    std::map<std::string, std::string> committed_runs;
    std::set<std::string> nodes;
    json ingest_override = json::object();
    json judgment_override = json::object();

    json run(const json& request = doc_request()) {
        return godbrain_truth::promote(
            request,
            [&](const std::string& url) {
                calls.push_back("fetch");
                check(url == "https://learn.microsoft.com/en-us/fixture?q=one",
                      "Fetch URL lost its query or retained its fragment");
                if (fail == "fetch") throw std::runtime_error("fixture transport failed");
                return page;
            },
            [&](const godbrain_truth::Probe&) {
                calls.push_back("probe");
                if (fail == "probe") throw std::runtime_error("fixture probe denied");
                return observed;
            },
            [&] {
                calls.push_back("pin");
                ++pin_reads;
                if (fail == "pin" || (fail_pin_recheck && pin_reads > 1))
                    throw std::runtime_error("fixture sensor unavailable");
                if (pin_reads > 1 && pin_after_probe) return *pin_after_probe;
                return pin;
            },
            [&](const json& input) {
                calls.push_back("save");
                if (fail == "save") throw std::runtime_error("fixture note persistence failed");
                notes.push_back(input);
                return json{{"status", "success"}, {"stable_id", std::string(64, 'c')}};
            },
            [&](const json& input) {
                calls.push_back("ingest");
                if (fail == "ingest") throw std::runtime_error("fixture projection failed");
                documents.push_back(input);
                std::string id(64, 'a');
                std::string status = noop ? "idempotent_noop" : "committed";
                if (persist) {
                    const auto& claim = input.at("payload").at("claims").at(0);
                    id = keccak256(
                        std::string("claim") + '\0' + claim.at("type").get<std::string>() + '\0' +
                        godbrain_truth::collapse_ws(claim.at("content").get<std::string>()));
                    const auto key =
                        json::array({input.at("payload").at("provenance").at("source_hash"),
                                     input.at("extractor_id"), input.at("extractor_version"),
                                     input.at("schema_version")})
                            .dump();
                    if (committed_runs.emplace(key, id).second)
                        nodes.insert(id);
                    else
                        status = "idempotent_noop";
                }
                json receipt = {{"status", "success"},
                                {"store_status", status},
                                {"stable_id", id},
                                {"source_hash", input["payload"]["provenance"]["source_hash"]},
                                {"run_id", "fixture-run"},
                                {"record_id", "fixture-record"}};
                receipt.update(ingest_override);
                return receipt;
            },
            [&](const json& input) {
                calls.push_back("judge");
                check(input.at("id") != std::string(64, 'c'),
                      "Caller prose reached automatic judgment");
                if (persist)
                    check(nodes.count(input.at("id").get<std::string>()) == 1,
                          "Assertion judgment targeted a node absent from its committed run");
                if (fail == "judge") throw std::runtime_error("fixture judgment failed");
                judgments.push_back(input);
                json receipt = {{"status", noop ? "idempotent_noop" : "judged"},
                                {"stable_id", input.at("id")},
                                {"to", "verified"}};
                receipt.update(judgment_override);
                return receipt;
            });
    }
};

static void check_separation(const Fixture& fixture, const json& result) {
    check(result.at("trust") == "candidate" && result.at("promoted") == false,
          "A passing check crowned caller prose");
    check(result.at("assertion").at("trust") == "verified" &&
              result.at("assertion").at("promoted") == true,
          "The canonical observation was not verified");
    const auto& envelope = fixture.documents.back();
    const auto raw = envelope.at("raw_transcript").get<std::string>();
    const auto content = envelope.at("payload").at("claims").at(0).at("content").get<std::string>();
    check(raw.find("UNSUPPORTED") == std::string::npos &&
              content.find("UNSUPPORTED") == std::string::npos,
          "Caller interpretation contaminated verified content or evidence");
    check(envelope.at("payload").at("trust_tier") == "candidate",
          "Assertion bypassed candidate ingestion");
    check(envelope.at("payload").at("provenance").at("source_hash") == keccak256(raw),
          "Immutable raw evidence is not bound to its exact hash");
    check(envelope.at("payload").at("claims").at(0).at("evidence_spans").at(0) ==
              "[0:" + std::to_string(raw.size()) + "]",
          "Evidence span does not cover the source");
    check(json::parse(raw).at("checker_version") == godbrain_truth::kVersion &&
              content.find("checker_version=1.0.0") != std::string::npos,
          "Checker version was not bound");
}

int main(int argc, char** argv) {
    try {
        if (argc == 2 && (std::string(argv[1]) == "--emit-envelope" ||
                          std::string(argv[1]) == "--emit-roundtrip")) {
            Fixture fixture;
            const bool roundtrip = std::string(argv[1]) == "--emit-roundtrip";
            auto request = host_request();
            if (roundtrip) {
                const std::string value = std::string("  two  spaces\tline\nnext\r\f\v ") +
                                          "\xc2\xa0" + "\xe2\x80\x83" + "\xc3\x85" + "  ";
                fixture.observed = {
                    true, value, {{"value_type", "REG_SZ"}, {"detail  key", "  exact\tvalue\n"}}};
                request = host_request("registry_value", value);
                request["probe"]["path"] = "SOFTWARE\\Fixture  Key";
                request["probe"]["name"] = std::string("Fixture  ") + "\xc3\x85" + " Value";
            }
            fixture.run(request);
            const auto& document = fixture.documents.back();
            if (roundtrip) {
                const auto& claim = document.at("payload").at("claims").at(0);
                const auto id = keccak256(
                    std::string("claim") + '\0' + claim.at("type").get<std::string>() + '\0' +
                    godbrain_truth::collapse_ws(claim.at("content").get<std::string>()));
                std::cout << json{{"envelope", document}, {"kernel_stable_id", id}}.dump(2, ' ',
                                                                                         true)
                          << '\n';
            } else {
                std::cout << document.dump(2, ' ', true) << '\n';
            }
            return 0;
        }
        {
            Fixture fixture;
            const auto result = fixture.run();
            check_separation(fixture, result);
            const auto raw =
                json::parse(fixture.documents.back().at("raw_transcript").get<std::string>());
            check(raw.at("evidence").at("body") == fixture.page.body &&
                      raw.at("observation").at("document_keccak256") ==
                          keccak256(fixture.page.body),
                  "Only a quote/hash was retained, not the complete fetched source");
            check(fixture.calls == std::vector<std::string>{"fetch", "save", "ingest", "judge"},
                  "Document verification used a host sensor or reordered the commit gate");
            const auto original = fixture.documents.back();
            fixture.noop = true;
            auto changed = doc_request();
            changed["text"] = "UNSUPPORTED: another caller interpretation.";
            const auto repeated = fixture.run(changed);
            check_separation(fixture, repeated);
            check(fixture.documents.back() == original,
                  "Retry or different caller prose changed canonical evidence identity");
            fixture.page.body += "<p>new source version</p>";
            fixture.run();
            check(fixture.documents.back()["payload"]["provenance"]["source_hash"] !=
                      original["payload"]["provenance"]["source_hash"],
                  "Changed source bytes reused the old source hash");
            fixture.page.body += std::string(40 * 1024, 'x');
            fixture.run();
            check(json::parse(fixture.documents.back().at("raw_transcript").get<std::string>())
                          .at("evidence")
                          .at("body") == fixture.page.body,
                  "Document evidence was truncated to the small thought limit");
        }
        {
            Fixture fixture;
            fixture.persist = true;
            const auto first = fixture.run();
            auto request = doc_request();
            request["text"] = "UNSUPPORTED: another sector's caller interpretation.";
            request["sector"] = "operator";
            const auto second = fixture.run(request);
            check_separation(fixture, second);
            check(first.at("assertion").at("source_hash") !=
                          second.at("assertion").at("source_hash") &&
                      first.at("assertion").at("stable_id") !=
                          second.at("assertion").at("stable_id") &&
                      fixture.committed_runs.size() == 2 && fixture.nodes.size() == 2,
                  "Distinct sectors reused an assertion run without inserting their own node");
            request["sector"] = " \tOPERATOR\r\n ";
            request["text"] = "UNSUPPORTED: revised prose with the same canonical sector.";
            const auto repeated = fixture.run(request);
            check(repeated.at("assertion").at("store_status") == "idempotent_noop" &&
                      repeated.at("assertion").at("source_hash") ==
                          second.at("assertion").at("source_hash") &&
                      repeated.at("assertion").at("stable_id") ==
                          second.at("assertion").at("stable_id") &&
                      fixture.committed_runs.size() == 2 && fixture.nodes.size() == 2,
                  "Canonical sector retry changed identity or created another run");
        }
        {
            const json observation = {
                {"two  spaces", std::string("  exact\tvalue\n") + "\xc2\xa0\xe2\x80\x83"},
                {"path", "C:\\Fixture  Directory\\value"}};
            const auto encoded = godbrain_truth::observation_text(observation);
            check(encoded.find_first_of(" \t\r\n\f\v") == std::string::npos &&
                      json::parse(encoded) == observation,
                  "Observation encoding cannot preserve exact values through normalization");
            for (unsigned char ch : encoded)
                check(ch < 128, "Observation encoding retained Unicode whitespace");
        }
        for (const auto* kind : {"registry_key", "registry_value", "appx", "service", "file"}) {
            Fixture fixture;
            fixture.observed = {true,
                                std::string(kind) == "service" ? "running" : "present",
                                {{"scope", "synthetic Windows observation"}}};
            auto request =
                host_request(kind, std::string(kind) == "service" ? "running" : "present");
            if (std::string(kind) == "file")
                request["probe"]["path"] = "C:\\Windows\\System32\\fixture.dll";
            const auto result = fixture.run(request);
            check_separation(fixture, result);
            check(fixture.calls ==
                      std::vector<std::string>{"pin", "probe", "pin", "save", "ingest", "judge"},
                  "Host verification bypassed its live pin or used document fetching");
            check(result.at("assertion")
                          .at("content")
                          .get<std::string>()
                          .find("os_pin=Core/26100.0\n") != std::string::npos,
                  "Host assertion lost pin applicability");
        }
        for (const auto* pin : {"Core/26100.1", ""}) {
            Fixture fixture;
            fixture.pin_after_probe = pin;
            rejects([&] { fixture.run(host_request()); });
            check(fixture.notes.empty() && fixture.documents.empty() && fixture.judgments.empty(),
                  "A changed or invalid post-probe OS pin reached persistence");
        }
        {
            Fixture fixture;
            fixture.fail_pin_recheck = true;
            rejects([&] { fixture.run(host_request()); });
            check(fixture.notes.empty() && fixture.documents.empty() && fixture.judgments.empty(),
                  "An unavailable post-probe OS pin retained verification authority");
        }
        for (const std::string& sector :
             {std::string("WINDOWS") + "\xc2\xa0" + "SRE", std::string("CAF") + "\xc3\x89"}) {
            for (const bool host : {false, true}) {
                Fixture fixture;
                auto request = host ? host_request() : doc_request();
                request["sector"] = sector;
                rejects([&] { fixture.run(request); });
                check(fixture.calls.empty(),
                      "A sector with incompatible C++/Go normalization reached a source read");
            }
        }
        {
            Fixture fixture;
            fixture.observed = {true, "start_pending", {{"service_state", 2}}};
            const auto mismatch = fixture.run(host_request());
            check(mismatch.at("probe_ok") == false && mismatch.at("observed") == "start_pending" &&
                      !mismatch.contains("assertion") && fixture.judgments.empty(),
                  "Pending SCM state became stopped/running or reached judgment");
        }
        {
            Fixture fixture;
            fixture.observed = {true, "not-the-requested-value", {{"value_type", "REG_SZ"}}};
            const auto mismatch = fixture.run(host_request("registry_value", "requested"));
            check(!mismatch.at("probe_ok").get<bool>() && fixture.documents.empty(),
                  "A substring registry match retained verification authority");
            fixture.observed.value = "Requested";
            check(!fixture.run(host_request("registry_value", "requested"))
                       .at("probe_ok")
                       .get<bool>(),
                  "Registry exact-value comparison ignored case");
            fixture.observed.value = "requested";
            check_separation(fixture, fixture.run(host_request("registry_value", "requested")));
        }
        {
            Fixture fixture;
            auto payload = doc_request();
            payload["quote"] = "this documentation contains a fixture sentence.";
            const auto mismatch = fixture.run(payload);
            check(!mismatch.at("quote_matched").get<bool>() && !mismatch.contains("assertion") &&
                      fixture.documents.empty() && fixture.judgments.empty(),
                  "Case-insensitive resemblance became an exact documentation quote");
        }
        {
            Fixture fixture;
            const auto result =
                fixture.run({{"class", "playbook"}, {"text", "UNSUPPORTED playbook"}});
            check(result.at("trust") == "candidate" && !result.contains("assertion") &&
                      fixture.calls == std::vector<std::string>{"save"},
                  "Playbook acquired auto-verification");
        }
        for (const auto* fail : {"fetch", "save", "ingest", "judge"}) {
            Fixture fixture;
            fixture.fail = fail;
            rejects([&] { fixture.run(); });
            if (fixture.fail != "judge")
                check(fixture.judgments.empty(), "Failure reached judgment");
            fixture.fail.clear();
            check_separation(fixture, fixture.run());
        }
        for (const auto* fail : {"pin", "probe"}) {
            Fixture fixture;
            fixture.fail = fail;
            rejects([&] { fixture.run(host_request()); });
            check(fixture.notes.empty() && fixture.documents.empty() && fixture.judgments.empty(),
                  "Failed sensor generated purported absence or an assertion");
        }
        for (const auto& bad : {json{{"status", "failed"}}, json{{"store_status", "staging"}},
                                json{{"stable_id", ""}}, json{{"stable_id", "nonhex"}},
                                json{{"source_hash", std::string(64, 'f')}}, json{{"run_id", ""}},
                                json{{"record_id", ""}}}) {
            Fixture fixture;
            fixture.ingest_override = bad;
            rejects([&] { fixture.run(); });
            check(fixture.judgments.empty(), "Malformed ingestion receipt reached judgment");
        }
        for (const auto& bad : {json{{"status", "failed"}}, json{{"to", "candidate"}},
                                json{{"stable_id", std::string(64, 'b')}}}) {
            Fixture fixture;
            fixture.judgment_override = bad;
            rejects([&] { fixture.run(); });
        }
        for (const auto* bad : {"", "unknown/0.0", "Core/26100.00", "Core/0.1", "Core/26100.x"}) {
            Fixture fixture;
            fixture.pin = bad;
            rejects([&] { fixture.run(host_request()); });
            check(fixture.notes.empty(), "Invalid host pin was persisted");
        }
        {
            Fixture fixture;
            fixture.observed.complete = false;
            rejects([&] { fixture.run(host_request()); });
            check(fixture.notes.empty(), "Incomplete probe was retained as a complete read");
        }
        for (const auto* bad :
             {"http://learn.microsoft.com/a", "https://example.com/a",
              "https://learn.microsoft.com.evil.invalid/a", "https://user@learn.microsoft.com/a",
              "https://learn.microsoft.com:8443/a",
              "https://learn.microsoft.com\\@example.com/a"}) {
            Fixture fixture;
            auto request = doc_request();
            request["learn_url"] = bad;
            rejects([&] { fixture.run(request); });
            check(fixture.calls.empty(), "Disallowed document URL reached the fetch");
        }
        check(godbrain_truth::document_url("HTTPS://LEARN.MICROSOFT.COM?x=1#fragment") ==
                  "https://learn.microsoft.com/?x=1",
              "URL normalization lost identity");
        for (const auto* type :
             {"application/json", "text/html; charset=", "text/html; charset=latin-1",
              "text/plain; charset=utf-8; charset=utf-8"}) {
            Fixture fixture;
            fixture.page.content_type = type;
            rejects([&] { fixture.run(); });
            check(fixture.notes.empty(), "Invalid document format reached persistence");
        }
        for (const auto* type : {"text/html", "text/html; charset=\"UTF-8\"", "text/plain",
                                 "text/plain; charset=us-ascii"}) {
            Fixture fixture;
            fixture.page.content_type = type;
            check_separation(fixture, fixture.run());
        }
        {
            Fixture fixture;
            auto request = doc_request();
            request["quote"] = std::string("hidden\0", 7) + request.at("quote").get<std::string>();
            rejects([&] { fixture.run(request); });
            rejects([&] { fixture.run(host_request("service", "invented_state")); });
            check(fixture.calls.empty(), "Invalid quote or service state reached a sensor");
        }
        {
            Fixture fixture;
            fixture.page.complete = false;
            rejects([&] { fixture.run(); });
            fixture.page.complete = true;
            fixture.page.body.push_back('\0');
            rejects([&] { fixture.run(); });
            fixture.page.body = "\xff";
            rejects([&] { fixture.run(); });
            fixture.page.body = std::string(godbrain_truth::kMaxDocumentBytes + 1, 'x');
            rejects([&] { fixture.run(); });
            check(fixture.notes.empty(), "Invalid or incomplete document reached persistence");
        }
        {
            size_t step = 0;
            const auto body = godbrain_truth::read_document(
                [&]() -> std::optional<std::string> {
                    if (step++ == 0) return "first";
                    if (step == 2) return "second";
                    return std::nullopt;
                },
                11);
            check(body == "firstsecond", "Chunked source bytes were changed");
        }
        for (const auto* failure : {"query", "read", "zero", "length", "oversize"}) {
            size_t step = 0;
            rejects([&] {
                godbrain_truth::read_document(
                    [&]() -> std::optional<std::string> {
                        if (step++ == 0) return "already contains the matching quote";
                        if (std::string(failure) == "query" || std::string(failure) == "read") {
                            throw std::runtime_error("fixture WinHTTP failure");
                        }
                        if (std::string(failure) == "zero") return "";
                        if (std::string(failure) == "oversize") {
                            return std::string(godbrain_truth::kMaxDocumentBytes, 'x');
                        }
                        return std::nullopt;
                    },
                    100);
            });
        }
        std::cout << "PASS: caller/assertion separation, immutable sources, exact probes, receipt "
                     "gates, failures and retries\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
