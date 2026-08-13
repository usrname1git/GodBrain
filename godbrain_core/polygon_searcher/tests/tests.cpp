#include "polygon_searcher/searcher.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>

using namespace godbrain::polygon;

namespace {

constexpr std::int64_t now_ms = 1'786'651'200'000LL;
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

BlockContext block() {
    return {
        .number = 76'543'210,
        .hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .parent_hash = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .status = BlockStatus::confirmed,
        .observed_epoch_ms = now_ms - 100,
    };
}

Route first_route() {
    return {"a-b-v1", "venue-v1", "token-a", "token-b"};
}

Route second_route() {
    return {"b-a-v2", "venue-v2", "token-b", "token-a"};
}

class FakeClock final : public Clock {
public:
    mutable std::int64_t value{now_ms};
    std::int64_t advance_per_read{0};
    [[nodiscard]] std::int64_t now_epoch_ms() const override {
        const std::int64_t current = value;
        value += advance_per_read;
        return current;
    }
};

class FakeBlocks final : public BlockProvider {
public:
    BlockContext value{block()};
    bool canonical{true};
    int canonical_calls{0};
    int fail_after_calls{-1};

    [[nodiscard]] BlockContext current() override { return value; }
    [[nodiscard]] bool is_canonical(const BlockContext&) override {
        ++canonical_calls;
        return canonical && (fail_after_calls < 0 || canonical_calls <= fail_after_calls);
    }
};

class FakeTokens final : public TokenMetadataProvider {
public:
    std::map<std::string, Token> values{
        {"token-a", {"token-a", "TKA", 6}},
        {"token-b", {"token-b", "TKB", 6}},
    };

    [[nodiscard]] Token get(std::string_view id) override {
        return values.at(std::string(id));
    }
};

class FakeQuotes final : public ExactInputQuoteProvider {
public:
    std::map<std::string, ExactInputQuote> values;
    bool fail{false};
    std::size_t calls{0};

    [[nodiscard]] ExactInputQuote quote(const QuoteRequest& request) override {
        ++calls;
        if (fail) {
            throw SearcherError("scripted quote failure");
        }
        return values.at(request.route.id + ":" + std::to_string(request.amount_in));
    }
};

class FakeCosts final : public GasCostProvider {
public:
    GasCostQuote value{
        .block = block(),
        .gas_units = 180'000,
        .native_wei = 5'000,
        .input_token_cost = 1'000,
        .observed_epoch_ms = now_ms - 50,
        .conversion_provenance = "fixture:gas",
        .quote_hash = "0xc01",
    };

    [[nodiscard]] GasCostQuote estimate(const CostRequest&) override {
        return value;
    }
};

class MemoryAudit final : public AuditStore {
public:
    SearcherSnapshot snapshot;
    std::vector<Decision> decisions;
    std::vector<std::string> incidents;
    int claims{0};
    int completions{0};

    void initialize(std::int64_t) override {}
    [[nodiscard]] SearcherSnapshot load() const override { return snapshot; }
    void record_decision(const Decision& decision, const BlockContext&) override {
        decisions.push_back(decision);
    }
    [[nodiscard]] bool claim(const ArbitragePlan& plan) override {
        ++claims;
        if (!snapshot.claimed_plan_ids.insert(plan.id).second) {
            return false;
        }
        snapshot.pending_plan_ids.insert(plan.id);
        return true;
    }
    void complete(const std::string& id) override {
        ++completions;
        CHECK(snapshot.pending_plan_ids.erase(id) == 1);
    }
    void record_paper_result(
        const PaperResult& result,
        std::string_view day,
        std::string_view token) override {
        snapshot.daily_pnl[std::string(day) + ":" + std::string(token)] +=
            result.realized_pnl;
    }
    void record_incident(
        std::string reason,
        std::string,
        std::int64_t) override {
        incidents.push_back(std::move(reason));
    }
    void latch_kill(std::string reason, std::int64_t time) override {
        if (!snapshot.kill.active) {
            snapshot.kill = {true, std::move(reason), time};
        }
    }
};

class FakeExecutor final : public PaperExecutor {
public:
    int calls{0};
    bool partial{false};
    bool atomic_loss{false};
    bool throws{false};

    [[nodiscard]] PaperResult execute(const ArbitragePlan& plan) override {
        ++calls;
        if (throws) {
            throw SearcherError("scripted executor failure");
        }
        const std::int64_t pnl =
            partial ? -10 : (atomic_loss ? -250'000 : plan.expected_net);
        const Amount final_amount = pnl < 0
            ? plan.amount_in - static_cast<Amount>(-pnl)
            : plan.amount_in + static_cast<Amount>(pnl);
        return {
            .plan_id = plan.id,
            .first_leg_filled = true,
            .second_leg_filled = !partial,
            .atomic = !partial,
            .final_amount = final_amount,
            .realized_pnl = pnl,
            .settled_epoch_ms = now_ms + 1,
            .incident = partial ? "partial_fixture_fill" : "",
        };
    }
};

ExactInputQuote quote(
    const Route& route,
    Amount amount_in,
    Amount amount_out,
    std::string hash) {
    return {
        .route = route,
        .amount_in = amount_in,
        .amount_out = amount_out,
        .max_supported_input = 10'000'000,
        .confidence_bps = 9'900,
        .block = block(),
        .observed_epoch_ms = now_ms - 50,
        .provider = "fixture-provider",
        .provenance = "fixture:exact-input",
        .quote_hash = std::move(hash),
    };
}

SearchConfig config() {
    SearchConfig value;
    value.allowed_tokens = {"token-a", "token-b"};
    value.allowed_venues = {"venue-v1", "venue-v2"};
    value.max_input_by_token = {
        {"token-a", 2'000'000},
        {"token-b", 2'000'000},
    };
    value.daily_loss_limit_by_token = {
        {"token-a", 250'000},
        {"token-b", 250'000},
    };
    return value;
}

struct Rig {
    FakeBlocks blocks;
    FakeTokens tokens;
    FakeQuotes quotes;
    FakeCosts costs;
    FakeClock clock;
    MemoryAudit audit;
    FakeExecutor executor;
    SearchConfig settings{config()};
    std::vector<Route> routes{first_route(), second_route()};
    std::map<std::string, std::vector<Amount>> sizes{
        {"token-a", {1'000'000}},
        {"token-b", {1'000'000}},
    };

    Rig() {
        quotes.values.emplace(
            "a-b-v1:1000000", quote(first_route(), 1'000'000, 1'000'000, "0x101"));
        quotes.values.emplace(
            "b-a-v2:1000000", quote(second_route(), 1'000'000, 1'100'000, "0x102"));
        quotes.values.emplace(
            "a-b-v1:1100000", quote(first_route(), 1'100'000, 1'000'000, "0x103"));
    }

    SearchResult scan() {
        Searcher searcher(
            blocks, tokens, quotes, costs, clock, audit, executor, settings);
        return searcher.scan(routes, sizes);
    }
};

const Decision& accepted(const SearchResult& result) {
    const auto found = std::find_if(
        result.decisions.begin(), result.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); });
    CHECK(found != result.decisions.end());
    return *found;
}

void exact_profit_boundary() {
    Rig rig;
    rig.settings.safety_margin_bps = 0;
    rig.settings.slippage_bps_per_leg = 0;
    rig.settings.execution_failure_reserve_bps = 0;
    rig.settings.atlas_bid_reserve_bps = 0;
    rig.settings.min_net_edge_bps = 100;
    rig.costs.value.input_token_cost = 0;
    rig.quotes.values["b-a-v2:1000000"].amount_out = 1'010'000;
    const SearchResult equal = rig.scan();
    CHECK(accepted(equal).plan->net_edge_bps == 100);

    Rig below;
    below.settings = rig.settings;
    below.costs.value.input_token_cost = 0;
    below.quotes.values["b-a-v2:1000000"].amount_out = 1'009'999;
    const SearchResult rejected = below.scan();
    CHECK(std::none_of(
        rejected.decisions.begin(), rejected.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));
}

void conservative_cost_breakdown() {
    Rig rig;
    const SearchResult result = rig.scan();
    const ArbitragePlan& plan = *accepted(result).plan;
    CHECK(plan.gross_profit == 100'000);
    CHECK(plan.costs.gas == 1'000);
    CHECK(plan.costs.atlas_bid_reserve == 20'000);
    CHECK(plan.costs.safety_margin == 3'000);
    CHECK(plan.costs.adverse_slippage == 5'500);
    CHECK(plan.costs.execution_failure_reserve == 2'500);
    CHECK(plan.costs.total() == 32'000);
    CHECK(plan.expected_net == 68'000);
    CHECK(plan.net_edge_bps == 680);
}

void rounding_and_decimals_are_checked() {
    Token token{"token-a", "TKA", 6};
    CHECK(token_whole_limit(token, 10) == 10'000'000);
    token.decimals = 19;
    expect_throw([&] { (void)token_whole_limit(token, 1); });

    Rig rig;
    rig.sizes["token-a"] = {1};
    rig.settings.max_input_by_token["token-a"] = 1;
    rig.settings.min_net_edge_bps = 1;
    rig.settings.safety_margin_bps = 1;
    rig.settings.slippage_bps_per_leg = 1;
    rig.settings.execution_failure_reserve_bps = 1;
    rig.settings.atlas_bid_reserve_bps = 1;
    rig.costs.value.input_token_cost = 0;
    rig.quotes.values.emplace(
        "a-b-v1:1", quote(first_route(), 1, 1, "0x104"));
    rig.quotes.values["b-a-v2:1"] =
        quote(second_route(), 1, 10, "0x105");
    const ArbitragePlan& plan = *accepted(rig.scan()).plan;
    CHECK(plan.costs.safety_margin == 1);
    CHECK(plan.costs.adverse_slippage == 1);
    CHECK(plan.costs.execution_failure_reserve == 1);
    CHECK(plan.costs.atlas_bid_reserve == 1);
}

void block_consistency_and_freshness_fail_closed() {
    Rig mismatch;
    mismatch.quotes.values["a-b-v1:1000000"].block.hash = "0x999";
    const SearchResult mixed = mismatch.scan();
    CHECK(std::none_of(
        mixed.decisions.begin(), mixed.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    Rig stale;
    stale.quotes.values["a-b-v1:1000000"].observed_epoch_ms =
        now_ms - stale.settings.max_quote_age_ms - 1;
    const SearchResult old = stale.scan();
    CHECK(std::none_of(
        old.decisions.begin(), old.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    Rig pending;
    pending.blocks.value.status = BlockStatus::pending;
    expect_throw([&] { (void)pending.scan(); });

    Rig reorg;
    reorg.blocks.canonical = false;
    expect_throw([&] { (void)reorg.scan(); });
}

void reorg_before_execution_latches() {
    Rig rig;
    rig.blocks.fail_after_calls = 1;
    expect_throw([&] { (void)rig.scan(); });
    CHECK(rig.audit.snapshot.kill.active);
    CHECK(rig.audit.snapshot.kill.reason == "block_reorg");
    CHECK(rig.executor.calls == 0);
}

void optimizer_is_bounded_and_deterministic() {
    Rig rig;
    rig.sizes["token-a"] = {2'000'000, 1'000'000, 2'000'000};
    rig.quotes.values.emplace(
        "a-b-v1:2000000",
        quote(first_route(), 2'000'000, 2'000'000, "0x201"));
    rig.quotes.values.emplace(
        "b-a-v2:2000000",
        quote(second_route(), 2'000'000, 2'200'000, "0x202"));
    rig.quotes.values.emplace(
        "a-b-v1:2200000",
        quote(first_route(), 2'200'000, 2'000'000, "0x203"));
    const SearchResult result = rig.scan();
    CHECK(result.selected_plan.has_value());
    CHECK(result.selected_plan->amount_in == 2'000'000);
    CHECK(result.decisions.size() == 3);

    Rig too_many;
    too_many.sizes["token-a"].assign(
        SearchConfig::hard_max_input_sizes + 1, 1'000'000);
    for (std::size_t index = 0; index < too_many.sizes["token-a"].size(); ++index) {
        too_many.sizes["token-a"][index] += index;
    }
    expect_throw([&] { (void)too_many.scan(); });

    Rig candidate_cap;
    candidate_cap.settings.max_candidates_per_block = 1;
    expect_throw([&] { (void)candidate_cap.scan(); });
}

void duplicate_plan_is_idempotent() {
    Rig rig;
    const SearchResult first = rig.scan();
    CHECK(first.paper_result.has_value());
    const SearchResult second = rig.scan();
    CHECK(second.selected_plan.has_value());
    CHECK(!second.paper_result.has_value());
    CHECK(rig.executor.calls == 1);
    CHECK(rig.audit.completions == 1);
}

void allowlists_and_hard_caps_enforce() {
    Rig token_denied;
    token_denied.settings.allowed_tokens.erase("token-b");
    const SearchResult token_result = token_denied.scan();
    CHECK(std::none_of(
        token_result.decisions.begin(), token_result.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    Rig venue_denied;
    venue_denied.settings.allowed_venues.erase("venue-v2");
    const SearchResult result = venue_denied.scan();
    CHECK(std::none_of(
        result.decisions.begin(), result.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    Rig excessive_gas;
    excessive_gas.costs.value.gas_units =
        excessive_gas.settings.max_gas_units + 1;
    const SearchResult gas_result = excessive_gas.scan();
    CHECK(std::none_of(
        gas_result.decisions.begin(),
        gas_result.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    SearchConfig unsafe = config();
    unsafe.max_gas_units = SearchConfig::hard_max_gas_units + 1;
    expect_throw([&] { unsafe.validate(FakeTokens{}.values); });
    unsafe = config();
    unsafe.max_input_by_token["token-a"] = 10'000'001;
    expect_throw([&] { unsafe.validate(FakeTokens{}.values); });
}

void confidence_and_malformed_provider_data_reject() {
    Rig low_confidence;
    low_confidence.quotes.values["a-b-v1:1000000"].confidence_bps = 9'000;
    const SearchResult result = low_confidence.scan();
    CHECK(std::none_of(
        result.decisions.begin(), result.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));
}

void kill_loss_and_partial_incident_latch() {
    Rig emergency;
    emergency.settings.emergency_kill = true;
    expect_throw([&] { (void)emergency.scan(); });
    CHECK(emergency.audit.snapshot.kill.reason == "emergency_kill");

    Rig loss;
    loss.audit.snapshot.daily_pnl["2026-08-13:token-a"] = -250'000;
    expect_throw([&] { (void)loss.scan(); });
    CHECK(loss.audit.snapshot.kill.reason == "daily_paper_loss");

    Rig partial;
    partial.executor.partial = true;
    const SearchResult result = partial.scan();
    CHECK(result.paper_result.has_value());
    CHECK(partial.audit.snapshot.kill.reason == "paper_execution_incident");
    CHECK(!partial.audit.incidents.empty());

    Rig realized_loss;
    realized_loss.executor.atomic_loss = true;
    const SearchResult loss_result = realized_loss.scan();
    CHECK(loss_result.paper_result.has_value());
    CHECK(realized_loss.audit.snapshot.kill.reason == "daily_paper_loss");
}

void deterministic_schema_and_ids() {
    Rig first;
    Rig second;
    second.clock.value += 1;
    const ArbitragePlan a = *accepted(first.scan()).plan;
    const ArbitragePlan b = *accepted(second.scan()).plan;
    CHECK(a.id == b.id);
    CHECK(deterministic_plan_id(a) == a.id);
    const Json encoded = plan_json(a);
    CHECK(encoded.at("schema_version") == 1);
    CHECK(encoded.at("idempotency_id") == a.id);
    CHECK(encoded.at("amounts").at("gross_profit") == "100000");
    Json normalized_a = encoded;
    Json normalized_b = plan_json(b);
    normalized_a.at("constraints").erase("created_epoch_ms");
    normalized_a.at("constraints").erase("deadline_epoch_ms");
    normalized_b.at("constraints").erase("created_epoch_ms");
    normalized_b.at("constraints").erase("deadline_epoch_ms");
    CHECK(normalized_a.dump() == normalized_b.dump());
}

void expiry_route_identity_and_pending_fail_closed() {
    Rig expired;
    expired.settings.max_quote_age_ms = 3'000;
    expired.settings.max_block_age_ms = 3'000;
    expired.clock.advance_per_read = 1'000;
    const SearchResult late = expired.scan();
    CHECK(late.selected_plan.has_value());
    CHECK(!late.paper_result.has_value());
    CHECK(expired.executor.calls == 0);
    CHECK(
        expired.audit.incidents.front() ==
        "plan_expired_before_paper_execution");

    Rig wrong_route;
    wrong_route.quotes.values["a-b-v1:1000000"].route.venue_id = "venue-v2";
    const SearchResult mismatch = wrong_route.scan();
    CHECK(std::none_of(
        mismatch.decisions.begin(), mismatch.decisions.end(),
        [](const Decision& value) { return value.plan.has_value(); }));

    Rig duplicate_route;
    duplicate_route.routes.push_back(first_route());
    expect_throw([&] { (void)duplicate_route.scan(); });

    Rig pending;
    pending.audit.snapshot.pending_plan_ids.insert("unknown-plan");
    expect_throw([&] { (void)pending.scan(); });
    CHECK(pending.audit.snapshot.kill.reason == "ambiguous_pending_cycle");
}

void large_amount_edge_math_and_result_validation() {
    Rig rig;
    constexpr Amount input = 10'000'000'000'000'000'000ULL;
    constexpr Amount profit = 50'000'000'000'000'000ULL;
    rig.tokens.values["token-a"].decimals = 18;
    rig.tokens.values["token-b"].decimals = 18;
    rig.settings.max_input_by_token = {
        {"token-a", input},
        {"token-b", input},
    };
    rig.settings.daily_loss_limit_by_token = {
        {"token-a", 1'000'000'000'000'000'000ULL},
        {"token-b", 1'000'000'000'000'000'000ULL},
    };
    rig.settings.safety_margin_bps = 0;
    rig.settings.slippage_bps_per_leg = 0;
    rig.settings.execution_failure_reserve_bps = 0;
    rig.settings.atlas_bid_reserve_bps = 0;
    rig.settings.min_net_edge_bps = 50;
    rig.costs.value.input_token_cost = 0;
    rig.sizes = {
        {"token-a", {input}},
        {"token-b", {input}},
    };
    auto first = quote(first_route(), input, input, "0x301");
    first.max_supported_input = input;
    auto second = quote(second_route(), input, input + profit, "0x302");
    second.max_supported_input = input;
    rig.quotes.values.clear();
    rig.quotes.values.emplace("a-b-v1:" + std::to_string(input), first);
    rig.quotes.values.emplace("b-a-v2:" + std::to_string(input), second);
    const SearchResult result = rig.scan();
    CHECK(result.selected_plan->net_edge_bps == 50);
    CHECK(result.paper_result->realized_pnl == static_cast<std::int64_t>(profit));
}

std::filesystem::path temporary_path(std::string_view name) {
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    return std::filesystem::temp_directory_path() /
        ("godbrain-polygon-" + std::string(name) + "-" + std::to_string(nonce));
}

void file_state_reconciles_and_rejects_corruption() {
    const auto state = temporary_path("state");
    {
        FileAuditStore store(state);
        store.initialize(now_ms);
        Rig rig;
        const ArbitragePlan plan = *accepted(rig.scan()).plan;
        CHECK(store.claim(plan));
    }
    {
        FileAuditStore restarted(state);
        restarted.initialize(now_ms + 1);
        CHECK(restarted.load().kill.active);
        CHECK(restarted.load().kill.reason == "ambiguous_pending_cycle_on_restart");
    }
    std::filesystem::remove_all(state);

    const auto corrupt = temporary_path("corrupt");
    std::filesystem::create_directories(corrupt);
    {
        std::ofstream output(corrupt / "snapshot.json");
        output << "{not-json";
    }
    FileAuditStore broken(corrupt);
    expect_throw([&] { broken.initialize(now_ms); });
    std::filesystem::remove_all(corrupt);

    const auto unwritable = temporary_path("unwritable");
    {
        std::ofstream output(unwritable);
        output << "not-a-directory";
    }
    FileAuditStore blocked(unwritable);
    expect_throw([&] { blocked.initialize(now_ms); });
    std::filesystem::remove(unwritable);

    const auto orphan = temporary_path("orphan");
    std::filesystem::create_directories(orphan);
    {
        std::ofstream output(orphan / "audit.jsonl");
        output << "{}\n";
    }
    FileAuditStore incomplete(orphan);
    expect_throw([&] { incomplete.initialize(now_ms); });
    std::filesystem::remove_all(orphan);

    FileAuditStore never_initialized(temporary_path("not-initialized"));
    expect_throw([&] { (void)never_initialized.load(); });
}

template <typename T>
concept HasSubmit = requires(T& value, const ArbitragePlan& plan) {
    value.submit(plan);
};

template <typename T>
concept HasSign = requires(T& value, const ArbitragePlan& plan) {
    value.sign(plan);
};

template <typename T>
concept HasBroadcast = requires(T& value, const ArbitragePlan& plan) {
    value.broadcast(plan);
};

static_assert(!HasSubmit<ExactInputQuoteProvider>);
static_assert(!HasSign<PaperExecutor>);
static_assert(!HasBroadcast<PaperExecutor>);

void source_has_no_live_transaction_surface() {
    const std::filesystem::path root = POLYGON_SEARCHER_SOURCE_DIR;
    const std::vector<std::string> banned{
        "eth_sendrawtransaction",
        "private_key",
        "privatekey",
        ".submit(",
        ".sign(",
        ".broadcast(",
        "sendtransaction",
    };
    for (const auto& directory : {root / "include", root / "src"}) {
        for (const auto& entry :
             std::filesystem::recursive_directory_iterator(directory)) {
            if (!entry.is_regular_file()) {
                continue;
            }
            const auto extension = entry.path().extension().string();
            if (extension != ".cpp" && extension != ".hpp") {
                continue;
            }
            std::ifstream input(entry.path(), std::ios::binary);
            const std::string text(
                (std::istreambuf_iterator<char>(input)),
                std::istreambuf_iterator<char>());
            std::string lowered = text;
            std::transform(
                lowered.begin(), lowered.end(), lowered.begin(),
                [](unsigned char character) {
                    return static_cast<char>(std::tolower(character));
                });
            for (const auto& pattern : banned) {
                CHECK(lowered.find(pattern) == std::string::npos);
            }
        }
    }
}

}  // namespace

int main() {
    run("exact profit boundary", exact_profit_boundary);
    run("conservative cost breakdown", conservative_cost_breakdown);
    run("rounding and decimals", rounding_and_decimals_are_checked);
    run("block consistency and freshness", block_consistency_and_freshness_fail_closed);
    run("reorg before execution", reorg_before_execution_latches);
    run("bounded deterministic optimizer", optimizer_is_bounded_and_deterministic);
    run("duplicate idempotency", duplicate_plan_is_idempotent);
    run("allowlists and hard caps", allowlists_and_hard_caps_enforce);
    run("provider confidence", confidence_and_malformed_provider_data_reject);
    run("kill loss and partial latches", kill_loss_and_partial_incident_latch);
    run("deterministic schema and ids", deterministic_schema_and_ids);
    run(
        "expiry route identity and pending state",
        expiry_route_identity_and_pending_fail_closed);
    run("large amount edge math", large_amount_edge_math_and_result_validation);
    run("state reconciliation and corruption", file_state_reconciles_and_rejects_corruption);
    run("no live transaction surface", source_has_no_live_transaction_surface);
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return 1;
    }
    std::cout << "all Polygon searcher tests passed\n";
    return 0;
}
