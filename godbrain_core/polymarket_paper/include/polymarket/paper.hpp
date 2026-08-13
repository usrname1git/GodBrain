#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "json.hpp"

namespace polymarket::paper {

using Json = nlohmann::json;
using TimePoint = std::chrono::system_clock::time_point;

class PaperError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class Decimal {
public:
    static constexpr std::int64_t scale = 1'000'000;

    constexpr Decimal() = default;
    static constexpr Decimal from_raw(std::int64_t raw) { return Decimal(raw); }
    static Decimal parse(std::string_view text, bool round_up = false);

    [[nodiscard]] constexpr std::int64_t raw() const { return raw_; }
    [[nodiscard]] std::string str() const;

    friend constexpr auto operator<=>(const Decimal&, const Decimal&) = default;
    friend Decimal operator+(Decimal left, Decimal right);
    friend Decimal operator-(Decimal left, Decimal right);
    friend Decimal operator*(Decimal left, std::int64_t right);
    friend Decimal operator/(Decimal left, std::int64_t right);

private:
    explicit constexpr Decimal(std::int64_t raw) : raw_(raw) {}
    std::int64_t raw_{0};
};

Decimal multiply_down(Decimal left, Decimal right);
Decimal multiply_up(Decimal left, Decimal right);
Decimal ratio_down(Decimal numerator, Decimal denominator);

struct Level {
    Decimal price;
    Decimal size;
};

struct Book {
    std::string token_id;
    std::string condition_id;
    std::string hash;
    std::int64_t observed_epoch_ms{0};
    std::vector<Level> asks;
    std::vector<Level> bids;
    Decimal tick_size;
    Decimal min_order_size;
};

struct Market {
    std::string id;
    std::string condition_id;
    std::string question;
    std::string yes_token_id;
    std::string no_token_id;
    bool accepting_orders{false};
    bool active{false};
    bool closed{true};
    bool archived{true};
    bool restricted{true};
    bool order_book_enabled{false};
    bool negative_risk{false};
    Decimal tick_size;
    Decimal min_order_size;

    [[nodiscard]] bool supported() const;
};

struct StrategyConfig {
    Decimal max_pair_gross{Decimal::parse("5")};
    Decimal min_net_edge{Decimal::parse("0.02")};
    Decimal fee_rate{Decimal::parse("0.07")};
    std::int64_t slippage_bps_per_leg{50};
    std::int64_t stale_book_ms{2'000};
    std::int64_t settlement_delay_ms{30'000};
};

struct Opportunity {
    std::string id;
    Market market;
    Decimal quantity;
    Decimal yes_cost;
    Decimal no_cost;
    Decimal fee_reserve;
    Decimal slippage_reserve;
    Decimal all_in_cost;
    Decimal merge_value;
    Decimal expected_profit;
    Decimal net_edge;
    std::int64_t evaluated_epoch_ms{0};
    std::string yes_book_hash;
    std::string no_book_hash;
};

struct Evaluation {
    std::optional<Opportunity> opportunity;
    std::string rejection;
};

Evaluation evaluate_pair(
    const Market& market,
    const Book& yes,
    const Book& no,
    std::int64_t now_epoch_ms,
    const StrategyConfig& config);

enum class PublicService { gamma, clob };

class PublicTransport {
public:
    virtual ~PublicTransport() = default;
    virtual Json get(
        PublicService service,
        std::string_view path,
        const std::map<std::string, std::string>& query) = 0;
};

class Clock {
public:
    virtual ~Clock() = default;
    [[nodiscard]] virtual TimePoint now() const = 0;
};

class SystemClock final : public Clock {
public:
    [[nodiscard]] TimePoint now() const override;
};

struct DiscoveryConfig {
    std::size_t page_size{50};
    std::size_t max_pages{1};
};

class PublicApi {
public:
    PublicApi(PublicTransport& transport, DiscoveryConfig config);
    std::vector<Market> discover_binary_markets();
    Book order_book(const std::string& token_id);

private:
    PublicTransport& transport_;
    DiscoveryConfig config_;
};

struct Config {
    static constexpr std::int64_t hard_pair_micros = 5 * Decimal::scale;
    static constexpr std::int64_t hard_total_micros = 10 * Decimal::scale;
    static constexpr std::int64_t hard_daily_loss_micros = 5 * Decimal::scale;

    Decimal max_pair_gross{Decimal::parse("5")};
    Decimal max_total_exposure{Decimal::parse("10")};
    Decimal max_daily_loss{Decimal::parse("5")};
    StrategyConfig strategy;
    DiscoveryConfig discovery;
    std::int64_t scan_interval_ms{3'000};
    std::filesystem::path state_directory{"polymarket-paper-state"};
    std::optional<std::filesystem::path> kill_switch_file;
    bool startup_kill{false};

    static Config from_environment();
    void validate() const;
};

enum class PositionState { paired, stranded, recovered, merged };

struct PaperPosition {
    std::string id;
    std::string opportunity_id;
    std::string market_id;
    std::string condition_id;
    Decimal quantity;
    Decimal acquisition_cost;
    Decimal yes_quantity;
    Decimal no_quantity;
    std::int64_t opened_epoch_ms{0};
    std::int64_t settle_after_epoch_ms{0};
    PositionState state{PositionState::paired};
};

struct KillSwitch {
    bool active{false};
    std::string reason;
    std::string trading_day;
    std::int64_t latched_epoch_ms{0};
};

struct Snapshot {
    std::set<std::string> claimed_opportunities;
    std::set<std::string> pending_opportunities;
    std::vector<PaperPosition> positions;
    std::map<std::string, Decimal> realized_pnl;
    KillSwitch kill;
    std::int64_t last_reconciliation_epoch_ms{0};
};

class Repository {
public:
    virtual ~Repository() = default;
    virtual void initialize() = 0;
    [[nodiscard]] virtual Snapshot load() const = 0;
    virtual bool claim(const Opportunity& opportunity) = 0;
    virtual void complete_claim(const std::string& opportunity_id) = 0;
    virtual void save_position(const PaperPosition& position) = 0;
    virtual void update_position(const PaperPosition& position) = 0;
    virtual void record_pnl(
        const std::string& event_id,
        const std::string& trading_day,
        Decimal amount,
        std::int64_t epoch_ms) = 0;
    virtual void latch_kill(
        std::string reason,
        std::string trading_day,
        std::int64_t epoch_ms) = 0;
    virtual void clear_utc_rollover(std::string new_day, std::int64_t epoch_ms) = 0;
    virtual void record_event(std::string type, const Json& payload) = 0;
    virtual void reconcile(std::int64_t epoch_ms) = 0;
};

class FileRepository final : public Repository {
public:
    explicit FileRepository(std::filesystem::path directory);
    void initialize() override;
    [[nodiscard]] Snapshot load() const override;
    bool claim(const Opportunity& opportunity) override;
    void complete_claim(const std::string& opportunity_id) override;
    void save_position(const PaperPosition& position) override;
    void update_position(const PaperPosition& position) override;
    void record_pnl(
        const std::string& event_id,
        const std::string& trading_day,
        Decimal amount,
        std::int64_t epoch_ms) override;
    void latch_kill(
        std::string reason,
        std::string trading_day,
        std::int64_t epoch_ms) override;
    void clear_utc_rollover(std::string new_day, std::int64_t epoch_ms) override;
    void record_event(std::string type, const Json& payload) override;
    void reconcile(std::int64_t epoch_ms) override;

private:
    void persist();
    void append(const Json& event);
    std::filesystem::path directory_;
    std::filesystem::path snapshot_path_;
    std::filesystem::path audit_path_;
    Snapshot snapshot_;
    std::set<std::string> pnl_event_ids_;
};

class MemoryRepository final : public Repository {
public:
    void initialize() override;
    [[nodiscard]] Snapshot load() const override;
    bool claim(const Opportunity& opportunity) override;
    void complete_claim(const std::string& opportunity_id) override;
    void save_position(const PaperPosition& position) override;
    void update_position(const PaperPosition& position) override;
    void record_pnl(
        const std::string& event_id,
        const std::string& trading_day,
        Decimal amount,
        std::int64_t epoch_ms) override;
    void latch_kill(
        std::string reason,
        std::string trading_day,
        std::int64_t epoch_ms) override;
    void clear_utc_rollover(std::string new_day, std::int64_t epoch_ms) override;
    void record_event(std::string type, const Json& payload) override;
    void reconcile(std::int64_t epoch_ms) override;
    [[nodiscard]] const std::vector<Json>& events() const { return events_; }

private:
    Snapshot snapshot_;
    std::set<std::string> pnl_event_ids_;
    std::vector<Json> events_;
};

struct SimulatedFill {
    Decimal quantity;
    Decimal notional;
    Decimal fee;
    bool complete{false};
    std::string reason;
};

class FillModel {
public:
    virtual ~FillModel() = default;
    virtual SimulatedFill buy(
        const Book& fresh_book,
        Decimal requested,
        Decimal fee_rate,
        std::int64_t slippage_bps) = 0;
    virtual SimulatedFill sell(
        const Book& fresh_book,
        Decimal requested,
        Decimal fee_rate,
        std::int64_t slippage_bps) = 0;
};

class ConservativeFillModel final : public FillModel {
public:
    SimulatedFill buy(
        const Book& fresh_book,
        Decimal requested,
        Decimal fee_rate,
        std::int64_t slippage_bps) override;
    SimulatedFill sell(
        const Book& fresh_book,
        Decimal requested,
        Decimal fee_rate,
        std::int64_t slippage_bps) override;
};

struct Health {
    std::string mode{"paper-only"};
    bool scanning{false};
    bool data_fresh{false};
    bool reconciliation_ok{false};
    Decimal exposure;
    Decimal realized_pnl;
    Decimal unrealized_pnl;
    KillSwitch kill;
    std::string last_error;
    std::int64_t updated_epoch_ms{0};
};

class PaperEngine {
public:
    PaperEngine(
        Config config,
        PublicApi& api,
        Repository& repository,
        FillModel& fill_model,
        Clock& clock);

    void initialize();
    void scan_once();
    [[nodiscard]] Health health() const;

private:
    void settle_due(std::int64_t now_ms, const std::string& day);
    void simulate(const Opportunity& opportunity, std::int64_t now_ms, const std::string& day);
    void refresh_health(std::int64_t now_ms);
    [[nodiscard]] Decimal exposure(const Snapshot& snapshot) const;
    [[nodiscard]] std::string utc_day(std::int64_t epoch_ms) const;

    Config config_;
    PublicApi& api_;
    Repository& repository_;
    FillModel& fill_model_;
    Clock& clock_;
    Health health_;
    bool initialized_{false};
};

Json health_json(const Health& health);
std::int64_t epoch_ms(TimePoint point);
std::string position_state_name(PositionState state);
PositionState parse_position_state(std::string_view state);

class WinHttpPublicTransport final : public PublicTransport {
public:
    Json get(
        PublicService service,
        std::string_view path,
        const std::map<std::string, std::string>& query) override;
};

}  // namespace polymarket::paper
