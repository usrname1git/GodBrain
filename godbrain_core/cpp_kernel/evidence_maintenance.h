#pragma once

#include "truth_assertion.h"

namespace godbrain_evidence {
using json = nlohmann::json;

inline json result(const json& job, const std::string& outcome, const std::string& reason,
                   const std::string& observed_hash = "", const std::string& successor = "") {
    return {{"command", "evidence"},
            {"action", "complete"},
            {"id", job.at("_id")},
            {"lease_token", job.at("lease_token")},
            {"outcome", outcome},
            {"reason", reason},
            {"observed_hash", observed_hash},
            {"successor", successor}};
}

template <class Fetch, class Probe, class Pin, class Inventory, class Publish>
json check(const json& job, Fetch fetch, Probe probe, Pin pin, Inventory inventory,
           Publish publish) {
    using namespace godbrain_truth;
    if (!job.at("canonical").get<bool>() || !job.at("source_valid").get<bool>())
        return result(job, "unavailable", "origin_or_source_unavailable");
    const auto raw = job.at("raw_source").get<std::string>();
    if (keccak256(raw) != job.at("source_hash"))
        throw std::runtime_error("maintenance source hash mismatch");
    if (job.value("source_type", "") == "kernel_truth_observation") {
        const auto bound = json::parse(raw);
        if (bound.at("profile") != kProfile || bound.at("checker_version") != kVersion ||
            bound.at("sector") != job.at("sector"))
            throw std::runtime_error("unsupported assertion checker or sector");
        const auto& original = bound.at("observation");
        const auto& evidence = bound.at("evidence");
        const auto kind = original.at("kind").get<std::string>();
        const std::string claim_class = kind == "host_probe_observation" ? "host_fact" : "doc_fact";
        const auto original_document = assertion_document(
            original, evidence, job.at("sector").get<std::string>(), claim_class);
        const auto original_content =
            original_document.at("payload").at("claims").at(0).at("content").get<std::string>();
        if (original_document.at("raw_transcript") != raw ||
            keccak256(collapse_ws(original_content)) != job.at("content_hash"))
            throw std::runtime_error("maintenance assertion does not match its origin");
        json observed, current_evidence;
        if (kind == "document_quote_presence") {
            const auto url = document_url(original.at("url").get<std::string>());
            const auto quote = original.at("quote").get<std::string>();
            bounded(quote, 2048, "bound quote");
            if (quote.size() < 24 || evidence.at("url") != url)
                throw std::runtime_error("invalid bound document subject");
            const Document before{evidence.at("body").get<std::string>(),
                                  evidence.at("content_type").get<std::string>(), true};
            const auto before_text = document_text(before);
            if (keccak256(before.body) != original.at("document_keccak256") ||
                keccak256(before_text) != original.at("normalized_text_keccak256") ||
                before_text.find(quote) == std::string::npos)
                throw std::runtime_error("invalid original document evidence");
            const auto document = fetch(url);
            const auto text = document_text(document);
            if (document.body == before.body && document.content_type == before.content_type)
                return result(job, "fresh", "exact_source_unchanged", keccak256(raw));
            const auto offset = text.find(quote);
            if (offset == std::string::npos)
                return result(job, "changed", "quote_removed", keccak256(document.body));
            observed = original;
            observed["document_keccak256"] = keccak256(document.body);
            observed["normalized_text_keccak256"] = keccak256(text);
            observed["normalized_offset"] = offset;
            observed["normalization"] = document.mime() == "text/plain"
                                            ? "plain-text-ascii-ws-v1"
                                            : "html-tags-as-spaces-ascii-ws-v1";
            current_evidence = {
                {"url", url}, {"body", document.body}, {"content_type", document.content_type}};
        } else if (kind == "host_probe_observation") {
            const auto subject = probe_request(original.at("probe"));
            const auto current_pin = checked_pin(pin());
            const auto read = probe(subject);
            if (!read.complete) return result(job, "unavailable", "host_probe_incomplete");
            bounded(read.value, 4096, "observed value", false);
            if (!read.details.is_object() || read.details.dump().size() > 8192 ||
                (subject.kind == "service" && !service_state(read.value)) ||
                (subject.kind != "service" && subject.kind != "registry_value" &&
                 read.value != "present"))
                return result(job, "unavailable", "host_probe_invalid");
            if (checked_pin(pin()) != current_pin)
                return result(job, "unavailable", "host_changed_during_probe");
            observed = {{"kind", kind},
                        {"probe", subject.subject()},
                        {"observed", read.value},
                        {"details", read.details},
                        {"os_pin", current_pin}};
            if (observed == original)
                return result(job, "fresh", "exact_probe_unchanged", keccak256(raw));
            current_evidence = observed;
        } else {
            return result(job, "unsupported", "unknown_observation_kind");
        }
        const auto document = assertion_document(observed, current_evidence,
                                                 job.at("sector").get<std::string>(), claim_class);
        const auto successor = publish(document);
        if (successor.value("trust", "") != "verified" || !successor.value("promoted", false))
            throw std::runtime_error("replacement observation was not acknowledged");
        return result(job, "changed", "new_observation_committed",
                      keccak256(document.at("raw_transcript").get<std::string>()),
                      successor.at("stable_id").get<std::string>());
    }
    if (raw.rfind("Windows host inventory\nclaim_class=host_fact\n", 0) == 0) {
        const auto current = trim(godbrain_host::inventory_text(inventory()));
        return result(job, current == raw ? "fresh" : "changed",
                      current == raw ? "exact_inventory_unchanged" : "inventory_changed",
                      keccak256(current));
    }
    if (job.value("profile", "") == "document") {
        const auto url = document_url(job.at("source_url").get<std::string>());
        const auto document = fetch(url);
        (void)document_text(document);
        return result(job, document.body == raw ? "fresh" : "changed",
                      document.body == raw ? "exact_legacy_source_unchanged"
                                           : "legacy_source_changed",
                      keccak256(document.body));
    }
    return result(job, "unsupported", "no_reproducible_source");
}
} // namespace godbrain_evidence
