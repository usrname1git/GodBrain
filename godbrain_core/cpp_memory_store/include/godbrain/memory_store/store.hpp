#pragma once

#include "godbrain/memory_store/protocol.hpp"

#include <string>
#include <vector>

namespace godbrain::memory {

struct StoreReceipt {
    std::string run_id;
    std::string record_id;
    std::string version;
    std::string schema_version;
    std::string status;
    int insert_count = 0;
    int update_count = 0;
    std::string timestamp;
};

struct JudgmentReceiptOut {
    std::string node_id;
    std::string stable_id;
    std::string from;
    std::string to;
    std::string status;
    std::string timestamp;
};

struct SkillRunReceiptOut {
    std::string run_id;
    std::string skill_name;
    std::string origin_node_id;
    std::string result;
    std::string status;
    std::string timestamp;
};

struct PromoteSkillReceiptOut {
    std::string skill_id;
    std::string name;
    std::string origin_node_id;
    std::string status;
    std::string timestamp;
};

struct QuerySkillHit {
    std::string name;
    std::string content;
    std::string origin_node_id;
    std::string origin_hash;
    std::string verification_profile;
};

struct QuerySkillsReceiptOut {
    std::string status;
    int count = 0;
    std::vector<QuerySkillHit> skills;
    std::string timestamp;
};

struct StalePinsReceiptOut {
    std::string status;
    std::string sector;
    std::string pin;
    int stale = 0;
    std::string timestamp;
};

std::string store_receipt_json(const StoreReceipt& r);
std::string judgment_receipt_json(const JudgmentReceiptOut& r);
std::string skill_run_receipt_json(const SkillRunReceiptOut& r);
std::string promote_skill_receipt_json(const PromoteSkillReceiptOut& r);
std::string query_skills_receipt_json(const QuerySkillsReceiptOut& r);
std::string stale_pins_receipt_json(const StalePinsReceiptOut& r);

bool store_available();

// Open from MONGODB_URI / MONGODB_DB_NAME. Caller must store_close.
struct StoreHandle;
StoreHandle* store_open(std::string* err);
void store_close(StoreHandle* h);

bool store_ingest(
    StoreHandle* h, const DistillationPayload& payload, StoreReceipt* receipt, std::string* err);
bool store_set_status(
    StoreHandle* h, const StatusJudgment& judgment, JudgmentReceiptOut* receipt, std::string* err);
bool store_stale_pins(
    StoreHandle* h, const StalePinsRequest& request, StalePinsReceiptOut* receipt, std::string* err);
bool store_record_skill_run(
    StoreHandle* h, const RecordSkillRunRequest& request, SkillRunReceiptOut* receipt, std::string* err);
bool store_promote_skill(
    StoreHandle* h, const PromoteSkillRequest& request, PromoteSkillReceiptOut* receipt, std::string* err);
bool store_query_skills(
    StoreHandle* h, const QuerySkillsRequest& request, QuerySkillsReceiptOut* receipt, std::string* err);

bool store_rebuild(StoreHandle* h, std::string* json_out, std::string* err);

}  // namespace godbrain::memory
