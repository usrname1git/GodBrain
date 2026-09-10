#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/json.hpp"
#include "godbrain/memory_store/state_machine.hpp"
#include "godbrain/memory_store/embedding.hpp"

#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4244)
#endif
#include "keccak256.hpp"
#if defined(_MSC_VER)
#pragma warning(pop)
#endif

#include <cctype>
#include <cstdio>
#include <iomanip>
#include <sstream>
#include <utility>

namespace godbrain::memory {
namespace {

const char* kClaimKeys[] = {
    "claim_id",
    "type",
    "content",
    "confidence",
    "evidence_spans",
    nullptr,
};

const char* kSkillExtractedKeys[] = {
    "name",
    "content",
    "task_kind",
    "framework",
    "verification_profile",
    "required_inputs",
    "procedure",
    "confidence",
    "evidence_spans",
    nullptr,
};

std::string collapse_ws(const std::string& s) {
    std::string o;
    bool in = false;
    for (unsigned char c : s) {
        if (std::isspace(c) != 0) {
            in = false;
            continue;
        }
        if (!o.empty() && !in) o.push_back(' ');
        o.push_back(static_cast<char>(c));
        in = true;
    }
    return o;
}

const char* kIngestKeys[] = {
    "extractor_id",
    "extractor_version",
    "schema_version",
    "degraded",
    "payload",
    "raw_transcript",
    "document",
    "chunks",
    nullptr,
};

const char* kPayloadKeys[] = {
    "trust_tier",
    "provenance",
    "claims",
    "core_concepts",
    "opsec_candidates",
    "skills_extracted",
    nullptr,
};

const char* kProvKeys[] = {
    "source_id",
    "source_type",
    "source_hash",
    "language",
    "prompt_hash",
    "model_id",
    "model_hash",
    "llm_temperature",
    nullptr,
};

const char* kJudgmentKeys[] = {
    "command",
    "id",
    "status",
    "reasoning",
    nullptr,
};

const char* kStalePinsKeys[] = {
    "command",
    "sector",
    "pin",
    "reasoning",
    nullptr,
};

const char* kRecordSkillKeys[] = {
    "command",
    "skill_name",
    "origin_node_id",
    "fixture_id",
    "suite_id",
    "verification_profile",
    "verification_version",
    "environment_hash",
    "result",
    "checks",
    "artifact_hash",
    "log_excerpt",
    "reasoning",
    nullptr,
};

const char* kPromoteSkillKeys[] = {
    "command",
    "name",
    "content",
    "origin_node_id",
    "origin_version",
    "origin_hash",
    "schema_version",
    "verification_profile",
    "reasoning",
    nullptr,
};

const char* kQuerySkillsKeys[] = {
    "command",
    "query",
    "limit",
    nullptr,
};

std::string trim_copy(std::string s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front())) != 0) s.erase(s.begin());
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back())) != 0) s.pop_back();
    return s;
}

bool require_string_field(const Json& obj, const char* key, std::string* out, std::string* err) {
    if (!json_has(obj, key)) {
        if (err) *err = std::string("missing ") + key;
        return false;
    }
    if (!json_string(obj, key, out)) {
        if (err) *err = std::string(key) + " must be a string";
        return false;
    }
    return true;
}

}  // namespace

std::string json_escape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':
                o += "\\\"";
                break;
            case '\\':
                o += "\\\\";
                break;
            case '\n':
                o += "\\n";
                break;
            case '\r':
                o += "\\r";
                break;
            case '\t':
                o += "\\t";
                break;
            default:
                if (c < 0x20) {
                    std::ostringstream h;
                    h << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                    o += h.str();
                } else {
                    o.push_back(static_cast<char>(c));
                }
        }
    }
    return o;
}

std::string keccak256_hex(const std::string& bytes) {
    uint8_t hash[32];
    Keccak256::getHash(
        reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), hash);
    std::ostringstream o;
    o << std::hex << std::setfill('0');
    for (unsigned char b : hash) {
        o << std::setw(2) << static_cast<int>(b);
    }
    return o.str();
}

std::string skill_procedure_text(const SkillExtracted& skill) {
    if (!skill.content.empty()) return skill.content;
    std::string o;
    for (size_t i = 0; i < skill.procedure.size(); ++i) {
        if (i) o.push_back('\n');
        o += skill.procedure[i];
    }
    return o;
}

std::string skill_stable_id(const std::string& name, const std::string& content) {
    return keccak256_hex(std::string("skill") + '\0' + name + '\0' + content);
}

bool validate_skill_extracted(const SkillExtracted& skill, std::string* err) {
    if (!safe_extractor_id(skill.name)) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    std::string content = skill_procedure_text(skill);
    if (content.empty() || content.size() > 8192) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    if (skill.procedure.size() > 32) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    for (const std::string& step : skill.procedure) {
        if (step.size() > 512) {
            if (err) *err = "skills_extracted entry is invalid";
            return false;
        }
    }
    if (skill.required_inputs.size() > 16) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    if (!skill.task_kind.empty()) {
        if (skill.task_kind.size() > 64) {
            if (err) *err = "skills_extracted entry is invalid";
            return false;
        }
        std::string id = skill.task_kind;
        for (char& c : id) {
            if (c == ' ') c = '-';
        }
        if (!safe_extractor_id(id)) {
            if (err) *err = "skills_extracted entry is invalid";
            return false;
        }
    }
    if (!skill.framework.empty() && (skill.framework.size() > 64 || !safe_extractor_id(skill.framework))) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    if (skill.confidence < 0 || skill.confidence > 1) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    return true;
}

std::string error_envelope_json(const std::string& error, const std::string& details) {
    std::ostringstream o;
    o << "{\"error\":\"" << json_escape(error) << "\"";
    if (!details.empty()) {
        o << ",\"details\":\"" << json_escape(details) << "\"";
    }
    o << "}\n";
    return o.str();
}

bool read_capped(const std::string& raw, std::string* out, std::string* err) {
    if (raw.size() > kMaxInputBytes) {
        if (err) *err = "input payload exceeds maximum size of 15 MiB";
        return false;
    }
    if (raw.empty()) {
        if (err) *err = "no JSON payload received on stdin";
        return false;
    }
    *out = raw;
    return true;
}

std::string normalize_ws(const std::string& s) { return collapse_ws(s); }

std::string claim_stable_id(const Claim& claim) {
    return keccak256_hex(std::string("claim") + '\0' + claim.type + '\0' + claim.content);
}

std::string kind_stable_id(const std::string& prefix, const std::string& content) {
    return keccak256_hex(prefix + content);
}

bool parse_evidence_span(const std::string& span, int* start, int* end) {
    if (span.size() < 5 || span.front() != '[' || span.back() != ']') return false;
    const std::string inner = span.substr(1, span.size() - 2);
    const auto colon = inner.find(':');
    if (colon == std::string::npos) return false;
    auto digits = [](const std::string& t, int* v) {
        if (t.empty()) return false;
        for (char c : t) {
            if (c < '0' || c > '9') return false;
        }
        try {
            *v = std::stoi(t);
        } catch (...) {
            return false;
        }
        return true;
    };
    if (!digits(inner.substr(0, colon), start) || !digits(inner.substr(colon + 1), end)) {
        return false;
    }
    return *end > *start;
}

bool validate_evidence_spans(
    const std::vector<std::string>& spans, const std::string& source, std::string* err) {
    for (const std::string& raw : spans) {
        std::string span = raw;
        while (!span.empty() && std::isspace(static_cast<unsigned char>(span.front())) != 0) {
            span.erase(span.begin());
        }
        while (!span.empty() && std::isspace(static_cast<unsigned char>(span.back())) != 0) {
            span.pop_back();
        }
        if (span.empty()) {
            if (err) *err = "evidence_spans must be [start:end] byte ranges on the source";
            return false;
        }
        int start = 0, end = 0;
        if (!parse_evidence_span(span, &start, &end) || end > static_cast<int>(source.size())) {
            if (err) *err = "evidence_spans must be [start:end] byte ranges on the source";
            return false;
        }
    }
    return true;
}

bool safe_extractor_id(const std::string& id) {
    if (id.empty() || id.size() > 64) return false;
    unsigned char first = static_cast<unsigned char>(id[0]);
    if (std::isalnum(first) == 0) return false;
    for (std::size_t n = 1; n < id.size(); ++n) {
        unsigned char c = static_cast<unsigned char>(id[n]);
        if (std::isalnum(c) == 0 && c != '.' && c != '_' && c != '-') return false;
    }
    return true;
}

bool allowed_status_transition(const std::string& from, const std::string& to) {
    if (from == to) return true;
    if (to == kStatusVerified) return from == kStatusCandidate || from == kStatusStale;
    if (to == kStatusRejected) {
        return from == kStatusCandidate || from == kStatusVerified || from == kStatusStale;
    }
    if (to == kStatusStale) return from == kStatusCandidate || from == kStatusVerified;
    if (to == kStatusCandidate) return from == kStatusStale;
    return false;
}

bool validate_status_judgment(const StatusJudgment& j, std::string* err) {
    if (j.command != kJudgmentCommand) {
        if (err) *err = "judgment command must be set_status";
        return false;
    }
    if (j.id.empty() || j.id.size() > 128) {
        if (err) *err = "judgment id required";
        return false;
    }
    if (j.status != kStatusVerified && j.status != kStatusRejected && j.status != kStatusStale) {
        if (err) *err = "invalid judgment status";
        return false;
    }
    std::string reason = collapse_ws(j.reasoning);
    if (static_cast<int>(reason.size()) < kMinJudgmentReason ||
        static_cast<int>(j.reasoning.size()) > kMaxJudgmentReason) {
        if (err) *err = "judgment reasoning required";
        return false;
    }
    return true;
}

bool valid_os_pin(const std::string& pin) {
    if (pin.empty() || pin.size() > 80) return false;
    for (unsigned char ch : pin) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' ||
            ch == '/' || ch == '_' || ch == '-') {
            continue;
        }
        return false;
    }
    return true;
}

bool has_mismatched_os_pin(const std::string& content, const std::string& pin) {
    if (content.find("os_pin=") == std::string::npos) return false;
    return content.find(std::string("os_pin=") + pin) == std::string::npos;
}

bool validate_stale_pins(const StalePinsRequest& r, std::string* err) {
    if (r.command != kStalePinsCommand) {
        if (err) *err = "stale_pins requires windows-sre sector and a pin";
        return false;
    }
    std::string sector = r.sector;
    while (!sector.empty() && std::isspace(static_cast<unsigned char>(sector.front())) != 0) {
        sector.erase(sector.begin());
    }
    while (!sector.empty() && std::isspace(static_cast<unsigned char>(sector.back())) != 0) sector.pop_back();
    std::string pin = r.pin;
    while (!pin.empty() && std::isspace(static_cast<unsigned char>(pin.front())) != 0) pin.erase(pin.begin());
    while (!pin.empty() && std::isspace(static_cast<unsigned char>(pin.back())) != 0) pin.pop_back();
    std::string reason = collapse_ws(r.reasoning);
    if (sector != "windows-sre" || !valid_os_pin(pin) || static_cast<int>(reason.size()) < kMinJudgmentReason) {
        if (err) *err = "stale_pins requires windows-sre sector and a pin";
        return false;
    }
    if (static_cast<int>(r.reasoning.size()) > kMaxJudgmentReason) {
        if (err) *err = "stale_pins requires windows-sre sector and a pin";
        return false;
    }
    return true;
}

bool skill_profile_allowed(const std::string& profile) {
    return profile == "local-edit-apply-v1" || profile == "galaxy-html-v1" || profile == "frontend-spa-v1" ||
           profile == "frontend-nextjs-v1" || profile == "desk-v1";
}

bool skill_profile_apply_only(const std::string& profile) { return profile == "local-edit-apply-v1"; }

bool skill_profile_suite_required(const std::string& profile) {
    return profile == "galaxy-html-v1" || profile == "frontend-spa-v1" || profile == "frontend-nextjs-v1";
}

int current_passing_fixture_count(const std::vector<SkillRunLite>& runs) {
    std::map<std::string, bool> seen;
    int n = 0;
    for (const SkillRunLite& run : runs) {
        std::string id = trim_copy(run.fixture_id);
        if (id.empty()) continue;
        if (seen.find(id) != seen.end()) continue;
        seen[id] = true;
        if (run.result == kSkillRunPassed) ++n;
    }
    return n;
}

bool validate_record_skill_run(const RecordSkillRunRequest& r, std::string* err) {
    auto fail_run = [&]() {
        if (err) *err = "skill verification run is invalid";
        return false;
    };
    if (r.command != kRecordSkillRunCommand) return fail_run();
    if (!safe_extractor_id(r.skill_name)) return fail_run();
    std::string origin = trim_copy(r.origin_node_id);
    if (origin.empty() || origin.size() > 64) return fail_run();
    std::string fixture = trim_copy(r.fixture_id);
    if (fixture.empty() || fixture.size() > 128) return fail_run();
    if (trim_copy(r.suite_id).size() > 128) return fail_run();
    if (trim_copy(r.verification_version).size() > 32) return fail_run();
    if (!skill_profile_allowed(r.verification_profile)) {
        if (err) *err = "verification_profile is not an allowlisted GodBrain profile";
        return false;
    }
    if (r.result != kSkillRunPassed && r.result != kSkillRunFailed) return fail_run();
    if (r.checks.size() > 16) return fail_run();
    for (const auto& kv : r.checks) {
        if (kv.first.size() > 64 || kv.second.size() > 64) return fail_run();
    }
    if (r.environment_hash.size() > 128 || r.artifact_hash.size() > 128) return fail_run();
    if (r.log_excerpt.size() > 4096) return fail_run();
    std::string reason = trim_copy(r.reasoning);
    if (static_cast<int>(reason.size()) < kMinJudgmentReason ||
        static_cast<int>(r.reasoning.size()) > kMaxJudgmentReason) {
        if (err) *err = "judgment reasoning is required";
        return false;
    }
    return true;
}

bool validate_promote_skill(const PromoteSkillRequest& r, std::string* err) {
    if (r.command != kPromoteSkillCommand) {
        if (err) *err = "skill verification run is invalid";
        return false;
    }
    if (!safe_extractor_id(r.name)) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    if (trim_copy(r.origin_node_id).empty()) {
        if (err) *err = "knowledge node not found";
        return false;
    }
    if (trim_copy(r.origin_version).empty() || trim_copy(r.origin_hash).empty()) {
        if (err) *err = "skill origin node hash mismatch";
        return false;
    }
    if (r.schema_version.empty() || r.schema_version.size() > 64) {
        if (err) *err = "skills_extracted entry is invalid";
        return false;
    }
    std::string reason = trim_copy(r.reasoning);
    if (static_cast<int>(reason.size()) < kMinJudgmentReason ||
        static_cast<int>(r.reasoning.size()) > kMaxJudgmentReason) {
        if (err) *err = "judgment reasoning is required";
        return false;
    }
    if (!r.verification_profile.empty() && !skill_profile_allowed(r.verification_profile)) {
        if (err) *err = "verification_profile is not an allowlisted GodBrain profile";
        return false;
    }
    return true;
}

bool validate_query_skills(const QuerySkillsRequest& r, std::string* err) {
    if (r.command != kQuerySkillsCommand) {
        if (err) *err = "skill verification run is invalid";
        return false;
    }
    if (r.query.size() > 512) {
        if (err) *err = "skill verification run is invalid";
        return false;
    }
    return true;
}

bool validate_pre_ingestion(const DistillationPayload& p, std::string* err) {
    if (p.has_document) {
        if (err) *err = "document payload not in cpp memory-store protocol cut 1";
        return false;
    }
    std::string extractor = p.extractor_id.empty() ? kDefaultExtractorID : p.extractor_id;
    if (!safe_extractor_id(extractor) || p.extractor_version.empty() ||
        p.extractor_version.size() > 128 || p.schema_version.empty() ||
        p.schema_version.size() > 64) {
        if (err) *err = "extractor identity is invalid";
        return false;
    }
    if (p.trust_tier != kStatusCandidate) {
        if (err) *err = "trust_tier must be 'candidate'";
        return false;
    }
    if (p.provenance.source_id.empty() || p.provenance.source_id.size() > 512 ||
        p.provenance.source_type.empty() || p.provenance.source_type.size() > 64 ||
        p.provenance.language.empty() || p.provenance.language.size() > 64) {
        if (err) *err = "source provenance identity is invalid";
        return false;
    }
    if (keccak256_hex(p.raw_transcript) != p.provenance.source_hash) {
        if (err) {
            *err = "source_hash mismatch: transcript hash does not match provenance source_hash";
        }
        return false;
    }
    return true;
}

bool classify_and_parse(const std::string& json_text, Route* route, std::string* err) {
    Json root;
    if (!parse_json(json_text, &root, err)) return false;
    if (!json_is_object(root)) {
        if (err) *err = "payload must be a JSON object";
        return false;
    }
    std::string command;
    if (json_has(root, "command")) {
        if (!json_string(root, "command", &command)) {
            if (err) *err = "command must be a string";
            return false;
        }
    }
    if (command == kJudgmentCommand) {
        if (!json_reject_unknown_keys(root, kJudgmentKeys, err)) return false;
        route->kind = CommandKind::SetStatus;
        route->judgment.command = command;
        if (!require_string_field(root, "id", &route->judgment.id, err)) return false;
        if (!require_string_field(root, "status", &route->judgment.status, err)) return false;
        if (!require_string_field(root, "reasoning", &route->judgment.reasoning, err)) return false;
        return validate_status_judgment(route->judgment, err);
    }
    if (command == kStalePinsCommand) {
        if (!json_reject_unknown_keys(root, kStalePinsKeys, err)) return false;
        route->kind = CommandKind::StalePins;
        route->stale_pins.command = command;
        json_string(root, "sector", &route->stale_pins.sector);
        json_string(root, "pin", &route->stale_pins.pin);
        json_string(root, "reasoning", &route->stale_pins.reasoning);
        return validate_stale_pins(route->stale_pins, err);
    }
    if (command == kRecordSkillRunCommand) {
        if (!json_reject_unknown_keys(root, kRecordSkillKeys, err)) return false;
        route->kind = CommandKind::RecordSkillRun;
        route->skill_run.command = command;
        json_string(root, "skill_name", &route->skill_run.skill_name);
        json_string(root, "origin_node_id", &route->skill_run.origin_node_id);
        json_string(root, "fixture_id", &route->skill_run.fixture_id);
        json_string(root, "suite_id", &route->skill_run.suite_id);
        json_string(root, "verification_profile", &route->skill_run.verification_profile);
        json_string(root, "verification_version", &route->skill_run.verification_version);
        json_string(root, "environment_hash", &route->skill_run.environment_hash);
        json_string(root, "result", &route->skill_run.result);
        json_string(root, "artifact_hash", &route->skill_run.artifact_hash);
        json_string(root, "log_excerpt", &route->skill_run.log_excerpt);
        json_string(root, "reasoning", &route->skill_run.reasoning);
        if (json_has(root, "checks")) {
            const Json* checks = json_get(root, "checks");
            if (checks == nullptr || checks->kind != Json::Kind::Object) {
                if (err) *err = "skill verification run is invalid";
                return false;
            }
            for (const auto& kv : checks->obj) {
                if (kv.second.kind != Json::Kind::String) {
                    if (err) *err = "skill verification run is invalid";
                    return false;
                }
                route->skill_run.checks[kv.first] = kv.second.str;
            }
        }
        return validate_record_skill_run(route->skill_run, err);
    }
    if (command == kPromoteSkillCommand) {
        if (!json_reject_unknown_keys(root, kPromoteSkillKeys, err)) return false;
        route->kind = CommandKind::PromoteSkill;
        route->promote.command = command;
        json_string(root, "name", &route->promote.name);
        json_string(root, "content", &route->promote.content);
        json_string(root, "origin_node_id", &route->promote.origin_node_id);
        json_string(root, "origin_version", &route->promote.origin_version);
        json_string(root, "origin_hash", &route->promote.origin_hash);
        json_string(root, "schema_version", &route->promote.schema_version);
        json_string(root, "verification_profile", &route->promote.verification_profile);
        json_string(root, "reasoning", &route->promote.reasoning);
        return validate_promote_skill(route->promote, err);
    }
    if (command == kQuerySkillsCommand) {
        if (!json_reject_unknown_keys(root, kQuerySkillsKeys, err)) return false;
        route->kind = CommandKind::QuerySkills;
        route->query_skills.command = command;
        json_string(root, "query", &route->query_skills.query);
        if (json_has(root, "limit")) {
            double n = 0;
            if (!json_number(root, "limit", &n)) {
                if (err) *err = "skill verification run is invalid";
                return false;
            }
            route->query_skills.limit = static_cast<int>(n);
        }
        return validate_query_skills(route->query_skills, err);
    }
    if (!command.empty()) {
        if (err) *err = "unknown command";
        return false;
    }

    if (!json_reject_unknown_keys(root, kIngestKeys, err)) return false;
    route->kind = CommandKind::Ingest;
    json_string(root, "extractor_id", &route->ingest.extractor_id);
    if (!require_string_field(root, "extractor_version", &route->ingest.extractor_version, err)) {
        return false;
    }
    if (!require_string_field(root, "schema_version", &route->ingest.schema_version, err)) {
        return false;
    }
    if (json_has(root, "degraded") && !json_bool(root, "degraded", &route->ingest.degraded)) {
        if (err) *err = "degraded must be a boolean";
        return false;
    }
    if (!require_string_field(root, "raw_transcript", &route->ingest.raw_transcript, err)) {
        return false;
    }
    const Json* payload = json_get(root, "payload");
    if (payload == nullptr || !json_is_object(*payload)) {
        if (err) *err = "payload must be an object";
        return false;
    }
    if (!json_reject_unknown_keys(*payload, kPayloadKeys, err)) return false;
    if (!require_string_field(*payload, "trust_tier", &route->ingest.trust_tier, err)) return false;
    const Json* prov = json_get(*payload, "provenance");
    if (prov == nullptr || !json_is_object(*prov)) {
        if (err) *err = "provenance must be an object";
        return false;
    }
    if (!json_reject_unknown_keys(*prov, kProvKeys, err)) return false;
    if (!require_string_field(*prov, "source_id", &route->ingest.provenance.source_id, err)) {
        return false;
    }
    if (!require_string_field(*prov, "source_type", &route->ingest.provenance.source_type, err)) {
        return false;
    }
    if (!require_string_field(*prov, "source_hash", &route->ingest.provenance.source_hash, err)) {
        return false;
    }
    if (!require_string_field(*prov, "language", &route->ingest.provenance.language, err)) {
        return false;
    }
    json_string(*prov, "prompt_hash", &route->ingest.provenance.prompt_hash);
    json_string(*prov, "model_id", &route->ingest.provenance.model_id);
    json_string(*prov, "model_hash", &route->ingest.provenance.model_hash);
    json_number(*prov, "llm_temperature", &route->ingest.provenance.llm_temperature);

    const Json* claims = json_get(*payload, "claims");
    if (claims != nullptr) {
        if (claims->kind != Json::Kind::Array) {
            if (err) *err = "claims must be an array";
            return false;
        }
        for (const Json& item : claims->arr) {
            if (!json_is_object(item)) {
                if (err) *err = "claim must be an object";
                return false;
            }
            if (!json_reject_unknown_keys(item, kClaimKeys, err)) return false;
            Claim c;
            json_string(item, "claim_id", &c.claim_id);
            json_string(item, "type", &c.type);
            if (!require_string_field(item, "content", &c.content, err)) return false;
            json_number(item, "confidence", &c.confidence);
            const Json* spans = json_get(item, "evidence_spans");
            if (spans != nullptr) {
                if (spans->kind != Json::Kind::Array) {
                    if (err) *err = "evidence_spans must be an array";
                    return false;
                }
                for (const Json& sp : spans->arr) {
                    if (sp.kind != Json::Kind::String) {
                        if (err) *err = "evidence_spans entries must be strings";
                        return false;
                    }
                    c.evidence_spans.push_back(sp.str);
                }
            }
            c.type = collapse_ws(c.type);
            for (char& ch : c.type) {
                ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            }
            c.content = collapse_ws(c.content);
            route->ingest.claims.push_back(std::move(c));
        }
    }
    auto take_strings = [&](const char* key, std::vector<std::string>* dest) -> bool {
        const Json* arr = json_get(*payload, key);
        if (arr == nullptr) return true;
        if (arr->kind != Json::Kind::Array) {
            if (err) *err = std::string(key) + " must be an array";
            return false;
        }
        for (const Json& item : arr->arr) {
            if (item.kind != Json::Kind::String) {
                if (err) *err = std::string(key) + " entries must be strings";
                return false;
            }
            dest->push_back(item.str);
        }
        return true;
    };
    if (!take_strings("core_concepts", &route->ingest.core_concepts)) return false;
    if (!take_strings("opsec_candidates", &route->ingest.opsec_candidates)) return false;

    const Json* extracted = json_get(*payload, "skills_extracted");
    if (extracted != nullptr) {
        if (extracted->kind != Json::Kind::Array) {
            if (err) *err = "skills_extracted must be an array";
            return false;
        }
        size_t n = extracted->arr.size();
        if (n > static_cast<size_t>(kMaxExtractedSkills)) n = static_cast<size_t>(kMaxExtractedSkills);
        for (size_t i = 0; i < n; ++i) {
            const Json& item = extracted->arr[i];
            if (!json_is_object(item)) {
                if (err) *err = "skills_extracted entry is invalid";
                return false;
            }
            if (!json_reject_unknown_keys(item, kSkillExtractedKeys, err)) return false;
            SkillExtracted s;
            json_string(item, "name", &s.name);
            json_string(item, "content", &s.content);
            json_string(item, "task_kind", &s.task_kind);
            json_string(item, "framework", &s.framework);
            json_string(item, "verification_profile", &s.verification_profile);
            json_number(item, "confidence", &s.confidence);
            auto take_arr = [&](const char* key, std::vector<std::string>* dest) -> bool {
                const Json* arr = json_get(item, key);
                if (arr == nullptr) return true;
                if (arr->kind != Json::Kind::Array) {
                    if (err) *err = "skills_extracted entry is invalid";
                    return false;
                }
                for (const Json& v : arr->arr) {
                    if (v.kind != Json::Kind::String) {
                        if (err) *err = "skills_extracted entry is invalid";
                        return false;
                    }
                    dest->push_back(v.str);
                }
                return true;
            };
            if (!take_arr("required_inputs", &s.required_inputs)) return false;
            if (!take_arr("procedure", &s.procedure)) return false;
            if (!take_arr("evidence_spans", &s.evidence_spans)) return false;
            s.name = trim_copy(s.name);
            s.content = trim_copy(s.content);
            s.task_kind = collapse_ws(s.task_kind);
            for (char& c : s.task_kind) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            s.framework = trim_copy(s.framework);
            for (char& c : s.framework) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            s.verification_profile = trim_copy(s.verification_profile);
            if (!s.verification_profile.empty() && !skill_profile_allowed(s.verification_profile)) {
                s.verification_profile.clear();
            }
            std::vector<std::string> inputs;
            for (const std::string& in : s.required_inputs) {
                std::string t = trim_copy(in);
                if (!t.empty()) inputs.push_back(t);
            }
            s.required_inputs = std::move(inputs);
            std::vector<std::string> steps;
            for (const std::string& step : s.procedure) {
                std::string t = trim_copy(step);
                if (!t.empty()) steps.push_back(t);
            }
            s.procedure = std::move(steps);
            std::string verr;
            if (!validate_skill_extracted(s, &verr)) continue;
            if (!validate_evidence_spans(s.evidence_spans, route->ingest.raw_transcript, err)) return false;
            route->ingest.skills_extracted.push_back(std::move(s));
        }
    }

    route->ingest.has_document = json_has(root, "document") || json_has(root, "chunks");
    return validate_pre_ingestion(route->ingest, err);
}

int run_self_test() {
    int failed = 0;
    auto check = [&](bool ok, const char* name) {
        if (!ok) {
            std::fprintf(stderr, "FAIL %s\n", name);
            ++failed;
        }
    };

    std::string err;
    std::string capped;
    check(!read_capped("", &capped, &err), "empty");
    err.clear();
    check(!read_capped(std::string(kMaxInputBytes + 1, 'a'), &capped, &err), "oversize");

    check(allowed_status_transition("candidate", "verified"), "cand-ver");
    check(allowed_status_transition("verified", "rejected"), "ver-rej");
    check(allowed_status_transition("verified", "stale"), "ver-stale");
    check(allowed_status_transition("stale", "verified"), "stale-ver");
    check(!allowed_status_transition("rejected", "verified"), "rej-terminal");
    check(!allowed_status_transition("rejected", "stale"), "rej-stale");

    StatusJudgment j;
    j.command = kJudgmentCommand;
    j.id = "claim:auth";
    j.status = kStatusVerified;
    j.reasoning = "clicking the button actually saves the file";
    err.clear();
    check(validate_status_judgment(j, &err), "judgment-ok");
    j.reasoning = "ok";
    err.clear();
    check(!validate_status_judgment(j, &err), "judgment-short");

    const std::string hello = "hello";
    const std::string hash = keccak256_hex(hello);
    const std::string good =
        std::string("{\"extractor_version\":\"v1\",\"schema_version\":\"1.0\",") +
        "\"raw_transcript\":\"hello\",\"payload\":{\"trust_tier\":\"candidate\","
        "\"provenance\":{\"source_id\":\"session\",\"source_type\":\"session_transcript\","
        "\"source_hash\":\"" +
        hash + "\",\"language\":\"mixed\"}}}";
    Route r;
    err.clear();
    check(classify_and_parse(good, &r, &err), "ingest-ok");

    std::string bad_hash = good;
    auto pos = bad_hash.find(hash);
    if (pos != std::string::npos) bad_hash.replace(pos, hash.size(), std::string(64, '0'));
    err.clear();
    check(!classify_and_parse(bad_hash, &r, &err), "ingest-hash");

    std::string verified = good;
    auto tpos = verified.find("candidate");
    if (tpos != std::string::npos) verified.replace(tpos, 9, "verified");
    err.clear();
    check(!classify_and_parse(verified, &r, &err), "ingest-trust");

    err.clear();
    check(!classify_and_parse(good + " {}", &r, &err), "trailing");

    const std::string unknown =
        std::string("{\"extractor_version\":\"v1\",\"schema_version\":\"1.0\",") +
        "\"raw_transcript\":\"hello\",\"surprise\":true,\"payload\":{\"trust_tier\":\"candidate\","
        "\"provenance\":{\"source_id\":\"session\",\"source_type\":\"session_transcript\","
        "\"source_hash\":\"" +
        hash + "\",\"language\":\"mixed\"}}}";
    err.clear();
    check(!classify_and_parse(unknown, &r, &err), "unknown-field");

    const std::string judge =
        "{\"command\":\"set_status\",\"id\":\"claim:auth\",\"status\":\"verified\","
        "\"reasoning\":\"clicking the button actually saves the file\"}";
    err.clear();
    check(classify_and_parse(judge, &r, &err) && r.kind == CommandKind::SetStatus, "set-status");

    const std::string skill_run =
        "{\"command\":\"record_skill_run\",\"skill_name\":\"build-galaxy-glance\","
        "\"origin_node_id\":\"0123456789abcdef01234567\",\"fixture_id\":\"galaxy-brief-v1\","
        "\"verification_profile\":\"galaxy-html-v1\",\"result\":\"passed\","
        "\"reasoning\":\"desk test passed on loopback\"}";
    err.clear();
    check(classify_and_parse(skill_run, &r, &err) && r.kind == CommandKind::RecordSkillRun, "record-skill-ok");
    std::string bad_profile = skill_run;
    auto ppos = bad_profile.find("galaxy-html-v1");
    if (ppos != std::string::npos) bad_profile.replace(ppos, 14, "npm-audit-force");
    err.clear();
    check(!classify_and_parse(bad_profile, &r, &err), "record-skill-profile");
    check(skill_profile_suite_required("galaxy-html-v1") && !skill_profile_suite_required("desk-v1"),
          "suite-profiles");
    check(skill_profile_apply_only("local-edit-apply-v1") && !skill_profile_apply_only("desk-v1"),
          "apply-only-profile");
    check(current_passing_fixture_count({{"a", "passed"}, {"a", "passed"}, {"b", "failed"}}) == 1,
          "fixture-same-twice");
    check(current_passing_fixture_count({{"a", "failed"}, {"a", "passed"}, {"b", "passed"}}) == 1,
          "fixture-later-fail-drops");
    check(current_passing_fixture_count({{"a", "passed"}, {"b", "passed"}}) == 2, "fixture-two-pass");
    const std::string promote =
        "{\"command\":\"promote_skill\",\"name\":\"build-galaxy-glance\",\"content\":\"keep brief\","
        "\"origin_node_id\":\"0123456789abcdef01234567\",\"origin_version\":\"v1\","
        "\"origin_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\","
        "\"schema_version\":\"1.0\",\"verification_profile\":\"galaxy-html-v1\","
        "\"reasoning\":\"two fixtures passed\"}";
    err.clear();
    check(classify_and_parse(promote, &r, &err) && r.kind == CommandKind::PromoteSkill, "promote-ok");
    const std::string qskills = "{\"command\":\"query_skills\",\"query\":\"desk\",\"limit\":5}";
    err.clear();
    check(classify_and_parse(qskills, &r, &err) && r.kind == CommandKind::QuerySkills, "query-skills-ok");
    const std::string stale =
        "{\"command\":\"stale_pins\",\"sector\":\"windows-sre\",\"pin\":\"IoTEnterpriseS/26100.1\","
        "\"reasoning\":\"os_pin changed previous -> live\"}";
    err.clear();
    check(classify_and_parse(stale, &r, &err) && r.kind == CommandKind::StalePins, "stale-pins-ok");
    check(has_mismatched_os_pin("os_pin=old/1", "new/1") && !has_mismatched_os_pin("os_pin=new/1", "new/1"),
          "os-pin-mismatch");
    err.clear();
    check(!classify_and_parse(
              "{\"command\":\"stale_pins\",\"sector\":\"tanks\",\"pin\":\"x\",\"reasoning\":\"abcd\"}", &r, &err),
          "stale-pins-sector");
    const std::string bad_skills =
        std::string("{\"extractor_version\":\"v1\",\"schema_version\":\"1.0\",") +
        "\"raw_transcript\":\"hello\",\"payload\":{\"trust_tier\":\"candidate\","
        "\"provenance\":{\"source_id\":\"session\",\"source_type\":\"session_transcript\","
        "\"source_hash\":\"" +
        hash + "\",\"language\":\"mixed\"},\"skills_extracted\":true}}";
    err.clear();
    check(!classify_and_parse(bad_skills, &r, &err), "skills-extracted-type");

    check(allowed_run_transition(kRunStaging, kRunValidated), "run-stag-val");
    check(allowed_run_transition(kRunStaging, kRunFailed), "run-stag-fail");
    check(allowed_run_transition(kRunValidated, kRunCommitted), "run-val-com");
    check(allowed_run_transition(kRunValidated, kRunFailed), "run-val-fail");
    check(!allowed_run_transition(kRunCommitted, kRunFailed), "run-com-terminal");
    check(!allowed_run_transition(kRunFailed, kRunStaging), "run-fail-no-retry-via-fail");

    failed += run_embedding_self_test();

    if (failed == 0) std::fprintf(stderr, "cpp_memory_store protocol self-test ok\n");
    return failed == 0 ? 0 : 1;
}

}  // namespace godbrain::memory
