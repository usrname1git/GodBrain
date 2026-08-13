#include "polymarket/paper.hpp"

#include <fstream>
#include <utility>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace polymarket::paper {
namespace {

constexpr int schema_version = 1;

Json position_json(const PaperPosition& position) {
    return {
        {"id", position.id},
        {"opportunity_id", position.opportunity_id},
        {"market_id", position.market_id},
        {"condition_id", position.condition_id},
        {"quantity", position.quantity.str()},
        {"acquisition_cost", position.acquisition_cost.str()},
        {"yes_quantity", position.yes_quantity.str()},
        {"no_quantity", position.no_quantity.str()},
        {"opened_epoch_ms", position.opened_epoch_ms},
        {"settle_after_epoch_ms", position.settle_after_epoch_ms},
        {"state", position_state_name(position.state)},
    };
}

PaperPosition parse_position(const Json& value) {
    try {
        return {
            .id = value.at("id").get<std::string>(),
            .opportunity_id = value.at("opportunity_id").get<std::string>(),
            .market_id = value.at("market_id").get<std::string>(),
            .condition_id = value.at("condition_id").get<std::string>(),
            .quantity = Decimal::parse(value.at("quantity").get<std::string>()),
            .acquisition_cost =
                Decimal::parse(value.at("acquisition_cost").get<std::string>()),
            .yes_quantity = Decimal::parse(value.at("yes_quantity").get<std::string>()),
            .no_quantity = Decimal::parse(value.at("no_quantity").get<std::string>()),
            .opened_epoch_ms = value.at("opened_epoch_ms").get<std::int64_t>(),
            .settle_after_epoch_ms =
                value.at("settle_after_epoch_ms").get<std::int64_t>(),
            .state = parse_position_state(value.at("state").get<std::string>()),
        };
    } catch (const Json::exception& error) {
        throw PaperError(std::string("corrupt position state: ") + error.what());
    }
}

Json snapshot_json(
    const Snapshot& snapshot,
    const std::set<std::string>& pnl_event_ids) {
    Json positions = Json::array();
    for (const auto& position : snapshot.positions) {
        positions.push_back(position_json(position));
    }
    Json pnl = Json::object();
    for (const auto& [day, amount] : snapshot.realized_pnl) {
        pnl[day] = amount.str();
    }
    return {
        {"schema_version", schema_version},
        {"claimed_opportunities", snapshot.claimed_opportunities},
        {"pending_opportunities", snapshot.pending_opportunities},
        {"positions", positions},
        {"realized_pnl", pnl},
        {"pnl_event_ids", pnl_event_ids},
        {"kill", {
            {"active", snapshot.kill.active},
            {"reason", snapshot.kill.reason},
            {"trading_day", snapshot.kill.trading_day},
            {"latched_epoch_ms", snapshot.kill.latched_epoch_ms},
        }},
        {"last_reconciliation_epoch_ms", snapshot.last_reconciliation_epoch_ms},
    };
}

void parse_snapshot(
    const Json& value,
    Snapshot* snapshot,
    std::set<std::string>* pnl_event_ids) {
    try {
        if (value.at("schema_version").get<int>() != schema_version) {
            throw PaperError("unsupported paper-state schema version");
        }
        snapshot->claimed_opportunities =
            value.at("claimed_opportunities").get<std::set<std::string>>();
        snapshot->pending_opportunities =
            value.at("pending_opportunities").get<std::set<std::string>>();
        snapshot->positions.clear();
        for (const Json& position : value.at("positions")) {
            snapshot->positions.push_back(parse_position(position));
        }
        snapshot->realized_pnl.clear();
        for (const auto& [day, amount] : value.at("realized_pnl").items()) {
            snapshot->realized_pnl.emplace(day, Decimal::parse(amount.get<std::string>()));
        }
        *pnl_event_ids = value.at("pnl_event_ids").get<std::set<std::string>>();
        const Json& kill = value.at("kill");
        snapshot->kill = {
            .active = kill.at("active").get<bool>(),
            .reason = kill.at("reason").get<std::string>(),
            .trading_day = kill.at("trading_day").get<std::string>(),
            .latched_epoch_ms = kill.at("latched_epoch_ms").get<std::int64_t>(),
        };
        snapshot->last_reconciliation_epoch_ms =
            value.at("last_reconciliation_epoch_ms").get<std::int64_t>();
    } catch (const Json::exception& error) {
        throw PaperError(std::string("corrupt paper-state snapshot: ") + error.what());
    }
}

void replace_position(std::vector<PaperPosition>* positions, const PaperPosition& position) {
    const auto found = std::find_if(
        positions->begin(), positions->end(), [&](const PaperPosition& current) {
            return current.id == position.id;
        });
    if (found == positions->end()) {
        throw PaperError("position update target not found");
    }
    *found = position;
}

}  // namespace

FileRepository::FileRepository(std::filesystem::path directory)
    : directory_(std::move(directory)),
      snapshot_path_(directory_ / "snapshot.json"),
      audit_path_(directory_ / "audit.jsonl") {}

void FileRepository::initialize() {
    std::error_code error;
    std::filesystem::create_directories(directory_, error);
    if (error) {
        throw PaperError("cannot create paper-state directory: " + error.message());
    }
    if (std::filesystem::exists(snapshot_path_)) {
        std::ifstream input(snapshot_path_, std::ios::binary);
        if (!input) {
            throw PaperError("cannot read paper-state snapshot");
        }
        try {
            const Json value = Json::parse(input);
            parse_snapshot(value, &snapshot_, &pnl_event_ids_);
        } catch (const Json::exception& parse_error) {
            throw PaperError(std::string("corrupt paper-state JSON: ") + parse_error.what());
        }
    } else {
        persist();
    }
    if (std::filesystem::exists(audit_path_)) {
        std::ifstream audit_input(audit_path_, std::ios::binary);
        if (!audit_input) {
            throw PaperError("cannot read append-only paper audit");
        }
        std::string line;
        std::size_t line_number = 0;
        while (std::getline(audit_input, line)) {
            ++line_number;
            if (line.empty()) {
                continue;
            }
            try {
                (void)Json::parse(line);
            } catch (const Json::exception& parse_error) {
                throw PaperError(
                    "corrupt paper audit at line " + std::to_string(line_number) +
                    ": " + parse_error.what());
            }
        }
        if (!audit_input.eof()) {
            throw PaperError("failed while validating append-only paper audit");
        }
    }
    std::ofstream audit(audit_path_, std::ios::app | std::ios::binary);
    if (!audit) {
        throw PaperError("cannot open append-only paper audit");
    }
}

Snapshot FileRepository::load() const {
    return snapshot_;
}

bool FileRepository::claim(const Opportunity& opportunity) {
    const bool inserted = snapshot_.claimed_opportunities.insert(opportunity.id).second;
    if (inserted) {
        snapshot_.pending_opportunities.insert(opportunity.id);
        persist();
    }
    return inserted;
}

void FileRepository::complete_claim(const std::string& opportunity_id) {
    if (snapshot_.pending_opportunities.erase(opportunity_id) != 1) {
        throw PaperError("pending opportunity completion target not found");
    }
    persist();
    append({
        {"type", "opportunity_completed"},
        {"opportunity_id", opportunity_id},
    });
}

void FileRepository::save_position(const PaperPosition& position) {
    const bool duplicate = std::any_of(
        snapshot_.positions.begin(), snapshot_.positions.end(),
        [&](const PaperPosition& current) { return current.id == position.id; });
    if (duplicate) {
        throw PaperError("duplicate position identifier");
    }
    snapshot_.positions.push_back(position);
    persist();
    append({{"type", "position_saved"}, {"position", position_json(position)}});
}

void FileRepository::update_position(const PaperPosition& position) {
    replace_position(&snapshot_.positions, position);
    persist();
    append({{"type", "position_updated"}, {"position", position_json(position)}});
}

void FileRepository::record_pnl(
    const std::string& event_id,
    const std::string& trading_day,
    Decimal amount,
    std::int64_t epoch_ms_value) {
    if (!pnl_event_ids_.insert(event_id).second) {
        return;
    }
    snapshot_.realized_pnl[trading_day] =
        snapshot_.realized_pnl[trading_day] + amount;
    persist();
    append({
        {"type", "realized_pnl"},
        {"event_id", event_id},
        {"trading_day", trading_day},
        {"amount", amount.str()},
        {"cumulative", snapshot_.realized_pnl.at(trading_day).str()},
        {"epoch_ms", epoch_ms_value},
    });
}

void FileRepository::latch_kill(
    std::string reason,
    std::string trading_day,
    std::int64_t epoch_ms_value) {
    if (snapshot_.kill.active) {
        return;
    }
    snapshot_.kill = {
        .active = true,
        .reason = std::move(reason),
        .trading_day = std::move(trading_day),
        .latched_epoch_ms = epoch_ms_value,
    };
    persist();
    append({
        {"type", "kill_switch_latched"},
        {"reason", snapshot_.kill.reason},
        {"trading_day", snapshot_.kill.trading_day},
        {"epoch_ms", epoch_ms_value},
    });
}

void FileRepository::clear_utc_rollover(std::string new_day, std::int64_t epoch_ms_value) {
    if (!snapshot_.kill.active || snapshot_.kill.reason != "daily_loss" ||
        snapshot_.kill.trading_day >= new_day) {
        return;
    }
    const std::string previous_day = snapshot_.kill.trading_day;
    snapshot_.kill = {};
    persist();
    append({
        {"type", "kill_switch_utc_rollover"},
        {"previous_trading_day", previous_day},
        {"new_trading_day", std::move(new_day)},
        {"epoch_ms", epoch_ms_value},
    });
}

void FileRepository::record_event(std::string type, const Json& payload) {
    append({{"type", std::move(type)}, {"payload", payload}});
}

void FileRepository::reconcile(std::int64_t epoch_ms_value) {
    snapshot_.last_reconciliation_epoch_ms = epoch_ms_value;
    persist();
    append({
        {"type", "paper_reconciliation"},
        {"epoch_ms", epoch_ms_value},
        {"claimed_count", snapshot_.claimed_opportunities.size()},
        {"position_count", snapshot_.positions.size()},
    });
}

void FileRepository::persist() {
    const std::filesystem::path temporary = snapshot_path_.string() + ".tmp";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw PaperError("cannot write temporary paper-state snapshot");
        }
        output << snapshot_json(snapshot_, pnl_event_ids_).dump(2) << '\n';
        output.flush();
        if (!output) {
            throw PaperError("failed to flush paper-state snapshot");
        }
    }
#ifdef _WIN32
    if (!MoveFileExW(
            temporary.wstring().c_str(),
            snapshot_path_.wstring().c_str(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        std::filesystem::remove(temporary);
        throw PaperError("failed to atomically replace paper-state snapshot");
    }
#else
    std::error_code error;
    std::filesystem::rename(temporary, snapshot_path_, error);
    if (error) {
        std::filesystem::remove(temporary);
        throw PaperError("failed to atomically replace paper-state snapshot: " + error.message());
    }
#endif
}

void FileRepository::append(const Json& event) {
    std::ofstream output(audit_path_, std::ios::app | std::ios::binary);
    if (!output) {
        throw PaperError("cannot append paper audit event");
    }
    output << event.dump() << '\n';
    output.flush();
    if (!output) {
        throw PaperError("failed to flush paper audit event");
    }
}

void MemoryRepository::initialize() {}

Snapshot MemoryRepository::load() const {
    return snapshot_;
}

bool MemoryRepository::claim(const Opportunity& opportunity) {
    const bool inserted = snapshot_.claimed_opportunities.insert(opportunity.id).second;
    if (inserted) {
        snapshot_.pending_opportunities.insert(opportunity.id);
    }
    return inserted;
}

void MemoryRepository::complete_claim(const std::string& opportunity_id) {
    if (snapshot_.pending_opportunities.erase(opportunity_id) != 1) {
        throw PaperError("pending opportunity completion target not found");
    }
}

void MemoryRepository::save_position(const PaperPosition& position) {
    if (std::any_of(
            snapshot_.positions.begin(), snapshot_.positions.end(),
            [&](const PaperPosition& current) { return current.id == position.id; })) {
        throw PaperError("duplicate position identifier");
    }
    snapshot_.positions.push_back(position);
}

void MemoryRepository::update_position(const PaperPosition& position) {
    replace_position(&snapshot_.positions, position);
}

void MemoryRepository::record_pnl(
    const std::string& event_id,
    const std::string& trading_day,
    Decimal amount,
    std::int64_t epoch_ms_value) {
    if (!pnl_event_ids_.insert(event_id).second) {
        return;
    }
    snapshot_.realized_pnl[trading_day] =
        snapshot_.realized_pnl[trading_day] + amount;
    events_.push_back({
        {"type", "realized_pnl"},
        {"event_id", event_id},
        {"amount", amount.str()},
        {"epoch_ms", epoch_ms_value},
    });
}

void MemoryRepository::latch_kill(
    std::string reason,
    std::string trading_day,
    std::int64_t epoch_ms_value) {
    if (!snapshot_.kill.active) {
        snapshot_.kill = {
            .active = true,
            .reason = std::move(reason),
            .trading_day = std::move(trading_day),
            .latched_epoch_ms = epoch_ms_value,
        };
    }
}

void MemoryRepository::clear_utc_rollover(
    std::string new_day,
    std::int64_t epoch_ms_value) {
    if (snapshot_.kill.active && snapshot_.kill.reason == "daily_loss" &&
        snapshot_.kill.trading_day < new_day) {
        events_.push_back({
            {"type", "kill_switch_utc_rollover"},
            {"new_day", std::move(new_day)},
            {"epoch_ms", epoch_ms_value},
        });
        snapshot_.kill = {};
    }
}

void MemoryRepository::record_event(std::string type, const Json& payload) {
    events_.push_back({{"type", std::move(type)}, {"payload", payload}});
}

void MemoryRepository::reconcile(std::int64_t epoch_ms_value) {
    snapshot_.last_reconciliation_epoch_ms = epoch_ms_value;
}

}  // namespace polymarket::paper
