#include "polymarket/paper.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <queue>
#include <stdexcept>
#include <string>
#include <type_traits>

using namespace polymarket::paper;

namespace {

constexpr std::int64_t fixture_ms = 1'786'593'600'000LL;
int failures = 0;

#define CHECK(expression) \
    do { \
        if (!(expression)) { \
            throw std::runtime_error( \
                std::string("CHECK failed at line ") + std::to_string(__LINE__) + \
                ": " #expression); \
        } \
    } while (false)

template <typename Function>
void expect_throw(Function&& function) {
    bool threw = false;
    try {
        function();
    } catch (const std::exception&) {
        threw = true;
    }
    CHECK(threw);
}

void run(const char* name, const std::function<void()>& test) {
    try {
        test();
        std::cout << "[PASS] " << name << '\n';
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "[FAIL] " << name << ": " << error.what() << '\n';
    }
}

Json load_fixture(const std::string& name) {
    const auto path =
        std::filesystem::path(__FILE__).parent_path() / "fixtures" / name;
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open fixture: " + path.string());
    }
    return Json::parse(input);
}

Market market() {
    return {
        .id = "1001",
        .condition_id = "0xcondition",
        .question = "Fixture?",
        .yes_token_id = "111",
        .no_token_id = "222",
        .accepting_orders = true,
        .active = true,
        .closed = false,
        .archived = false,
        .restricted = false,
        .order_book_enabled = true,
        .negative_risk = false,
        .tick_size = Decimal::parse("0.000001"),
        .min_order_size = Decimal::parse("1"),
    };
}

Book book(
    std::string token,
    std::string hash,
    std::string ask,
    std::string bid = "0.4",
    std::string size = "10",
    std::int64_t timestamp = fixture_ms) {
    return {
        .token_id = std::move(token),
        .condition_id = "0xcondition",
        .hash = std::move(hash),
        .observed_epoch_ms = timestamp,
        .asks = {{Decimal::parse(ask), Decimal::parse(size)}},
        .bids = {{Decimal::parse(bid), Decimal::parse(size)}},
        .tick_size = Decimal::parse("0.000001"),
        .min_order_size = Decimal::parse("1"),
    };
}

class FakeClock final : public Clock {
public:
    explicit FakeClock(std::int64_t milliseconds)
        : now_(TimePoint(std::chrono::milliseconds(milliseconds))) {}

    TimePoint now() const override { return now_; }
    void set(std::int64_t milliseconds) {
        now_ = TimePoint(std::chrono::milliseconds(milliseconds));
    }

private:
    TimePoint now_;
};

class FakeTransport final : public PublicTransport {
public:
    Json gamma = Json::array();
    std::map<std::string, Json> books;
    std::size_t gamma_calls{0};
    std::size_t book_calls{0};
    std::vector<std::string> cursors;

    Json get(
        PublicService service,
        std::string_view path,
        const std::map<std::string, std::string>& query) override {
        CHECK(path == (service == PublicService::gamma ? "/markets/keyset" : "/book"));
        if (service == PublicService::gamma) {
            ++gamma_calls;
            const auto cursor = query.find("after_cursor");
            cursors.push_back(cursor == query.end() ? "" : cursor->second);
            return Json{{"markets", gamma}};
        }
        ++book_calls;
        return books.at(query.at("token_id"));
    }
};

class PagedTransport final : public PublicTransport {
public:
    std::queue<Json> pages;
    std::size_t calls{0};

    Json get(
        PublicService service,
        std::string_view,
        const std::map<std::string, std::string>&) override {
        CHECK(service == PublicService::gamma);
        ++calls;
        Json result = pages.front();
        pages.pop();
        return result;
    }
};

class ScriptedFillModel final : public FillModel {
public:
    std::queue<SimulatedFill> buys;
    std::queue<SimulatedFill> sells;

    SimulatedFill buy(const Book&, Decimal, Decimal, std::int64_t) override {
        SimulatedFill result = buys.front();
        buys.pop();
        return result;
    }
    SimulatedFill sell(const Book&, Decimal, Decimal, std::int64_t) override {
        SimulatedFill result = sells.front();
        sells.pop();
        return result;
    }
};

template <typename T>
concept HasPost = requires(T& value) {
    value.post("/orders", Json::object());
};

static_assert(!HasPost<PublicTransport>);
static_assert(!HasPost<WinHttpPublicTransport>);

Config base_config() {
    Config config;
    config.strategy.fee_rate = Decimal::parse("0");
    config.strategy.slippage_bps_per_leg = 0;
    config.strategy.settlement_delay_ms = 60'000;
    config.discovery.page_size = 50;
    config.discovery.max_pages = 1;
    config.validate();
    return config;
}

FakeTransport profitable_transport() {
    FakeTransport transport;
    transport.gamma = load_fixture("gamma_markets.json");
    transport.books["111"] = load_fixture("book_yes.json");
    transport.books["222"] = load_fixture("book_no.json");
    return transport;
}

Opportunity opportunity_for(std::string id = "opportunity") {
    return {
        .id = std::move(id),
        .market = market(),
        .quantity = Decimal::parse("2"),
        .yes_cost = Decimal::parse("0.8"),
        .no_cost = Decimal::parse("0.8"),
        .fee_reserve = Decimal::parse("0"),
        .slippage_reserve = Decimal::parse("0"),
        .all_in_cost = Decimal::parse("1.6"),
        .merge_value = Decimal::parse("2"),
        .expected_profit = Decimal::parse("0.4"),
        .net_edge = Decimal::parse("0.25"),
        .evaluated_epoch_ms = fixture_ms,
        .yes_book_hash = "yes",
        .no_book_hash = "no",
    };
}

void decimal_is_exact() {
    CHECK(Decimal::parse("1.234567").raw() == 1'234'567);
    CHECK(Decimal::parse("0.0000009").raw() == 0);
    CHECK(Decimal::parse("0.0000009", true).raw() == 1);
    CHECK((Decimal::parse("2") - Decimal::parse("0.5")).str() == "1.5");
    CHECK((Decimal::parse("-2") * -5) == Decimal::parse("10"));
    CHECK(multiply_down(Decimal::parse("-2"), Decimal::parse("0.5")) ==
        Decimal::parse("-1"));
    expect_throw([] { (void)Decimal::parse("nan"); });
}

void exact_two_percent_boundary() {
    StrategyConfig config;
    config.fee_rate = Decimal::parse("0");
    config.slippage_bps_per_leg = 0;
    config.max_pair_gross = Decimal::parse("0.980392");
    config.min_net_edge = Decimal::parse("0.02");
    const auto accepted = evaluate_pair(
        market(),
        book("111", "yes-a", "0.49"),
        book("222", "no-a", "0.490392"),
        fixture_ms,
        config);
    CHECK(accepted.opportunity.has_value());
    CHECK(accepted.opportunity->net_edge == Decimal::parse("0.02"));

    config.max_pair_gross = Decimal::parse("0.980393");
    const auto rejected = evaluate_pair(
        market(),
        book("111", "yes-b", "0.49"),
        book("222", "no-b", "0.490393"),
        fixture_ms,
        config);
    CHECK(!rejected.opportunity.has_value());
    CHECK(rejected.rejection == "edge_below_threshold");
}

void walks_depth_and_reserves_costs() {
    StrategyConfig config;
    config.fee_rate = Decimal::parse("0.07");
    config.slippage_bps_per_leg = 50;
    config.max_pair_gross = Decimal::parse("5");
    Book yes = book("111", "yes", "0.4");
    yes.asks = {
        {Decimal::parse("0.4"), Decimal::parse("1")},
        {Decimal::parse("0.5"), Decimal::parse("2")},
    };
    Book no = book("222", "no", "0.4");
    no.asks = {{Decimal::parse("0.4"), Decimal::parse("3")}};
    const auto evaluated = evaluate_pair(market(), yes, no, fixture_ms, config);
    CHECK(evaluated.opportunity.has_value());
    const Opportunity& value = *evaluated.opportunity;
    CHECK(value.quantity == Decimal::parse("3"));
    CHECK(value.yes_cost == Decimal::parse("1.4"));
    CHECK(value.no_cost == Decimal::parse("1.2"));
    CHECK(value.fee_reserve == Decimal::parse("0.1022"));
    CHECK(value.slippage_reserve == Decimal::parse("0.013"));
    CHECK(value.all_in_cost == Decimal::parse("2.7152"));
}

void stale_and_constraints_reject() {
    StrategyConfig config;
    const auto stale = evaluate_pair(
        market(),
        book("111", "yes", "0.4", "0.3", "10", fixture_ms - 2'001),
        book("222", "no", "0.4"),
        fixture_ms,
        config);
    CHECK(stale.rejection == "stale_book");

    Book changed = book("111", "yes", "0.4");
    changed.tick_size = Decimal::parse("0.01");
    const auto mismatch = evaluate_pair(
        market(), changed, book("222", "no", "0.4"), fixture_ms, config);
    CHECK(mismatch.rejection == "market_constraints_changed");
}

void hard_caps_cannot_be_raised() {
    Config config;
    config.max_pair_gross = Decimal::parse("5.000001");
    config.strategy.max_pair_gross = config.max_pair_gross;
    expect_throw([&] { config.validate(); });
    config = Config{};
    config.max_total_exposure = Decimal::parse("10.000001");
    expect_throw([&] { config.validate(); });
    config = Config{};
    config.max_daily_loss = Decimal::parse("5.000001");
    expect_throw([&] { config.validate(); });
    config = Config{};
    config.discovery.page_size = 100;
    config.discovery.max_pages = 20;
    config.scan_interval_ms = 1'000;
    expect_throw([&] { config.validate(); });
}

void strategy_enforces_pair_cap() {
    StrategyConfig config;
    config.fee_rate = Decimal::parse("0");
    config.slippage_bps_per_leg = 0;
    config.max_pair_gross = Decimal::parse("5");
    const auto result = evaluate_pair(
        market(),
        book("111", "yes-cap", "0.4", "0.3", "100"),
        book("222", "no-cap", "0.4", "0.3", "100"),
        fixture_ms,
        config);
    CHECK(result.opportunity.has_value());
    CHECK(result.opportunity->all_in_cost <= Decimal::parse("5"));
    CHECK(result.opportunity->quantity == Decimal::parse("6.25"));
}

void parses_fixture_and_bounds_pagination() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 4});
    const auto markets = api.discover_binary_markets();
    CHECK(markets.size() == 1);
    CHECK(markets.front().yes_token_id == "111");
    CHECK(markets.front().no_token_id == "222");
    const Book yes = api.order_book("111");
    CHECK(yes.asks.front().price == Decimal::parse("0.49"));
    CHECK(yes.observed_epoch_ms == fixture_ms);
    transport.books["111"]["asks"] = Json::array({
        Json{{"price", "0.50"}, {"size", "2"}},
        Json{{"price", "0.49"}, {"size", "1"}},
    });
    CHECK(api.order_book("111").asks.front().price == Decimal::parse("0.49"));

    Json full_page = Json::array();
    for (int index = 0; index < 2; ++index) {
        Json item = load_fixture("gamma_markets.json").front();
        item["id"] = std::to_string(index + 1);
        full_page.push_back(item);
    }
    PagedTransport paged;
    paged.pages.push(Json{{"markets", full_page}, {"next_cursor", "cursor-1"}});
    paged.pages.push(Json{{"markets", full_page}});
    PublicApi bounded(paged, {.page_size = 2, .max_pages = 2});
    CHECK(bounded.discover_binary_markets().size() == 4);
    CHECK(paged.calls == 2);
}

void malformed_payloads_fail_closed() {
    FakeTransport transport;
    transport.gamma = Json::object();
    PublicApi api(transport, {.page_size = 10, .max_pages = 1});
    expect_throw([&] { (void)api.discover_binary_markets(); });

    transport.gamma = load_fixture("gamma_markets.json");
    transport.books["111"] = load_fixture("book_yes.json");
    transport.books["111"]["timestamp"] = "not-a-time";
    expect_throw([&] { (void)api.order_book("111"); });
    transport.books["111"] = load_fixture("book_yes.json");
    transport.books["111"]["tick_size"] = "0.01";
    transport.books["111"]["asks"][0]["price"] = "0.491";
    expect_throw([&] { (void)api.order_book("111"); });
    expect_throw([&] { (void)api.order_book("../private"); });
}

void engine_resnapshots_before_each_leg() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ConservativeFillModel fills;
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(transport.book_calls == 4);
    CHECK(repository.load().positions.size() == 1);
}

void fresh_fill_cannot_breach_pair_or_total_cap() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ScriptedFillModel fills;
    fills.buys.push({
        .quantity = Decimal::parse("5"),
        .notional = Decimal::parse("6"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "moved",
    });
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(repository.load().positions.empty());
    CHECK(repository.load().pending_opportunities.empty());
    CHECK(engine.health().exposure == Decimal::parse("0"));
}

void second_leg_cap_breach_recovers_first_leg() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ScriptedFillModel fills;
    fills.buys.push({
        .quantity = Decimal::parse("5"),
        .notional = Decimal::parse("2"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "filled",
    });
    fills.buys.push({
        .quantity = Decimal::parse("5"),
        .notional = Decimal::parse("4"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "moved",
    });
    fills.sells.push({
        .quantity = Decimal::parse("5"),
        .notional = Decimal::parse("1.9"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "recovered",
    });
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(repository.load().positions.empty());
    CHECK(repository.load().kill.active);
    CHECK(repository.load().realized_pnl.at("2026-08-13") == Decimal::parse("-0.1"));
}

void duplicate_restart_is_idempotent() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ConservativeFillModel fills;
    FakeClock clock(fixture_ms);
    Config config = base_config();
    PaperEngine engine(config, api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(repository.load().positions.size() == 1);
    engine.scan_once();
    CHECK(repository.load().positions.size() == 1);
    CHECK(repository.load().claimed_opportunities.size() == 1);
}

void total_exposure_rejects_pair() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    repository.initialize();
    repository.save_position({
        .id = "existing",
        .opportunity_id = "existing-opportunity",
        .market_id = "existing-market",
        .condition_id = "existing-condition",
        .quantity = Decimal::parse("6"),
        .acquisition_cost = Decimal::parse("6"),
        .yes_quantity = Decimal::parse("6"),
        .no_quantity = Decimal::parse("6"),
        .opened_epoch_ms = fixture_ms,
        .settle_after_epoch_ms = fixture_ms + 100'000,
        .state = PositionState::paired,
    });
    ConservativeFillModel fills;
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(repository.load().positions.size() == 1);
    CHECK(repository.load().claimed_opportunities.empty());
}

void partial_second_leg_recovers_and_latches() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ScriptedFillModel fills;
    fills.buys.push({
        .quantity = Decimal::parse("5"),
        .notional = Decimal::parse("2.45"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "filled",
    });
    fills.buys.push({
        .quantity = Decimal::parse("2"),
        .notional = Decimal::parse("0.96"),
        .fee = Decimal::parse("0"),
        .complete = false,
        .reason = "partial",
    });
    fills.sells.push({
        .quantity = Decimal::parse("3"),
        .notional = Decimal::parse("1.41"),
        .fee = Decimal::parse("0"),
        .complete = true,
        .reason = "recovered",
    });
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    const Snapshot snapshot = repository.load();
    CHECK(snapshot.kill.active);
    CHECK(snapshot.kill.reason == "non_atomic_leg_failure");
    CHECK(snapshot.positions.size() == 1);
    CHECK(snapshot.positions.front().state == PositionState::paired);
    CHECK(snapshot.positions.front().quantity == Decimal::parse("2"));
    CHECK(snapshot.realized_pnl.at("2026-08-13") == Decimal::parse("-0.06"));
}

void partial_first_leg_recovers_and_latches() {
    FakeTransport transport = profitable_transport();
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ScriptedFillModel fills;
    fills.buys.push({
        .quantity = Decimal::parse("2"),
        .notional = Decimal::parse("0.98"),
        .fee = Decimal::parse("0"),
        .complete = false,
        .reason = "partial",
    });
    fills.sells.push({
        .quantity = Decimal::parse("1"),
        .notional = Decimal::parse("0.47"),
        .fee = Decimal::parse("0"),
        .complete = false,
        .reason = "partial_recovery",
    });
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    const Snapshot snapshot = repository.load();
    CHECK(snapshot.kill.active);
    CHECK(snapshot.positions.size() == 1);
    CHECK(snapshot.positions.front().state == PositionState::stranded);
    CHECK(snapshot.positions.front().quantity == Decimal::parse("1"));
    CHECK(snapshot.realized_pnl.at("2026-08-13") == Decimal::parse("-0.02"));
}

void daily_loss_latches_and_rolls_utc() {
    FakeTransport transport;
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    repository.initialize();
    repository.record_pnl(
        "loss", "2026-08-13", Decimal::parse("-5"), fixture_ms);
    ConservativeFillModel fills;
    FakeClock clock(fixture_ms);
    PaperEngine engine(base_config(), api, repository, fills, clock);
    engine.initialize();
    engine.scan_once();
    CHECK(repository.load().kill.active);
    CHECK(repository.load().kill.reason == "daily_loss");

    clock.set(fixture_ms + 86'400'000);
    engine.scan_once();
    CHECK(!repository.load().kill.active);
}

void file_repository_detects_corruption_and_persists_ids() {
    const auto root = std::filesystem::temp_directory_path() /
        ("godbrain-paper-test-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(root);
    {
        std::ofstream output(root / "snapshot.json");
        output << "{broken";
    }
    expect_throw([&] {
        FileRepository corrupt(root);
        corrupt.initialize();
    });
    std::filesystem::remove_all(root);

    const auto durable = root.string() + "-durable";
    {
        FileRepository first(durable);
        first.initialize();
        CHECK(first.claim(opportunity_for()));
        first.record_pnl("pnl-id", "2026-08-13", Decimal::parse("0.1"), fixture_ms);
    }
    {
        FileRepository restarted(durable);
        restarted.initialize();
        CHECK(!restarted.claim(opportunity_for()));
        restarted.record_pnl(
            "pnl-id", "2026-08-13", Decimal::parse("0.1"), fixture_ms);
        CHECK(restarted.load().realized_pnl.at("2026-08-13") == Decimal::parse("0.1"));
    }
    {
        std::ofstream output(std::filesystem::path(durable) / "audit.jsonl", std::ios::app);
        output << "{broken-audit\n";
    }
    expect_throw([&] {
        FileRepository corrupt_audit(durable);
        corrupt_audit.initialize();
    });
    std::filesystem::remove_all(durable);

    const auto blocked_path = root.string() + "-not-a-directory";
    {
        std::ofstream output(blocked_path);
        output << "file";
    }
    expect_throw([&] {
        FileRepository unavailable(blocked_path);
        unavailable.initialize();
    });
    std::filesystem::remove(blocked_path);
}

void operator_file_kill_is_latched() {
    const auto kill_file = std::filesystem::temp_directory_path() /
        ("godbrain-paper-kill-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    {
        std::ofstream output(kill_file);
        output << "stop\n";
    }
    Config config = base_config();
    config.kill_switch_file = kill_file;
    FakeTransport transport;
    PublicApi api(transport, {.page_size = 50, .max_pages = 1});
    MemoryRepository repository;
    ConservativeFillModel fills;
    FakeClock clock(fixture_ms);
    PaperEngine engine(config, api, repository, fills, clock);
    engine.initialize();
    CHECK(repository.load().kill.active);
    CHECK(repository.load().kill.reason == "operator");
    std::filesystem::remove(kill_file);
}

void interrupted_claim_latches_on_restart() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("godbrain-paper-pending-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    {
        FileRepository first(directory);
        first.initialize();
        CHECK(first.claim(opportunity_for("pending-opportunity")));
        CHECK(first.load().pending_opportunities.contains("pending-opportunity"));
    }
    {
        FileRepository restarted(directory);
        FakeTransport transport;
        PublicApi api(transport, {.page_size = 50, .max_pages = 1});
        ConservativeFillModel fills;
        FakeClock clock(fixture_ms);
        PaperEngine engine(base_config(), api, restarted, fills, clock);
        engine.initialize();
        CHECK(restarted.load().kill.active);
        CHECK(restarted.load().kill.reason == "reconciliation_failure");
    }
    std::filesystem::remove_all(directory);
}

void reporting_is_deterministic_and_paper_only() {
    Health health;
    health.data_fresh = true;
    health.exposure = Decimal::parse("1.25");
    health.realized_pnl = Decimal::parse("-0.1");
    health.updated_epoch_ms = fixture_ms;
    const std::string first = health_json(health).dump();
    const std::string second = health_json(health).dump();
    CHECK(first == second);
    CHECK(first.find("\"mode\":\"paper-only\"") != std::string::npos);
    CHECK(first.find("private") == std::string::npos);
    CHECK(first.find("order") == std::string::npos);
}

}  // namespace

int main() {
    run("decimal_is_exact", decimal_is_exact);
    run("exact_two_percent_boundary", exact_two_percent_boundary);
    run("walks_depth_and_reserves_costs", walks_depth_and_reserves_costs);
    run("stale_and_constraints_reject", stale_and_constraints_reject);
    run("hard_caps_cannot_be_raised", hard_caps_cannot_be_raised);
    run("strategy_enforces_pair_cap", strategy_enforces_pair_cap);
    run("parses_fixture_and_bounds_pagination", parses_fixture_and_bounds_pagination);
    run("malformed_payloads_fail_closed", malformed_payloads_fail_closed);
    run("engine_resnapshots_before_each_leg", engine_resnapshots_before_each_leg);
    run(
        "fresh_fill_cannot_breach_pair_or_total_cap",
        fresh_fill_cannot_breach_pair_or_total_cap);
    run("second_leg_cap_breach_recovers_first_leg", second_leg_cap_breach_recovers_first_leg);
    run("duplicate_restart_is_idempotent", duplicate_restart_is_idempotent);
    run("total_exposure_rejects_pair", total_exposure_rejects_pair);
    run("partial_second_leg_recovers_and_latches", partial_second_leg_recovers_and_latches);
    run("partial_first_leg_recovers_and_latches", partial_first_leg_recovers_and_latches);
    run("daily_loss_latches_and_rolls_utc", daily_loss_latches_and_rolls_utc);
    run(
        "file_repository_detects_corruption_and_persists_ids",
        file_repository_detects_corruption_and_persists_ids);
    run("interrupted_claim_latches_on_restart", interrupted_claim_latches_on_restart);
    run("operator_file_kill_is_latched", operator_file_kill_is_latched);
    run("reporting_is_deterministic_and_paper_only", reporting_is_deterministic_and_paper_only);
    return failures == 0 ? 0 : 1;
}
