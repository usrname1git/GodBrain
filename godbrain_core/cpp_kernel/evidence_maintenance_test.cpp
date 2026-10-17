#include "evidence_maintenance.h"
#include <iostream>

using json = nlohmann::json;

static void require(bool ok, const char* why) {
    if (!ok) throw std::runtime_error(why);
}

int main() {
    try {
        const std::string url = "https://learn.microsoft.com/en-us/windows/test-fixture";
        const std::string quote = "A specific source-backed observation of Windows servicing.";
        godbrain_truth::Document document{quote, "text/plain; charset=utf-8", true};
        json observation = {{"kind", "document_quote_presence"},
                            {"url", url},
                            {"quote", quote},
                            {"decoding", "validated-utf-8"},
                            {"normalization", "plain-text-ascii-ws-v1"},
                            {"document_keccak256", keccak256(quote)},
                            {"normalized_text_keccak256", keccak256(quote)},
                            {"normalized_offset", 0}};
        json evidence = {{"url", url}, {"body", quote}, {"content_type", document.content_type}};
        auto envelope =
            godbrain_truth::assertion_document(observation, evidence, "test", "doc_fact");
        json job = {
            {"_id", std::string(64, 'a')},
            {"lease_token", std::string(24, 'b')},
            {"source_type", "kernel_truth_observation"},
            {"sector", "test"},
            {"canonical", true},
            {"source_valid", true},
            {"profile", "document"},
            {"raw_source", envelope.at("raw_transcript")},
            {"source_hash", envelope.at("payload").at("provenance").at("source_hash")},
            {"content_hash",
             keccak256(godbrain_truth::collapse_ws(
                 envelope.at("payload").at("claims").at(0).at("content").get<std::string>()))}};
        int fetched = 0, published = 0;
        bool publish_fail = false;
        const auto run = [&] {
            return godbrain_evidence::check(
                job,
                [&](const std::string& requested) {
                    ++fetched;
                    require(requested == url, "fetch subject was not canonical");
                    return document;
                },
                [](const godbrain_truth::Probe&) { return godbrain_truth::Observation{}; },
                [] { return "fixture/123.45"; }, [] { return json::object(); },
                [&](const json& successor) {
                    ++published;
                    require(successor.at("payload").at("trust_tier") == "candidate",
                            "replacement bypassed candidate ingestion");
                    require(successor.at("raw_transcript") != envelope.at("raw_transcript"),
                            "unchanged observation created a replacement");
                    if (publish_fail) throw std::runtime_error("injected persistence failure");
                    return json{{"trust", "verified"},
                                {"promoted", true},
                                {"stable_id", std::string(64, 'c')}};
                });
        };
        require(run().at("outcome") == "fresh" && published == 0, "unchanged document not renewed");
        for (const auto& scenario : {
                 json{{"body", "A specific <b>source-backed</b> observation of Windows servicing."},
                      {"from", "text/html; charset=utf-8"}, {"to", "text/plain; charset=utf-8"},
                      {"removed", true}},
                 json{{"body", "<span title=\"" + quote + "\">Other text.</span>"},
                      {"from", "text/plain; charset=utf-8"}, {"to", "text/html; charset=utf-8"},
                      {"removed", true}},
                 json{{"body", quote}, {"from", "text/plain; charset=utf-8"},
                      {"to", "text/html; charset=utf-8"}, {"removed", false}}}) {
            godbrain_truth::Document original{scenario.at("body"), scenario.at("from"), true};
            const auto text = godbrain_truth::document_text(original);
            auto assertion = observation;
            assertion["document_keccak256"] = keccak256(original.body);
            assertion["normalized_text_keccak256"] = keccak256(text);
            assertion["normalized_offset"] = text.find(quote);
            assertion["normalization"] = original.mime() == "text/plain"
                                             ? "plain-text-ascii-ws-v1"
                                             : "html-tags-as-spaces-ascii-ws-v1";
            const auto saved = godbrain_truth::assertion_document(
                assertion, {{"url", url}, {"body", original.body},
                            {"content_type", original.content_type}}, "test", "doc_fact");
            auto mime_job = job;
            mime_job["raw_source"] = saved.at("raw_transcript");
            mime_job["source_hash"] = saved.at("payload").at("provenance").at("source_hash");
            mime_job["content_hash"] = keccak256(godbrain_truth::collapse_ws(
                saved.at("payload").at("claims").at(0).at("content").get<std::string>()));
            original.content_type = scenario.at("to");
            int replacements = 0;
            const auto changed = godbrain_evidence::check(
                mime_job, [&](const std::string&) { return original; },
                [](const godbrain_truth::Probe&) { return godbrain_truth::Observation{}; },
                [] { return "fixture/123.45"; }, [] { return json::object(); },
                [&](const json& replacement) {
                    ++replacements;
                    const auto bound = json::parse(replacement.at("raw_transcript").get<std::string>());
                    require(bound.at("evidence").at("content_type") == scenario.at("to"),
                            "replacement lost the current Content-Type");
                    return json{{"trust", "verified"}, {"promoted", true},
                                {"stable_id", std::string(64, 'd')}};
                });
            const bool removed = scenario.at("removed");
            require(changed.at("outcome") == "changed" &&
                        changed.at("reason") == (removed ? "quote_removed" : "new_observation_committed") &&
                        replacements == (removed ? 0 : 1),
                    "Content-Type change renewed an old interpretation");
        }
        document.body += " New surrounding text.";
        require(run().at("outcome") == "changed" && published == 1,
                "changed document incorrectly renewed the old version");
        publish_fail = true;
        bool rejected = false;
        try {
            (void)run();
        } catch (const std::runtime_error&) {
            rejected = true;
        }
        require(rejected, "persistence failure returned successful renewal");
        publish_fail = false;
        document.body = "The earlier quote is no longer here.";
        require(run().at("reason") == "quote_removed" && published == 2,
                "removed quote was crowned or retried as unchanged");
        document.complete = false;
        rejected = false;
        try {
            (void)run();
        } catch (const std::runtime_error&) {
            rejected = true;
        }
        require(rejected, "incomplete fetch returned freshness");
        job["canonical"] = false;
        const int before = fetched;
        require(run().at("outcome") == "unavailable" && fetched == before,
                "noncanonical origin fetched a remote source");
        job["canonical"] = true;
        job["source_hash"] = std::string(64, '0');
        rejected = false;
        try {
            (void)run();
        } catch (const std::runtime_error&) {
            rejected = true;
        }
        require(rejected, "source hash mismatch was accepted");
        job["source_hash"] = envelope.at("payload").at("provenance").at("source_hash");
        job["source_type"] = "session_transcript";
        job["profile"] = "unsupported";
        require(run().at("outcome") == "unsupported",
                "legacy interpretation was automatically crowned");
        const json inventory = {{"edition_id", "fixture"},
                                {"current_build", "123"},
                                {"ubr", 45},
                                {"os_pin", "fixture/123.45"},
                                {"computer_name", "test-host"},
                                {"total_physical_ram_gb", 32},
                                {"logical_processors", 8},
                                {"volumes", json::array()}};
        const auto saved_inventory = godbrain_truth::trim(godbrain_host::inventory_text(inventory));
        job["raw_source"] = saved_inventory;
        job["source_hash"] = keccak256(saved_inventory);
        job["profile"] = "host";
        const auto inventory_result = godbrain_evidence::check(
            job, [](const std::string&) { return godbrain_truth::Document{}; },
            [](const godbrain_truth::Probe&) { return godbrain_truth::Observation{}; },
            [] { return "fixture/123.45"; }, [&] { return inventory; },
            [](const json&) -> json {
                throw std::runtime_error("inventory must not publish caller prose");
            });
        require(inventory_result.at("outcome") == "fresh" &&
                    inventory_result.at("observed_hash") == keccak256(saved_inventory),
                "saved inventory trimming prevented exact renewal");
        for (const std::string kind :
             {"registry_value", "registry_key", "service", "file", "appx"}) {
            godbrain_truth::Probe subject{
                kind, kind == "file" ? "C:\\Temp\\fixture.txt" : "SOFTWARE\\Fixture", "Fixture",
                ""};
            subject = godbrain_truth::probe_request(subject.subject());
            const std::string value = kind == "service"          ? "running"
                                      : kind == "registry_value" ? "Exact  Unicode \xC3\x85"
                                                                 : "present";
            godbrain_truth::Observation read{true, value, {{"synthetic", true}}};
            const json original = {{"kind", "host_probe_observation"},
                                   {"probe", subject.subject()},
                                   {"observed", value},
                                   {"details", read.details},
                                   {"os_pin", "fixture/123.45"}};
            envelope = godbrain_truth::assertion_document(original, original, "test", "host_fact");
            job["source_type"] = "kernel_truth_observation";
            job["raw_source"] = envelope.at("raw_transcript");
            job["source_hash"] = envelope.at("payload").at("provenance").at("source_hash");
            job["content_hash"] = keccak256(godbrain_truth::collapse_ws(
                envelope.at("payload").at("claims").at(0).at("content").get<std::string>()));
            int writes = 0, pins = 0;
            bool drift = false;
            const auto host = [&] {
                pins = 0;
                return godbrain_evidence::check(
                    job,
                    [](const std::string&) -> godbrain_truth::Document {
                        throw std::runtime_error("host probe fetched a document");
                    },
                    [&](const godbrain_truth::Probe& requested) {
                        require(requested.subject() == subject.subject(), "host subject changed");
                        return read;
                    },
                    [&] { return ++pins > 1 && drift ? "fixture/123.46" : "fixture/123.45"; },
                    [] { return json::object(); },
                    [&](const json& replacement) {
                        ++writes;
                        require(replacement.at("raw_transcript") != envelope.at("raw_transcript"),
                                "host replacement reused old evidence");
                        return json{{"trust", "verified"},
                                    {"promoted", true},
                                    {"stable_id", std::string(64, 'd')}};
                    });
            };
            require(host().at("outcome") == "fresh" && writes == 0, "exact host probe not renewed");
            read.complete = false;
            require(host().at("reason") == "host_probe_incomplete" && writes == 0,
                    "failed host read renewed evidence");
            read.complete = true;
            drift = true;
            require(host().at("reason") == "host_changed_during_probe" && writes == 0,
                    "OS drift during a host read was accepted");
            drift = false;
            if (kind == "service")
                read.value = "stopped";
            else if (kind == "registry_value")
                read.value = "New  Unicode \xC3\x85";
            else
                read.details["synthetic"] = false;
            require(host().at("outcome") == "changed" && writes == 1,
                    "host change renewed the old snapshot");
            read.value = kind == "registry_value" ? read.value : "unknown";
            read.details = json::array();
            require(host().at("reason") == "host_probe_invalid" && writes == 1,
                    "invalid host response published an observation");
        }
        std::cout
            << "evidence maintenance: exact renewal, replacement, missing quotes, source binding, "
               "incomplete reads and persistence failure passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
