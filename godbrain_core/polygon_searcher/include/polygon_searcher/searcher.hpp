#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "json.hpp"

namespace godbrain::polygon {

using Json = nlohmann::json;
using Amount = std::uint64_t;

class SearcherError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

enum class BlockStatus { confirmed, pending, unknown, reorged };

struct BlockContext {
    std::uint64_t number{0};
    std::string hash;
    std::string parent_hash;
    BlockStatus status{BlockStatus::unknown};
    std::int64_t observed_epoch_ms{0};

    friend bool operator==(const BlockContext&, const BlockContext&) = default;
};

struct Token {
    std::string id;
    std::string symbol;
    std::uint8_t decimals{0};
};

struct Venue {
    std::string id;
    std::string protocol;
};

struct Route {
    std::string id;
    std::string venue_id;
    std::string token_in;
    std::string token_out;

    friend bool operator==(const Route&, const Route&) = default;
};

struct QuoteRequest {
    Route route;
    Amount amount_in{0};
    BlockContext block;
};

struct ExactInputQuote {
    Route route;
    Amount amount_in{0};
    Amount amount_out{0};
    Amount max_supported_input{0};
    std::uint32_t confidence_bps{0};
    BlockContext block;
    std::int64_t observed_epoch_ms{0};
    std::string provider;
    std::string provenance;
    std::string quote_hash;
};

struct CostRequest {
    Route first;
    Route second;
    Token input_token;
    Amount amount_in{0};
    BlockContext block;
};

struct GasCostQuote {
    BlockContext block;
    std::uint64_t gas_units{0};
    Amount native_wei{0};
    Amount input_token_cost{0};
    std::int64_t observed_epoch_ms{0};
    std::string conversion_provenance;
    std::string quote_hash;
};

class BlockProvider {
public:
    virtual ~BlockProvider() = default;
    [[nodiscard]] virtual BlockContext current() = 0;
    [[nodiscard]] virtual bool is_canonical(const BlockContext& block) = 0;
};

class TokenMetadataProvider {
public:
    virtual ~TokenMetadataProvider() = default;
    [[nodiscard]] virtual Token get(std::string_view token_id) = 0;
};

class ExactInputQuoteProvider {
public:
    virtual ~ExactInputQuoteProvider() = default;
    [[nodiscard]] virtual ExactInputQuote quote(const QuoteRequest& request) = 0;
};

class GasCostProvider {
public:
    virtual ~GasCostProvider() = default;
    [[nodiscard]] virtual GasCostQuote estimate(const CostRequest& request) = 0;
};

class Clock {
public:
    virtual ~Clock() = default;
    [[nodiscard]] virtual std::int64_t now_epoch_ms() const = 0;
};

struct CostBreakdown {
    Amount gas{0};
    Amount atlas_bid_reserve{0};
    Amount safety_margin{0};
    Amount adverse_slippage{0};
    Amount execution_failure_reserve{0};

    [[nodiscard]] Amount total() const;
};

struct ArbitragePlan {
    std::uint32_t schema_version{1};
    std::string id;
    BlockContext block;
    Token input_token;
    Token intermediate_token;
    Route first;
    Route second;
    Amount amount_in{0};
    Amount first_quote_out{0};
    Amount gross_amount_out{0};
    Amount gross_profit{0};
    CostBreakdown costs;
    std::int64_t expected_net{0};
    std::uint32_t net_edge_bps{0};
    std::int64_t created_epoch_ms{0};
    std::int64_t deadline_epoch_ms{0};
    std::string first_quote_provider;
    std::string first_quote_provenance;
    std::string first_quote_hash;
    std::int64_t first_quote_observed_epoch_ms{0};
    std::string second_quote_provider;
    std::string second_quote_provenance;
    std::string second_quote_hash;
    std::int64_t second_quote_observed_epoch_ms{0};
    std::string gas_conversion_provenance;
    std::string gas_quote_hash;
    std::int64_t gas_quote_observed_epoch_ms{0};
    std::uint32_t min_confidence_bps{0};
    std::uint64_t max_gas_units{0};
};

struct Decision {
    std::optional<ArbitragePlan> plan;
    std::string reason;
    std::string route_pair;
    Amount amount_in{0};
};

struct PaperResult {
    std::string plan_id;
    bool first_leg_filled{false};
    bool second_leg_filled{false};
    bool atomic{false};
    Amount final_amount{0};
    std::int64_t realized_pnl{0};
    std::int64_t settled_epoch_ms{0};
    std::string incident;
};

class PaperExecutor {
public:
    virtual ~PaperExecutor() = default;
    [[nodiscard]] virtual PaperResult execute(const ArbitragePlan& plan) = 0;
};

struct KillLatch {
    bool active{false};
    std::string reason;
    std::int64_t latched_epoch_ms{0};
};

struct SearcherSnapshot {
    std::set<std::string> claimed_plan_ids;
    std::set<std::string> pending_plan_ids;
    std::map<std::string, std::int64_t> daily_pnl;
    KillLatch kill;
    std::int64_t reconciled_epoch_ms{0};
};

class AuditStore {
public:
    virtual ~AuditStore() = default;
    virtual void initialize(std::int64_t now_epoch_ms) = 0;
    [[nodiscard]] virtual SearcherSnapshot load() const = 0;
    virtual void record_decision(const Decision& decision, const BlockContext& block) = 0;
    [[nodiscard]] virtual bool claim(const ArbitragePlan& plan) = 0;
    virtual void complete(const std::string& plan_id) = 0;
    virtual void record_paper_result(
        const PaperResult& result,
        std::string_view trading_day,
        std::string_view token_id) = 0;
    virtual void record_incident(
        std::string reason,
        std::string plan_id,
        std::int64_t epoch_ms) = 0;
    virtual void latch_kill(std::string reason, std::int64_t epoch_ms) = 0;
};

class FileAuditStore final : public AuditStore {
public:
    explicit FileAuditStore(std::filesystem::path directory);
    void initialize(std::int64_t now_epoch_ms) override;
    [[nodiscard]] SearcherSnapshot load() const override;
    void record_decision(const Decision& decision, const BlockContext& block) override;
    [[nodiscard]] bool claim(const ArbitragePlan& plan) override;
    void complete(const std::string& plan_id) override;
    void record_paper_result(
        const PaperResult& result,
        std::string_view trading_day,
        std::string_view token_id) override;
    void record_incident(
        std::string reason,
        std::string plan_id,
        std::int64_t epoch_ms) override;
    void latch_kill(std::string reason, std::int64_t epoch_ms) override;

private:
    void ensure_initialized() const;
    void persist();
    void append(const Json& event);

    std::filesystem::path directory_;
    std::filesystem::path snapshot_path_;
    std::filesystem::path audit_path_;
    SearcherSnapshot snapshot_;
    bool initialized_{false};
};

struct SearchConfig {
    static constexpr std::uint8_t hard_max_token_decimals = 18;
    static constexpr std::size_t hard_max_input_sizes = 32;
    static constexpr std::size_t hard_max_routes = 128;
    static constexpr std::size_t hard_max_candidates_per_block = 256;
    static constexpr std::uint64_t hard_max_gas_units = 1'000'000;
    static constexpr std::int64_t hard_max_quote_age_ms = 3'000;
    static constexpr std::uint32_t hard_max_slippage_bps_per_leg = 200;
    static constexpr std::uint32_t hard_max_safety_bps = 200;
    static constexpr std::uint32_t hard_max_failure_reserve_bps = 200;
    static constexpr std::uint32_t hard_max_bid_reserve_bps = 5'000;
    static constexpr std::uint32_t hard_min_net_edge_bps = 1;
    static constexpr Amount hard_max_whole_tokens = 10;
    static constexpr Amount hard_max_daily_loss_whole_tokens = 2;

    std::size_t max_routes{32};
    std::size_t max_candidates_per_block{64};
    std::uint64_t max_gas_units{350'000};
    std::int64_t max_quote_age_ms{1'000};
    std::int64_t max_block_age_ms{1'500};
    std::int64_t plan_ttl_ms{750};
    std::uint32_t min_confidence_bps{9'500};
    std::uint32_t min_net_edge_bps{50};
    std::uint32_t slippage_bps_per_leg{25};
    std::uint32_t safety_margin_bps{30};
    std::uint32_t execution_failure_reserve_bps{25};
    std::uint32_t atlas_bid_reserve_bps{2'000};
    std::set<std::string> allowed_tokens;
    std::set<std::string> allowed_venues;
    std::map<std::string, Amount> max_input_by_token;
    std::map<std::string, Amount> daily_loss_limit_by_token;
    bool emergency_kill{false};

    void validate(const std::map<std::string, Token>& tokens) const;
};

struct SearchResult {
    BlockContext block;
    std::vector<Decision> decisions;
    std::optional<ArbitragePlan> selected_plan;
    std::optional<PaperResult> paper_result;
};

class Searcher {
public:
    Searcher(
        BlockProvider& blocks,
        TokenMetadataProvider& tokens,
        ExactInputQuoteProvider& quotes,
        GasCostProvider& costs,
        Clock& clock,
        AuditStore& audit,
        PaperExecutor& executor,
        SearchConfig config);

    [[nodiscard]] SearchResult scan(
        std::vector<Route> routes,
        std::map<std::string, std::vector<Amount>> input_sizes);

private:
    [[nodiscard]] Decision evaluate(
        const Route& first,
        const Route& second,
        Amount amount_in,
        const BlockContext& block,
        const std::map<std::string, Token>& token_metadata);

    BlockProvider& blocks_;
    TokenMetadataProvider& tokens_;
    ExactInputQuoteProvider& quotes_;
    GasCostProvider& costs_;
    Clock& clock_;
    AuditStore& audit_;
    PaperExecutor& executor_;
    SearchConfig config_;
    std::mutex cycle_mutex_;
};

[[nodiscard]] Json plan_json(const ArbitragePlan& plan);
[[nodiscard]] Json decision_json(const Decision& decision);
[[nodiscard]] Json paper_result_json(const PaperResult& result);
[[nodiscard]] std::string deterministic_plan_id(const ArbitragePlan& plan);
[[nodiscard]] std::string utc_day(std::int64_t epoch_ms);
[[nodiscard]] Amount token_whole_limit(const Token& token, Amount whole_tokens);

}  // namespace godbrain::polygon
