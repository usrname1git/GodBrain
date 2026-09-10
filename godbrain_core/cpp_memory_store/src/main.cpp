#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/store.hpp"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--self-test") {
            return godbrain::memory::run_self_test();
        }
    }

    std::string raw;
    char buf[4096];
    while (std::cin.read(buf, sizeof buf) || std::cin.gcount() > 0) {
        raw.append(buf, static_cast<std::size_t>(std::cin.gcount()));
        if (raw.size() > godbrain::memory::kMaxInputBytes) break;
    }
    std::string body;
    std::string err;
    if (!godbrain::memory::read_capped(raw, &body, &err)) {
        std::cout << godbrain::memory::error_envelope_json(err, "");
        return 1;
    }
    godbrain::memory::Route route;
    if (!godbrain::memory::classify_and_parse(body, &route, &err)) {
        std::cout << godbrain::memory::error_envelope_json("Failed to parse JSON payload", err);
        return 1;
    }
    if (!godbrain::memory::store_available()) {
        std::cout << godbrain::memory::error_envelope_json(
            "mongo-c-driver not linked", "run scripts/Fetch-MongoCDriver.ps1");
        return 1;
    }
    std::string open_err;
    godbrain::memory::StoreHandle* store = godbrain::memory::store_open(&open_err);
    if (store == nullptr) {
        if (open_err.find("embedding") != std::string::npos) {
            std::cout << godbrain::memory::error_envelope_json(
                "Invalid embedding configuration", open_err);
        } else {
            std::cout << godbrain::memory::error_envelope_json(
                "Failed to connect to MongoDB", open_err);
        }
        return 1;
    }
    int rc = 1;
    if (route.kind == godbrain::memory::CommandKind::Ingest) {
        godbrain::memory::StoreReceipt receipt;
        if (godbrain::memory::store_ingest(store, route.ingest, &receipt, &err)) {
            std::cout << godbrain::memory::store_receipt_json(receipt);
            rc = 0;
        } else if (err.find("RAG projection") != std::string::npos) {
            std::cout << godbrain::memory::error_envelope_json(
                "Committed ingestion RAG projection failed", err);
        } else {
            std::cout << godbrain::memory::error_envelope_json("StartIngestion failed", err);
        }
    } else if (route.kind == godbrain::memory::CommandKind::SetStatus) {
        godbrain::memory::JudgmentReceiptOut receipt;
        if (godbrain::memory::store_set_status(store, route.judgment, &receipt, &err)) {
            std::cout << godbrain::memory::judgment_receipt_json(receipt);
            rc = 0;
        } else if (err.find("RAG status") != std::string::npos) {
            std::cout << godbrain::memory::error_envelope_json("RAG status sync failed", err);
        } else {
            std::cout << godbrain::memory::error_envelope_json("set_status failed", err);
        }
    } else if (route.kind == godbrain::memory::CommandKind::RecordSkillRun) {
        godbrain::memory::SkillRunReceiptOut receipt;
        if (godbrain::memory::store_record_skill_run(store, route.skill_run, &receipt, &err)) {
            std::cout << godbrain::memory::skill_run_receipt_json(receipt);
            rc = 0;
        } else {
            std::cout << godbrain::memory::error_envelope_json("RecordSkillVerificationRun failed", err);
        }
    } else if (route.kind == godbrain::memory::CommandKind::PromoteSkill) {
        godbrain::memory::PromoteSkillReceiptOut receipt;
        if (godbrain::memory::store_promote_skill(store, route.promote, &receipt, &err)) {
            std::cout << godbrain::memory::promote_skill_receipt_json(receipt);
            rc = 0;
        } else {
            std::cout << godbrain::memory::error_envelope_json("PromoteSkill failed", err);
        }
    } else if (route.kind == godbrain::memory::CommandKind::QuerySkills) {
        godbrain::memory::QuerySkillsReceiptOut receipt;
        if (godbrain::memory::store_query_skills(store, route.query_skills, &receipt, &err)) {
            std::cout << godbrain::memory::query_skills_receipt_json(receipt);
            rc = 0;
        } else {
            std::cout << godbrain::memory::error_envelope_json("QueryPromotedSkills failed", err);
        }
    } else {
        std::cout << godbrain::memory::error_envelope_json(
            "command not in cpp memory-store store cut", err);
    }
    godbrain::memory::store_close(store);
    return rc;
}
