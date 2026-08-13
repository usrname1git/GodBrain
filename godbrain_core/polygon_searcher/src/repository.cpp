#include "polygon_searcher/searcher.hpp"

#include <fstream>
#include <utility>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace godbrain::polygon {
namespace {

constexpr int snapshot_schema_version = 1;

Json snapshot_json(const SearcherSnapshot& snapshot) {
    return {
        {"schema_version", snapshot_schema_version},
        {"claimed_plan_ids", snapshot.claimed_plan_ids},
        {"pending_plan_ids", snapshot.pending_plan_ids},
        {"daily_pnl", snapshot.daily_pnl},
        {"kill", {
            {"active", snapshot.kill.active},
            {"reason", snapshot.kill.reason},
            {"latched_epoch_ms", snapshot.kill.latched_epoch_ms},
        }},
        {"reconciled_epoch_ms", snapshot.reconciled_epoch_ms},
    };
}

SearcherSnapshot parse_snapshot(const Json& value) {
    try {
        if (value.at("schema_version").get<int>() != snapshot_schema_version) {
            throw SearcherError("unsupported Polygon searcher snapshot version");
        }
        const Json& kill = value.at("kill");
        return {
            .claimed_plan_ids =
                value.at("claimed_plan_ids").get<std::set<std::string>>(),
            .pending_plan_ids =
                value.at("pending_plan_ids").get<std::set<std::string>>(),
            .daily_pnl =
                value.at("daily_pnl").get<std::map<std::string, std::int64_t>>(),
            .kill = {
                .active = kill.at("active").get<bool>(),
                .reason = kill.at("reason").get<std::string>(),
                .latched_epoch_ms = kill.at("latched_epoch_ms").get<std::int64_t>(),
            },
            .reconciled_epoch_ms =
                value.at("reconciled_epoch_ms").get<std::int64_t>(),
        };
    } catch (const Json::exception& error) {
        throw SearcherError(std::string("corrupt Polygon searcher snapshot: ") + error.what());
    }
}

void atomic_replace(
    const std::filesystem::path& temporary,
    const std::filesystem::path& destination) {
#ifdef _WIN32
    if (!MoveFileExW(
            temporary.c_str(),
            destination.c_str(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        throw SearcherError(
            "cannot atomically replace Polygon searcher snapshot: " +
            std::to_string(GetLastError()));
    }
#else
    std::error_code error;
    std::filesystem::rename(temporary, destination, error);
    if (error) {
        throw SearcherError(
            "cannot atomically replace Polygon searcher snapshot: " + error.message());
    }
#endif
}

}  // namespace

FileAuditStore::FileAuditStore(std::filesystem::path directory)
    : directory_(std::move(directory)),
      snapshot_path_(directory_ / "snapshot.json"),
      audit_path_(directory_ / "audit.jsonl") {}

void FileAuditStore::initialize(std::int64_t now_epoch_ms) {
    if (initialized_) {
        throw SearcherError("Polygon searcher audit store is already initialized");
    }
    std::error_code error;
    std::filesystem::create_directories(directory_, error);
    if (error) {
        throw SearcherError("cannot create Polygon searcher state: " + error.message());
    }
    const bool snapshot_exists = std::filesystem::exists(snapshot_path_);
    const bool audit_exists = std::filesystem::exists(audit_path_);
    if (snapshot_exists != audit_exists) {
        throw SearcherError("incomplete Polygon searcher persistence pair");
    }
    if (snapshot_exists) {
        std::ifstream input(snapshot_path_, std::ios::binary);
        if (!input) {
            throw SearcherError("cannot read Polygon searcher snapshot");
        }
        try {
            snapshot_ = parse_snapshot(Json::parse(input));
        } catch (const Json::exception& parse_error) {
            throw SearcherError(
                std::string("corrupt Polygon searcher snapshot JSON: ") +
                parse_error.what());
        }
    } else {
        snapshot_.reconciled_epoch_ms = now_epoch_ms;
        persist();
    }
    if (audit_exists) {
        std::ifstream input(audit_path_, std::ios::binary);
        if (!input) {
            throw SearcherError("cannot read append-only Polygon searcher audit");
        }
        std::string line;
        std::size_t line_number = 0;
        while (std::getline(input, line)) {
            ++line_number;
            if (line.empty()) {
                continue;
            }
            try {
                (void)Json::parse(line);
            } catch (const Json::exception& parse_error) {
                throw SearcherError(
                    "corrupt Polygon searcher audit at line " +
                    std::to_string(line_number) + ": " + parse_error.what());
            }
        }
        if (!input.eof()) {
            throw SearcherError("failed while validating Polygon searcher audit");
        }
    }
    std::ofstream writable(audit_path_, std::ios::app | std::ios::binary);
    if (!writable) {
        throw SearcherError("append-only Polygon searcher audit is unwritable");
    }
    if (!snapshot_.pending_plan_ids.empty()) {
        snapshot_.kill = {
            .active = true,
            .reason = "ambiguous_pending_cycle_on_restart",
            .latched_epoch_ms = now_epoch_ms,
        };
        snapshot_.reconciled_epoch_ms = now_epoch_ms;
        persist();
        append({
            {"type", "reconciliation_incident"},
            {"reason", snapshot_.kill.reason},
            {"pending_plan_ids", snapshot_.pending_plan_ids},
            {"epoch_ms", now_epoch_ms},
        });
    }
    initialized_ = true;
}

SearcherSnapshot FileAuditStore::load() const {
    ensure_initialized();
    return snapshot_;
}

void FileAuditStore::record_decision(
    const Decision& decision,
    const BlockContext& block) {
    ensure_initialized();
    append({
        {"type", "opportunity_decision"},
        {"block_number", block.number},
        {"block_hash", block.hash},
        {"decision", decision_json(decision)},
    });
}

bool FileAuditStore::claim(const ArbitragePlan& plan) {
    ensure_initialized();
    if (!snapshot_.claimed_plan_ids.insert(plan.id).second) {
        return false;
    }
    snapshot_.pending_plan_ids.insert(plan.id);
    persist();
    append({{"type", "paper_plan_claimed"}, {"plan", plan_json(plan)}});
    return true;
}

void FileAuditStore::complete(const std::string& plan_id) {
    ensure_initialized();
    if (snapshot_.pending_plan_ids.erase(plan_id) != 1) {
        throw SearcherError("pending Polygon paper plan was not found");
    }
    persist();
    append({{"type", "paper_plan_completed"}, {"plan_id", plan_id}});
}

void FileAuditStore::record_paper_result(
    const PaperResult& result,
    std::string_view trading_day,
    std::string_view token_id) {
    ensure_initialized();
    const std::string key =
        std::string(trading_day) + ":" + std::string(token_id);
    const std::int64_t current =
        snapshot_.daily_pnl.contains(key) ? snapshot_.daily_pnl.at(key) : 0;
    if ((result.realized_pnl > 0 &&
         current > std::numeric_limits<std::int64_t>::max() - result.realized_pnl) ||
        (result.realized_pnl < 0 &&
         current < std::numeric_limits<std::int64_t>::min() - result.realized_pnl)) {
        throw SearcherError("daily paper PnL overflow");
    }
    snapshot_.daily_pnl[key] = current + result.realized_pnl;
    persist();
    append({
        {"type", "paper_settlement"},
        {"trading_day", trading_day},
        {"token_id", token_id},
        {"result", paper_result_json(result)},
        {"cumulative_pnl", std::to_string(snapshot_.daily_pnl.at(key))},
    });
}

void FileAuditStore::record_incident(
    std::string reason,
    std::string plan_id,
    std::int64_t epoch_ms) {
    ensure_initialized();
    append({
        {"type", "paper_incident"},
        {"reason", std::move(reason)},
        {"plan_id", std::move(plan_id)},
        {"epoch_ms", epoch_ms},
    });
}

void FileAuditStore::latch_kill(std::string reason, std::int64_t epoch_ms) {
    ensure_initialized();
    if (snapshot_.kill.active) {
        return;
    }
    snapshot_.kill = {
        .active = true,
        .reason = std::move(reason),
        .latched_epoch_ms = epoch_ms,
    };
    persist();
    append({
        {"type", "kill_switch_latched"},
        {"reason", snapshot_.kill.reason},
        {"epoch_ms", epoch_ms},
    });
}

void FileAuditStore::ensure_initialized() const {
    if (!initialized_) {
        throw SearcherError("Polygon searcher audit store is not initialized");
    }
}

void FileAuditStore::persist() {
    const std::filesystem::path temporary = snapshot_path_.string() + ".tmp";
    {
        std::ofstream output(
            temporary, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw SearcherError("cannot write temporary Polygon searcher snapshot");
        }
        output << snapshot_json(snapshot_).dump(2) << '\n';
        output.flush();
        if (!output) {
            throw SearcherError("failed while flushing Polygon searcher snapshot");
        }
    }
    atomic_replace(temporary, snapshot_path_);
}

void FileAuditStore::append(const Json& event) {
    std::ofstream output(audit_path_, std::ios::app | std::ios::binary);
    if (!output) {
        throw SearcherError("cannot append Polygon searcher audit");
    }
    output << event.dump() << '\n';
    output.flush();
    if (!output) {
        throw SearcherError("failed while flushing Polygon searcher audit");
    }
}

}  // namespace godbrain::polygon
