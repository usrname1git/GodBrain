#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace godbrain::memory {

constexpr std::size_t kMaxInputBytes = 15u * 1024u * 1024u;
constexpr const char* kDefaultExtractorID = "Librarian-CPP";
constexpr const char* kJudgmentCommand = "set_status";
constexpr const char* kRecordSkillRunCommand = "record_skill_run";
constexpr const char* kPromoteSkillCommand = "promote_skill";
constexpr const char* kQuerySkillsCommand = "query_skills";
constexpr const char* kStatusCandidate = "candidate";
constexpr const char* kStatusVerified = "verified";
constexpr const char* kStatusRejected = "rejected";
constexpr const char* kStatusStale = "stale";
constexpr const char* kSkillRunPassed = "passed";
constexpr const char* kSkillRunFailed = "failed";
constexpr int kMinJudgmentReason = 4;
constexpr int kMaxJudgmentReason = 2048;

enum class CommandKind {
    Ingest,
    SetStatus,
    StalePins,
    RecordSkillRun,
    PromoteSkill,
    QuerySkills,
};

struct Provenance {
    std::string source_id;
    std::string source_type;
    std::string source_hash;
    std::string language;
    std::string prompt_hash;
    std::string model_id;
    std::string model_hash;
    double llm_temperature = 0;
};

struct Claim {
    std::string claim_id;
    std::string type;
    std::string content;
    double confidence = 0;
    std::vector<std::string> evidence_spans;
};

struct DistillationPayload {
    std::string extractor_id;
    std::string extractor_version;
    std::string schema_version;
    bool degraded = false;
    std::string trust_tier;
    Provenance provenance;
    std::string raw_transcript;
    std::vector<Claim> claims;
    std::vector<std::string> core_concepts;
    std::vector<std::string> opsec_candidates;
    bool has_document = false;
};

std::string normalize_ws(const std::string& s);
std::string claim_stable_id(const Claim& claim);
std::string kind_stable_id(const std::string& prefix, const std::string& content);
bool parse_evidence_span(const std::string& span, int* start, int* end);
bool validate_evidence_spans(const std::vector<std::string>& spans, const std::string& source, std::string* err);

struct StatusJudgment {
    std::string command;
    std::string id;
    std::string status;
    std::string reasoning;
};

struct RecordSkillRunRequest {
    std::string command;
    std::string skill_name;
    std::string origin_node_id;
    std::string fixture_id;
    std::string suite_id;
    std::string verification_profile;
    std::string verification_version;
    std::string environment_hash;
    std::string result;
    std::map<std::string, std::string> checks;
    std::string artifact_hash;
    std::string log_excerpt;
    std::string reasoning;
};

struct PromoteSkillRequest {
    std::string command;
    std::string name;
    std::string content;
    std::string origin_node_id;
    std::string origin_version;
    std::string origin_hash;
    std::string schema_version;
    std::string verification_profile;
    std::string reasoning;
};

struct QuerySkillsRequest {
    std::string command;
    std::string query;
    int limit = 0;
};

struct SkillRunLite {
    std::string fixture_id;
    std::string result;
};

struct Route {
    CommandKind kind = CommandKind::Ingest;
    DistillationPayload ingest;
    StatusJudgment judgment;
    RecordSkillRunRequest skill_run;
    PromoteSkillRequest promote;
    QuerySkillsRequest query_skills;
};

std::string keccak256_hex(const std::string& bytes);
std::string error_envelope_json(const std::string& error, const std::string& details);

// Read at most kMaxInputBytes+1. empty -> err, oversize -> err.
bool read_capped(const std::string& raw, std::string* out, std::string* err);

bool classify_and_parse(const std::string& json_text, Route* route, std::string* err);
bool validate_pre_ingestion(const DistillationPayload& p, std::string* err);
bool validate_status_judgment(const StatusJudgment& j, std::string* err);
bool validate_record_skill_run(const RecordSkillRunRequest& r, std::string* err);
bool validate_promote_skill(const PromoteSkillRequest& r, std::string* err);
bool validate_query_skills(const QuerySkillsRequest& r, std::string* err);
bool allowed_status_transition(const std::string& from, const std::string& to);
bool safe_extractor_id(const std::string& id);
bool skill_profile_allowed(const std::string& profile);
bool skill_profile_apply_only(const std::string& profile);
bool skill_profile_suite_required(const std::string& profile);
int current_passing_fixture_count(const std::vector<SkillRunLite>& runs);

int run_self_test();

}  // namespace godbrain::memory
