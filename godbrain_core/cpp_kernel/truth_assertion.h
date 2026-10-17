#pragma once

#include "host_observation.h"
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4244)
#endif
#include "../cpp_tools/keccak256.hpp"
#if defined(_MSC_VER)
#pragma warning(pop)
#endif

#include <optional>
#include <string>

namespace godbrain_truth {
using json = nlohmann::json;

constexpr const char* kProfile = "truth-observation-v1";
constexpr const char* kVersion = "1.0.0";
constexpr size_t kMaxDocumentBytes = 1500 * 1024;
constexpr size_t kMaxContentBytes = 32 * 1024;
constexpr size_t kMaxWireBytes = 15 * 1024 * 1024;

inline std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n\f\v");
    if (first == std::string::npos) return "";
    return value.substr(first, value.find_last_not_of(" \t\r\n\f\v") - first + 1);
}

inline std::string lower(std::string value) {
    for (char& ch : value) {
        if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch + ('a' - 'A'));
    }
    return value;
}

inline void bounded(const std::string& value, size_t limit, const char* field,
                    bool required = true) {
    if ((required && value.empty()) || value.size() > limit ||
        value.find('\0') != std::string::npos) {
        throw std::runtime_error(std::string(field) + " is empty, oversized, or invalid");
    }
}

inline std::string collapse_ws(const std::string& raw) {
    std::string out;
    bool space = false;
    for (unsigned char ch : raw) {
        if (ch <= 32) {
            space = true;
            continue;
        }
        if (space && !out.empty()) out.push_back(' ');
        space = false;
        out.push_back(static_cast<char>(ch));
    }
    return out;
}

inline std::string document_url(std::string url) {
    bounded(url, 2048, "documentation URL");
    for (unsigned char ch : url) {
        if (ch <= 32 || ch >= 127 || ch == '\\') {
            throw std::runtime_error(
                "documentation URL must be ASCII without controls or backslashes");
        }
    }
    url = url.substr(0, url.find('#'));
    if (lower(url.substr(0, 8)) != "https://") {
        throw std::runtime_error("documentation URL must be HTTPS");
    }
    const size_t end = url.find_first_of("/?", 8);
    const std::string host = lower(url.substr(8, end == std::string::npos ? end : end - 8));
    if (host != "learn.microsoft.com" && host != "support.microsoft.com") {
        throw std::runtime_error("documentation URL must use learn.microsoft.com or "
                                 "support.microsoft.com on default HTTPS");
    }
    std::string suffix = end == std::string::npos ? "/" : url.substr(end);
    if (suffix.front() == '?') suffix.insert(suffix.begin(), '/');
    return "https://" + host + suffix;
}

inline void document_body(const std::string& body) {
    bounded(body, kMaxDocumentBytes, "complete document body");
}

template <class NextChunk>
std::string read_document(NextChunk next, std::optional<size_t> expected = std::nullopt) {
    if (expected && *expected > kMaxDocumentBytes) {
        throw std::runtime_error("document Content-Length exceeds limit");
    }
    std::string body;
    while (const auto chunk = next()) {
        if (chunk->empty()) throw std::runtime_error("document read ended before EOF");
        if (chunk->size() > kMaxDocumentBytes || body.size() > kMaxDocumentBytes - chunk->size()) {
            throw std::runtime_error("document exceeds limit");
        }
        body += *chunk;
    }
    if (expected && body.size() != *expected) {
        throw std::runtime_error("document body does not match Content-Length");
    }
    document_body(body);
    return body;
}

struct Document {
    std::string body;
    std::string content_type;
    bool complete = false;

    std::string mime() const { return lower(trim(content_type.substr(0, content_type.find(';')))); }
};

inline std::string document_text(const Document& document) {
    document_body(document.body);
    if (!document.complete) throw std::runtime_error("documentation fetch was incomplete");
    const std::string type = lower(document.content_type);
    const auto separator = type.find(';');
    const std::string mime = document.mime();
    if (mime != "text/html" && mime != "application/xhtml+xml" && mime != "text/plain") {
        throw std::runtime_error("documentation response is not HTML or plain text");
    }
    std::string charset;
    bool charset_seen = false;
    size_t start = separator;
    while (start != std::string::npos) {
        const size_t end = type.find(';', start + 1);
        const std::string parameter =
            trim(type.substr(start + 1, end == std::string::npos ? end : end - start - 1));
        const auto equals = parameter.find('=');
        if (trim(parameter.substr(0, equals)) == "charset" && equals != std::string::npos) {
            if (charset_seen) throw std::runtime_error("duplicate documentation charset");
            charset_seen = true;
            charset = trim(parameter.substr(equals + 1));
            if (charset.size() >= 2 && charset.front() == '"' && charset.back() == '"') {
                charset = charset.substr(1, charset.size() - 2);
            }
        }
        start = end;
    }
    if (charset_seen && charset != "utf-8" && charset != "us-ascii") {
        throw std::runtime_error("unsupported documentation charset");
    }
    if (charset == "us-ascii") {
        for (unsigned char ch : document.body) {
            if (ch >= 128) throw std::runtime_error("non-ASCII documentation body");
        }
    }
    // Learn can omit charset. Validate the bytes as UTF-8 rather than guessing a legacy encoding.
    (void)json(document.body).dump();
    if (mime == "text/plain") return collapse_ws(document.body);
    std::string text;
    bool tag = false;
    for (char ch : document.body) {
        if (ch == '<') {
            tag = true;
            text.push_back(' ');
        } else if (ch == '>')
            tag = false;
        else if (!tag)
            text.push_back(ch);
    }
    return collapse_ws(text);
}

struct Probe {
    std::string kind;
    std::string path;
    std::string name;
    std::string expect;

    json subject() const { return {{"kind", kind}, {"path", path}, {"name", name}}; }
};

inline bool service_state(const std::string& state) {
    return state == "running" || state == "stopped" || state == "start_pending" ||
           state == "stop_pending" || state == "pause_pending" || state == "continue_pending" ||
           state == "paused";
}

inline Probe probe_request(const json& raw) {
    Probe probe{lower(trim(raw.value("kind", ""))), trim(raw.value("path", "")),
                trim(raw.value("name", "")), raw.value("expect", "")};
    bounded(probe.expect, 2048, "probe.expect", false);
    if (probe.kind == "registry_key" || probe.kind == "registry_value") {
        bounded(probe.path, 256, "registry path");
        if (probe.path.find("..") != std::string::npos ||
            probe.path.find_first_of("/*?\r\n\t") != std::string::npos) {
            throw std::runtime_error("invalid HKLM registry path");
        }
        if (probe.kind == "registry_value")
            bounded(probe.name, 128, "registry value name");
        else
            probe.name.clear();
    } else if (probe.kind == "appx" || probe.kind == "service") {
        probe.name = probe.name.empty() ? probe.path : probe.name;
        bounded(probe.name, probe.kind == "service" ? 64 : 128, "probe name");
        probe.path.clear();
    } else if (probe.kind == "file") {
        bounded(probe.path, 2048, "file path");
        probe.name.clear();
    } else {
        throw std::runtime_error(
            "host_fact probe.kind must be registry_key, registry_value, appx, service, or file");
    }
    if (probe.kind == "service") {
        probe.expect = lower(trim(probe.expect));
        if (!probe.expect.empty() && !service_state(probe.expect)) {
            throw std::runtime_error("service expect is not a supported SCM state");
        }
    } else if (probe.kind != "registry_value") {
        probe.expect = lower(trim(probe.expect));
        if (!probe.expect.empty() && probe.expect != "present") {
            throw std::runtime_error("presence probes only support expect=present");
        }
    }
    return probe;
}

struct Observation {
    bool complete = false;
    std::string value;
    json details = json::object();
};

inline std::string checked_pin(const std::string& pin) {
    const auto slash = pin.find('/');
    const auto dot = pin.find('.', slash == std::string::npos ? 0 : slash);
    if (slash == std::string::npos || dot == std::string::npos) {
        throw std::runtime_error("host assertion has no valid OS pin");
    }
    std::uint32_t ubr = 0;
    const auto parsed = std::from_chars(pin.data() + dot + 1, pin.data() + pin.size(), ubr);
    if (parsed.ec != std::errc{} || parsed.ptr != pin.data() + pin.size() ||
        godbrain_host::make_windows_pin(pin.substr(0, slash),
                                        pin.substr(slash + 1, dot - slash - 1), ubr) != pin) {
        throw std::runtime_error("host assertion OS pin is malformed");
    }
    return pin;
}

inline json assertion_document(const json& observation, const json& evidence,
                               const std::string& sector, const std::string& claim_class) {
    const std::string raw = json{
        {"profile", kProfile},
        {"checker_version", kVersion},
        {"observation", observation},
        {"evidence", evidence}}.dump();
    const std::string hash = keccak256(raw);
    std::string content =
        "Machine-checked observation only; not proof of caller interpretation.\nclaim_class=" +
        claim_class + "\nassertion_profile=" + kProfile + "\nchecker_version=" + kVersion + "\n";
    if (claim_class == "host_fact") {
        content += "os_pin=" + observation.at("os_pin").get<std::string>() + "\n";
    }
    content += "observation=" + observation.dump() +
               "\nevidence_keccak256=" + keccak256(evidence.dump()) + "\n";
    bounded(content, kMaxContentBytes, "assertion content");
    json document = {
        {"extractor_id", "Kernel-Truth-CPP"},
        {"extractor_version", kVersion},
        {"schema_version", "1.0"},
        {"degraded", false},
        {"raw_transcript", raw},
        {"payload",
         {{"trust_tier", "candidate"},
          {"provenance",
           {{"source_id", "truth:" + hash},
            {"source_type", "kernel_truth_observation"},
            {"source_hash", hash},
            {"language", "mixed"},
            {"prompt_hash", "N/A"},
            {"model_id", "none"},
            {"model_hash", "N/A"},
            {"llm_temperature", 0.0}}},
          {"claims", json::array({{{"claim_id", "claim:" + hash},
                                   {"type", sector},
                                   {"content", content},
                                   {"confidence", 1.0},
                                   {"evidence_spans",
                                    json::array({"[0:" + std::to_string(raw.size()) + "]"})}}})},
          {"core_concepts", json::array()},
          {"opsec_candidates", json::array()}}}};
    if (document.dump().size() > kMaxWireBytes)
        throw std::runtime_error("assertion exceeds ingestion limit");
    return document;
}

template <class Fetch, class ReadProbe, class Pin, class Save, class Ingest, class Judge>
json promote(const json& payload, Fetch fetch, ReadProbe read_probe, Pin read_pin, Save save,
             Ingest ingest, Judge judge) {
    const std::string claim_class = lower(trim(payload.value("class", "")));
    const std::string text = trim(payload.value("text", payload.value("content", "")));
    const std::string sector = trim(payload.value("sector", "windows-sre"));
    bounded(text, kMaxContentBytes, "claim text");
    bounded(sector, 128, "claim sector");
    if (claim_class != "host_fact" && claim_class != "doc_fact" && claim_class != "playbook") {
        throw std::runtime_error("class must be host_fact, doc_fact, or playbook");
    }
    json fields = {{"class", claim_class}};
    json observation;
    json evidence;
    bool matched = false;
    if (claim_class == "doc_fact") {
        const auto url = document_url(trim(payload.value("learn_url", payload.value("url", ""))));
        const auto requested_quote = payload.value("quote", "");
        bounded(requested_quote, 2048, "documentation quote");
        const auto quote = collapse_ws(requested_quote);
        bounded(quote, 2048, "documentation quote");
        if (quote.size() < 24)
            throw std::runtime_error("documentation quote needs at least 24 bytes");
        const Document document = fetch(url);
        const auto normalized = document_text(document);
        const auto offset = normalized.find(quote);
        matched = offset != std::string::npos;
        fields["learn_url"] = url;
        fields["quote_matched"] = matched;
        fields["quote"] = quote;
        observation = {{"kind", "document_quote_presence"},
                       {"url", url},
                       {"quote", quote},
                       {"decoding", "validated-utf-8"},
                       {"normalization", document.mime() == "text/plain"
                                             ? "plain-text-ascii-ws-v1"
                                             : "html-tags-as-spaces-ascii-ws-v1"},
                       {"document_keccak256", keccak256(document.body)},
                       {"normalized_text_keccak256", keccak256(normalized)}};
        if (matched) observation["normalized_offset"] = offset;
        evidence = {{"url", url}, {"body", document.body}, {"content_type", document.content_type}};
    } else if (claim_class == "host_fact") {
        const auto probe = probe_request(payload.value("probe", json::object()));
        const auto pin = checked_pin(read_pin());
        const Observation read = read_probe(probe);
        if (!read.complete)
            throw std::runtime_error("host probe could not establish an observation");
        bounded(read.value, 4096, "observed value", false);
        if (!read.details.is_object() || read.details.dump().size() > 8192) {
            throw std::runtime_error("host probe details are invalid");
        }
        if (probe.kind != "registry_value" && probe.kind != "service" && read.value != "present") {
            throw std::runtime_error("presence probe did not establish presence");
        }
        if (probe.kind == "service" && !service_state(read.value)) {
            throw std::runtime_error("host probe did not establish an exact service state");
        }
        matched = probe.expect.empty() || read.value == probe.expect;
        fields["probe_ok"] = matched;
        fields["probe"] = probe.subject();
        fields["probe"]["expect"] = probe.expect;
        fields["observed"] = read.value;
        fields["os_pin"] = pin;
        observation = {{"kind", "host_probe_observation"},
                       {"probe", probe.subject()},
                       {"observed", read.value},
                       {"details", read.details},
                       {"os_pin", pin}};
        evidence = observation;
    }
    const std::string check = claim_class == "playbook" ? "not_applicable"
                              : matched                 ? "matched"
                                                        : "not_matched";
    std::string note = text + "\nclaim_class=" + claim_class + "\nauto_verify=never\n";
    if (claim_class == "host_fact")
        note += "os_pin=" + fields.at("os_pin").get<std::string>() + "\n";
    note += "check_status=" + check + "\ncheck=" + fields.dump() + "\n";
    bounded(note, kMaxContentBytes, "candidate claim");
    json stored = save(json{{"content", note}, {"sector", sector}});
    stored.update(fields);
    stored["trust"] = "candidate";
    stored["promoted"] = false;
    stored["check_status"] = check;
    if (!matched) return stored;

    const auto document = assertion_document(observation, evidence, sector, claim_class);
    json assertion = ingest(document);
    const auto id = assertion.value("stable_id", "");
    const auto status = assertion.value("store_status", "");
    if (assertion.value("status", "") != "success" ||
        (status != "committed" && status != "idempotent_noop") || id.size() != 64 ||
        id.find_first_not_of("0123456789abcdef") != std::string::npos ||
        assertion.value("source_hash", "") !=
            document.at("payload").at("provenance").at("source_hash") ||
        assertion.value("run_id", "").empty() || assertion.value("record_id", "").empty()) {
        throw std::runtime_error("assertion ingestion did not acknowledge its bound source");
    }
    const auto judgment =
        judge(json{{"id", id},
                   {"status", "verified"},
                   {"reasoning", std::string(kProfile) + "/" + kVersion +
                                     " checked observation only; source_keccak256=" +
                                     assertion.at("source_hash").get<std::string>()}});
    const auto judgment_status = judgment.value("status", "");
    if ((judgment_status != "judged" && judgment_status != "idempotent_noop") ||
        judgment.value("stable_id", "") != id || judgment.value("to", "") != "verified") {
        throw std::runtime_error("assertion judgment did not acknowledge this observation");
    }
    assertion["judgment"] = judgment;
    assertion["trust"] = "verified";
    assertion["promoted"] = true;
    assertion["profile"] = kProfile;
    assertion["checker_version"] = kVersion;
    assertion["content"] = document.at("payload").at("claims").at(0).at("content");
    stored["assertion"] = std::move(assertion);
    return stored;
}
} // namespace godbrain_truth
