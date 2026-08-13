#include "godbrain/polygon_observer.hpp"
#include "polygon_searcher/searcher.hpp"
#include "godbrain/polygon_pipeline.hpp"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>

namespace observer = godbrain::polygon::observer;
namespace pipeline = godbrain::polygon::pipeline;
namespace searcher = godbrain::polygon::searcher;
using Json = nlohmann::json;

namespace {

constexpr std::string_view token_a = "0x0000000000000000000000000000000000000001";
constexpr std::string_view token_b = "0x0000000000000000000000000000000000000002";
constexpr std::string_view router = "0x0000000000000000000000000000000000000100";
constexpr std::string_view router_two =
    "0x0000000000000000000000000000000000000200";

std::string hash(char digit) {
    return "0x" + std::string(64U, digit);
}

std::string word(std::uint64_t value) {
    std::ostringstream output;
    output << std::hex << std::setfill('0') << std::setw(64) << value;
    return output.str();
}

std::string amounts_response(std::uint64_t input, std::uint64_t output) {
    return "0x" + word(32U) + word(2U) + word(input) + word(output);
}

Json config_json() {
    return {
        {"schema_version", 1},
        {"chain_id", 137},
        {"evidence_revision", std::string(64U, 'a')},
        {"source",
         {{"url", "https://example.invalid/review/v1.json"},
          {"sha256", std::string(64U, 'b')}}},
        {"confirmation_depth", 10},
        {"maximum_block_age_seconds", 120},
        {"maximum_future_seconds", 2},
        {"maximum_quote_amount", 10'000'000},
        {"maximum_calldata_bytes", 256},
        {"gas_units_ceiling", 300'000},
        {"tokens",
         Json::array(
             {{{"address", token_a}, {"symbol", "A"}, {"decimals", 6}},
              {{"address", token_b}, {"symbol", "B"}, {"decimals", 18}}})},
        {"venues",
         Json::array(
             {{{"address", router},
               {"kind", "uniswap_v2_get_amounts_out"}},
              {{"address", router_two},
               {"kind", "uniswap_v2_get_amounts_out"}}})},
        {"routes",
         Json::array(
             {{{"id", "a-b"},
               {"venue", router},
               {"token_in", token_a},
               {"token_out", token_b}},
              {{"id", "b-a"},
               {"venue", router_two},
               {"token_in", token_b},
               {"token_out", token_a}},
              {{"id", "gas-b-a"},
               {"venue", router},
               {"token_in", token_b},
               {"token_out", token_a}}})},
        {"cycles",
         Json::array({{{"id", "a-b-a"},
                       {"first_route", "a-b"},
                       {"second_route", "b-a"}}})},
        {"gas_conversion",
         {{"wrapped_native", token_b},
          {"input_token", token_a},
          {"route_id", "gas-b-a"}}},
    };
}

template <typename Function>
void expect_throw(Function&& function) {
    bool threw = false;
    try {
        function();
    } catch (const std::exception&) {
        threw = true;
    }
    if (!threw) {
        throw std::runtime_error("expected exception");
    }
}

void require(bool condition, std::string_view message) {
    if (!condition) {
        throw std::runtime_error(std::string(message));
    }
}

class FixedObserverClock final : public observer::Clock {
public:
    explicit FixedObserverClock(std::int64_t seconds) : seconds_(seconds) {}

    [[nodiscard]] std::chrono::system_clock::time_point now() const override {
        return std::chrono::system_clock::time_point(std::chrono::seconds(seconds_));
    }

private:
    std::int64_t seconds_;
};

class FixedSearcherClock final : public searcher::Clock {
public:
    explicit FixedSearcherClock(std::int64_t value) : value_(value) {}
    [[nodiscard]] std::int64_t now_epoch_ms() const override { return value_; }

private:
    std::int64_t value_;
};

class FakeHealth final : public pipeline::HealthGate {
public:
    observer::HealthSnapshot value;
    [[nodiscard]] observer::HealthSnapshot inspect() override { return value; }
};

class FakeRpc final : public pipeline::ReadOnlyRpc {
public:
    std::string current_hash{hash('1')};
    std::string code{"0x6000"};
    std::string response{amounts_response(100U, 125U)};
    std::uint64_t timestamp{1'000U};
    std::uint64_t base_fee{10U};
    std::string last_data;
    std::uint64_t last_number{0};

    [[nodiscard]] Json get_block(std::uint64_t number) override {
        last_number = number;
        return {
            {"number", pipeline::canonical_block_number_tag(number)},
            {"hash", current_hash},
            {"parentHash", hash('2')},
            {"timestamp", pipeline::canonical_block_number_tag(timestamp)},
            {"baseFeePerGas", pipeline::canonical_block_number_tag(base_fee)},
        };
    }

    [[nodiscard]] std::string get_code(
        std::string_view address, std::uint64_t number) override {
        require(
            address == router || address == router_two,
            "unexpected code address");
        last_number = number;
        return code;
    }

    [[nodiscard]] std::string eth_call(
        std::string_view to,
        std::string_view data,
        std::uint64_t number) override {
        require(to == router || to == router_two, "unexpected call address");
        last_data = std::string(data);
        last_number = number;
        return response;
    }
};

class FakeBlocks final : public searcher::BlockProvider {
public:
    bool canonical{true};
    std::size_t checks{0};

    [[nodiscard]] searcher::BlockContext current() override { return block; }
    [[nodiscard]] bool is_canonical(const searcher::BlockContext&) override {
        ++checks;
        return canonical;
    }

    searcher::BlockContext block{
        .number = 100U,
        .hash = hash('1'),
        .parent_hash = hash('2'),
        .status = searcher::BlockStatus::confirmed,
        .observed_epoch_ms = 1'000'000,
    };
};

class FakeConversionQuotes final : public searcher::ExactInputQuoteProvider {
public:
        bool wrong_route{false};
        bool wrong_block{false};
        std::uint64_t output{7U};
        std::size_t calls{0};

        [[nodiscard]] searcher::ExactInputQuote quote(
            const searcher::QuoteRequest& request) override {
            ++calls;
            auto route = request.route;
            auto conversion_block = request.block;
            if (wrong_route) {
                route.id = "wrong";
            }
            if (wrong_block) {
                conversion_block.hash = hash('9');
            }
            return {
                .route = route,
                .amount_in = request.amount_in,
                .amount_out = output,
                .max_supported_input = request.amount_in,
                .confidence_bps = 10'000U,
                .block = conversion_block,
                .observed_epoch_ms = request.block.observed_epoch_ms,
                .provider = "polygon-pipeline-uniswap-v2",
                .provenance = "sha256:" + std::string(64U, 'd'),
                .quote_hash = std::string(64U, 'd'),
            };
        }
};

class FixtureTransport final : public observer::RpcTransport {
public:
        std::size_t block_calls{0};
        std::size_t code_calls{0};
        std::size_t quote_calls{0};

        observer::HttpResponse post(
            const observer::Endpoint&,
            std::string_view body,
            const observer::TransportLimits&) override {
            const Json request = Json::parse(body);
            const std::string method = request.at("method").get<std::string>();
            Json result;
            if (method == "eth_getBlockByNumber") {
                ++block_calls;
                require(
                    request.at("params").at(0) == "0x64",
                    "fixture block lookup was not pinned");
                result = {
                    {"number", "0x64"},
                    {"hash", hash('1')},
                    {"parentHash", hash('2')},
                    {"timestamp", "0x3e8"},
                    {"baseFeePerGas", "0x1"},
                };
            } else if (method == "eth_getCode") {
                ++code_calls;
                require(
                    request.at("params").at(1) == "0x64",
                    "fixture code lookup was not pinned");
                result = "0x6000";
            } else if (method == "eth_call") {
                ++quote_calls;
                const auto& call = request.at("params").at(0);
                const std::string to = call.at("to").get<std::string>();
                const std::string data = call.at("data").get<std::string>();
                require(
                    request.at("params").at(1) == "0x64",
                    "fixture quote was not pinned");
                require(data.starts_with("0xd06ca61f"), "fixture selector");
                const auto amount = std::stoull(data.substr(58U, 16U), nullptr, 16);
                std::uint64_t output = 0;
                if (to == router && amount == 100'000U) {
                    output = 140'000U;
                } else if (to == router_two && amount == 140'000U) {
                    output = 130'000U;
                } else if (to == router_two && amount == 100'000U) {
                    output = 90'000U;
                } else if (to == router && amount == 90'000U) {
                    output = 95'000U;
                } else if (to == router && amount == 300'000U) {
                    output = 1U;
                } else {
                    throw std::runtime_error("unexpected fixture quote");
                }
                result = amounts_response(amount, output);
            } else {
                throw std::runtime_error("non-read-only fixture method");
            }
            return {
                .status = 200U,
                .body =
                    Json{
                        {"jsonrpc", "2.0"},
                        {"id", request.at("id")},
                        {"result", std::move(result)},
                    }
                        .dump(),
                .latency = std::chrono::milliseconds(1),
            };
        }

        observer::HttpResponse get(
            const observer::Endpoint&,
            const observer::TransportLimits&) override {
            throw std::runtime_error("fixture GET is not configured");
        }
};

searcher::Route route_a_b() {
    return {
        .id = "a-b",
        .venue_id = std::string(router),
        .token_in = std::string(token_a),
        .token_out = std::string(token_b),
    };
}

void test_namespaces_and_config() {
    observer::HealthSnapshot observer_value;
    searcher::BlockContext searcher_value;
    require(!observer_value.ready, "observer type unavailable");
    require(
        searcher_value.status == searcher::BlockStatus::unknown,
        "searcher type unavailable");

    const auto parsed = pipeline::PipelineConfig::from_json(config_json());
    require(parsed.chain_id == 137U && parsed.routes.size() == 3U, "config parse");
    require(
        pipeline::PipelineConfig::from_json(parsed.to_json()).to_json() ==
            parsed.to_json(),
        "config round trip");

    Json bad = config_json();
    bad["unknown"] = true;
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["schema_version"] = 4'294'967'297ULL;
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["tokens"][0]["address"] =
        "0x000000000000000000000000000000000000000A";
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["tokens"][0]["decimals"] = 19;
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["venues"][0]["kind"] = "arbitrary";
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["routes"].push_back(bad["routes"][0]);
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["cycles"][0]["second_route"] = "a-b";
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
    bad = config_json();
    bad["routes"][1]["venue"] = router;
    expect_throw([&] { (void)pipeline::PipelineConfig::from_json(bad); });
}

void test_abi() {
    const std::string encoded = pipeline::encode_get_amounts_out(
        100U, token_a, token_b, 256U);
    require(encoded.starts_with("0xd06ca61f"), "fixed selector");
    require((encoded.size() - 2U) / 2U == 164U, "bounded two-token encoding");
    const auto response = amounts_response(100U, 125U);
    require(
        pipeline::decode_get_amounts_out(response, 100U) == 125U,
        "strict ABI decode");
    expect_throw([&] {
        (void)pipeline::decode_get_amounts_out(
            "0x" + word(64U) + word(2U) + word(100U) + word(125U), 100U);
    });
    expect_throw([&] {
        (void)pipeline::decode_get_amounts_out(
            "0x" + word(32U) + word(3U) + word(100U) + word(125U), 100U);
    });
    expect_throw([&] {
        (void)pipeline::decode_get_amounts_out(response.substr(0U, 250U), 100U);
    });
    std::string oversized = response;
    oversized.replace(194U, 48U, std::string(48U, '1'));
    expect_throw(
        [&] { (void)pipeline::decode_get_amounts_out(oversized, 100U); });
}

void test_quote_and_no_code() {
    const auto config = pipeline::PipelineConfig::from_json(config_json());
    FakeRpc rpc;
    FakeBlocks blocks;
    FixedSearcherClock clock(1'000'123);
    pipeline::UniswapV2QuoteProvider quotes(rpc, blocks, clock, config);
    const searcher::QuoteRequest request{
        .route = route_a_b(), .amount_in = 100U, .block = blocks.block};
    const auto first = quotes.quote(request);
    const auto second = quotes.quote(request);
    require(first.amount_out == 125U, "quote output");
    require(first.quote_hash == second.quote_hash, "quote determinism");
    require(first.quote_hash.size() == 64U, "SHA-256 quote hash");
    require(
        first.provider == "polygon-pipeline-uniswap-v2" &&
            first.provenance == "sha256:" + first.quote_hash,
        "searcher-safe quote identity");
    require(blocks.checks == 4U, "canonical checks before and after");
    require(rpc.last_number == 100U, "quote uses pinned block");
    require(rpc.last_data.starts_with("0xd06ca61f"), "reviewed calldata only");
    rpc.code = "0x";
    expect_throw([&] { (void)quotes.quote(request); });
    rpc.code = "0x00";
    expect_throw([&] { (void)quotes.quote(request); });
}

void test_confirmation_depth_and_reorg() {
    const auto config = pipeline::PipelineConfig::from_json(config_json());
    FakeHealth health;
    health.value.ready = true;
    health.value.chain_id = 137U;
    health.value.latest_block_number = 110U;
    FakeRpc rpc;
    FixedObserverClock clock(1'000);
    pipeline::ConfirmedBlockProvider blocks(health, rpc, clock, config);
    const auto block = blocks.current();
    require(block.number == 100U && rpc.last_number == 100U, "confirmation depth");
    require(blocks.is_canonical(block), "canonical block");
    rpc.current_hash = hash('3');
    require(!blocks.is_canonical(block), "reorg rejected");

    health.value.ready = false;
    expect_throw([&] { (void)blocks.current(); });
    health.value.ready = true;
    health.value.chain_id = 1U;
    expect_throw([&] { (void)blocks.current(); });
    health.value.chain_id = 137U;
    rpc.timestamp = 800U;
    expect_throw([&] { (void)blocks.current(); });
    rpc.timestamp = 1'003U;
    expect_throw([&] { (void)blocks.current(); });
}

void test_block_pinned_gas_cost() {
    require(
        pipeline::checked_base_fee_cost(300'000U, 10U) == 3'000'000U,
        "base fee multiplication");
    expect_throw([&] {
        (void)pipeline::checked_base_fee_cost(
            std::numeric_limits<std::uint64_t>::max(), 2U);
    });

    const auto config = pipeline::PipelineConfig::from_json(config_json());
    FakeHealth health;
    health.value.ready = true;
    health.value.chain_id = 137U;
    health.value.latest_block_number = 110U;
    FakeRpc rpc;
    FixedObserverClock observer_clock(1'000);
    pipeline::ConfirmedBlockProvider blocks(
        health, rpc, observer_clock, config);
    const auto block = blocks.current();
    FixedSearcherClock clock(1'000'000);
    FakeConversionQuotes conversion;
    pipeline::ConservativeGasCostProvider costs(
        blocks, conversion, clock, config);
    const searcher::CostRequest request{
        .first = route_a_b(),
        .second =
            {.id = "b-a",
             .venue_id = std::string(router_two),
             .token_in = std::string(token_b),
             .token_out = std::string(token_a)},
        .input_token =
            {.id = std::string(token_a), .symbol = "A", .decimals = 6U},
        .amount_in = 100U,
        .block = block,
    };
    const auto cost = costs.estimate(request);
    require(
        conversion.calls == 1U && cost.native_wei == 3'000'000U &&
            cost.input_token_cost == 7U,
        "live exact conversion quote used");
    require(
        cost.conversion_provenance == "sha256:" + std::string(64U, 'd') &&
            cost.quote_hash.size() == 64U,
        "searcher-safe gas provenance");
    conversion.wrong_route = true;
    expect_throw([&] { (void)costs.estimate(request); });
    conversion.wrong_route = false;
    conversion.wrong_block = true;
    expect_throw([&] { (void)costs.estimate(request); });
}

searcher::ArbitragePlan accepted_plan() {
    searcher::ArbitragePlan plan;
    plan.id = "accepted-paper-plan";
    plan.block = {
        .number = 100U,
        .hash = hash('1'),
        .parent_hash = hash('2'),
        .status = searcher::BlockStatus::confirmed,
        .observed_epoch_ms = 1'000'000,
    };
    plan.input_token = {
        .id = std::string(token_a), .symbol = "A", .decimals = 6U};
    plan.intermediate_token = {
        .id = std::string(token_b), .symbol = "B", .decimals = 18U};
    plan.first = route_a_b();
    plan.second = {
        .id = "b-a",
        .venue_id = std::string(router_two),
        .token_in = std::string(token_b),
        .token_out = std::string(token_a),
    };
    plan.amount_in = 100U;
    plan.first_quote_out = 120U;
    plan.gross_amount_out = 110U;
    plan.gross_profit = 10U;
    plan.costs = {
        .gas = 2U,
        .atlas_bid_reserve = 1U,
        .safety_margin = 1U,
        .adverse_slippage = 1U,
        .execution_failure_reserve = 1U,
    };
    plan.expected_net = 4;
    plan.created_epoch_ms = 1'000'000;
    plan.deadline_epoch_ms = 1'001'000;
    plan.first_quote_provider = "reviewed";
    plan.first_quote_hash = std::string(64U, 'a');
    plan.first_quote_provenance = "sha256:" + plan.first_quote_hash;
    plan.first_quote_observed_epoch_ms = 1'000'000;
    plan.second_quote_provider = "reviewed";
    plan.second_quote_hash = std::string(64U, 'b');
    plan.second_quote_provenance = "sha256:" + plan.second_quote_hash;
    plan.second_quote_observed_epoch_ms = 1'000'000;
    plan.gas_quote_hash = std::string(64U, 'c');
    plan.gas_conversion_provenance = "sha256:" + plan.gas_quote_hash;
    plan.gas_quote_observed_epoch_ms = 1'000'000;
    plan.max_gas_units = 300'000U;
    return plan;
}

void scan_keys(const Json& value, const std::vector<std::string>& forbidden) {
    if (value.is_object()) {
        for (const auto& [key, child] : value.items()) {
            for (const auto& marker : forbidden) {
                require(key.find(marker) == std::string::npos, "forbidden Atlas key");
            }
            scan_keys(child, forbidden);
        }
    } else if (value.is_array()) {
        for (const auto& child : value) {
            scan_keys(child, forbidden);
        }
    }
}

void test_atlas_data_only() {
    const auto atlas =
        pipeline::atlas_simulation_plan(accepted_plan(), std::string(64U, 'd'));
    require(atlas.at("id").get<std::string>().size() == 64U, "Atlas SHA-256 ID");
    require(
        atlas ==
            pipeline::atlas_simulation_plan(
                accepted_plan(), std::string(64U, 'd')),
        "Atlas deterministic");
    const std::vector<std::string> forbidden{
        "calldata", "private", "signature", "nonce", "relay", "broadcast",
        "deploy", "wallet", "transaction"};
    scan_keys(atlas, forbidden);
}

Json replay_fixture() {
    return {
        {"schema_version", 1},
        {"evidence_class",
         "sanitized_fixture_test_evidence_not_market_evidence"},
        {"records",
         Json::array(
             {{{"route_id", "a-b"},
               {"amount_in", 100},
               {"block",
                {{"number", 100},
                 {"hash", hash('1')},
                 {"parent_hash", hash('2')},
                 {"observed_epoch_ms", 1'000'000}}},
               {"observed_epoch_ms", 1'000'123},
               {"code_result", "0x6000"},
               {"call_result", amounts_response(100U, 125U)}}})},
    };
}

void test_replay() {
    const auto config = pipeline::PipelineConfig::from_json(config_json());
    const auto first = pipeline::replay_offline(config, replay_fixture());
    const auto second = pipeline::replay_offline(config, replay_fixture());
    require(first.json == second.json && first.csv == second.csv, "replay deterministic");
    require(
        first.json.at("records")[0].at("amount_out") == "125",
        "replay decodes response");
    require(
        first.json.at("evidence_class") ==
            "sanitized_fixture_test_evidence_not_market_evidence",
        "replay is labeled test evidence");
    const std::filesystem::path first_prefix =
        "polygon-pipeline-replay-byte-a";
    const std::filesystem::path second_prefix =
        "polygon-pipeline-replay-byte-b";
    pipeline::write_replay_output(first, first_prefix);
    pipeline::write_replay_output(second, second_prefix);
    const auto read_bytes = [](const std::filesystem::path& path) {
        std::ifstream input(path, std::ios::binary);
        if (!input) {
            throw std::runtime_error("cannot read replay output");
        }
        return std::string(
            std::istreambuf_iterator<char>(input),
            std::istreambuf_iterator<char>());
    };
    require(
        read_bytes(first_prefix.string() + ".json") ==
                read_bytes(second_prefix.string() + ".json") &&
            read_bytes(first_prefix.string() + ".csv") ==
                read_bytes(second_prefix.string() + ".csv"),
        "replay files are byte deterministic");
    for (const auto& path :
         {first_prefix.string() + ".json",
          first_prefix.string() + ".csv",
          second_prefix.string() + ".json",
          second_prefix.string() + ".csv"}) {
        std::filesystem::remove(path);
    }
    Json bad = replay_fixture();
    bad["records"][0]["extra"] = true;
    expect_throw([&] { (void)pipeline::replay_offline(config, bad); });
}

void test_searcher_adapter_integration() {
    const auto config = pipeline::PipelineConfig::from_json(config_json());
    FixtureTransport transport;
    const auto endpoint =
        observer::parse_local_endpoint("http://127.0.0.1:8545/");
    pipeline::ObserverReadOnlyRpc rpc(transport, endpoint);
    FakeHealth health;
    health.value.ready = true;
    health.value.chain_id = 137U;
    health.value.latest_block_number = 110U;
    FixedObserverClock observer_clock(1'000);
    pipeline::ConfirmedBlockProvider blocks(
        health, rpc, observer_clock, config);
    pipeline::ObserverClockAdapter clock(observer_clock);
    pipeline::ConfigTokenMetadataProvider tokens(config);
    pipeline::UniswapV2QuoteProvider quotes(rpc, blocks, clock, config);
    pipeline::ConservativeGasCostProvider costs(
        blocks, quotes, clock, config);
    pipeline::DeterministicPaperExecutor paper(clock);

    const std::filesystem::path audit_directory =
        std::filesystem::current_path() / "polygon-pipeline-integration-audit";
    std::filesystem::remove_all(audit_directory);
    const std::vector<searcher::Route> routes{
        route_a_b(),
        {.id = "b-a",
         .venue_id = std::string(router_two),
         .token_in = std::string(token_b),
         .token_out = std::string(token_a)},
    };
    searcher::SearchConfig risk;
    risk.max_routes = routes.size();
    risk.max_candidates_per_block = 4U;
    risk.max_gas_units = config.gas_units_ceiling;
    risk.max_quote_age_ms = 3'000;
    risk.max_block_age_ms = 3'000;
    risk.plan_ttl_ms = 1'000;
    risk.allowed_tokens = {std::string(token_a), std::string(token_b)};
    risk.allowed_venues = {std::string(router), std::string(router_two)};
    risk.max_input_by_token = {
        {std::string(token_a), 100'000U},
        {std::string(token_b), 100'000U},
    };
    risk.daily_loss_limit_by_token = {
        {std::string(token_a), 1'000'000U},
        {std::string(token_b), 1'000'000'000'000'000'000ULL},
    };
    const std::map<std::string, std::vector<searcher::Amount>> sizes{
        {std::string(token_a), {100'000U}},
        {std::string(token_b), {100'000U}},
    };

    searcher::FileAuditStore first_audit(audit_directory);
    first_audit.initialize(clock.now_epoch_ms());
    searcher::Searcher first_searcher(
        blocks,
        tokens,
        quotes,
        costs,
        clock,
        first_audit,
        paper,
        risk);
    const auto first = first_searcher.scan(routes, sizes);
    require(first.selected_plan.has_value(), "adapter plan accepted by Searcher");
    require(first.paper_result.has_value(), "paper result produced");
    require(
        first.selected_plan->first_quote_provider ==
                "polygon-pipeline-uniswap-v2" &&
            first.selected_plan->first_quote_provenance.starts_with("sha256:") &&
            first.selected_plan->gas_conversion_provenance.starts_with("sha256:"),
        "adapter evidence passes Searcher validation");
    const auto atlas = pipeline::atlas_simulation_plan(
        *first.selected_plan, config.evidence_revision);
    require(
        atlas.at("kind") == "atlas_simulation_plan",
        "accepted plan converted to Atlas envelope");
    require(
        transport.quote_calls >= 5U && transport.code_calls == transport.quote_calls &&
            transport.block_calls >= 10U,
        "pinned quotes and canonical checks performed");

    searcher::FileAuditStore restarted_audit(audit_directory);
    restarted_audit.initialize(clock.now_epoch_ms());
    searcher::Searcher restarted_searcher(
        blocks,
        tokens,
        quotes,
        costs,
        clock,
        restarted_audit,
        paper,
        risk);
    const auto restarted = restarted_searcher.scan(routes, sizes);
    require(
        restarted.selected_plan.has_value() &&
            restarted.selected_plan->id == first.selected_plan->id &&
            !restarted.paper_result.has_value(),
        "restart suppresses duplicate paper result");
    std::filesystem::remove_all(audit_directory);
}

void test_source_safety_scan() {
    const std::filesystem::path root = POLYGON_PIPELINE_SOURCE_DIR;
    const std::vector<std::string> forbidden{
        std::string("eth_") + "send",
        std::string("sign") + "transaction",
        std::string("personal") + "_",
        std::string("wallet") + "_",
        std::string("create") + "process",
        std::string("shell") + "execute",
        std::string("std::") + "system",
        std::string("broad") + "cast",
        std::string("de") + "ploy",
        std::string("re") + "lay",
        std::string("non") + "ce",
    };
    for (const auto& subtree : {"src", "include"}) {
        for (const auto& entry :
             std::filesystem::recursive_directory_iterator(root / subtree)) {
            if (!entry.is_regular_file()) {
                continue;
            }
            const auto extension = entry.path().extension().string();
            if (extension != ".cpp" && extension != ".hpp") {
                continue;
            }
            std::ifstream input(entry.path());
            std::string contents{
                std::istreambuf_iterator<char>(input),
                std::istreambuf_iterator<char>()};
            std::transform(
                contents.begin(), contents.end(), contents.begin(), [](char value) {
                    return static_cast<char>(
                        std::tolower(static_cast<unsigned char>(value)));
                });
            for (const auto& marker : forbidden) {
                require(
                    contents.find(marker) == std::string::npos,
                    "mutation surface found in production source");
            }
        }
    }
}

}  // namespace

int main() {
    try {
        test_namespaces_and_config();
        test_abi();
        test_quote_and_no_code();
        test_confirmation_depth_and_reorg();
        test_block_pinned_gas_cost();
        test_atlas_data_only();
        test_replay();
        test_searcher_adapter_integration();
        test_source_safety_scan();
        require(
            pipeline::sha256_hex("abc") ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256 vector");
        std::cout << "polygon_pipeline_tests: ok\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "polygon_pipeline_tests: " << error.what() << '\n';
        return 1;
    }
}
