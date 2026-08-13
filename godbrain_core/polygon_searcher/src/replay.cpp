#include "polygon_searcher/searcher.hpp"

#include <algorithm>
#include <charconv>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <string>
#include <utility>

using namespace godbrain::polygon::searcher;

namespace {

Amount parse_amount(const Json& value) {
    const std::string text = value.get<std::string>();
    Amount amount = 0;
    const auto parsed =
        std::from_chars(text.data(), text.data() + text.size(), amount);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        throw SearcherError("fixture amount must be an unsigned decimal string");
    }
    return amount;
}

class FixtureClock final : public Clock {
public:
    explicit FixtureClock(std::int64_t now) : now_(now) {}
    [[nodiscard]] std::int64_t now_epoch_ms() const override { return now_; }

private:
    std::int64_t now_;
};

class FixtureBlocks final : public BlockProvider {
public:
    explicit FixtureBlocks(BlockContext block) : block_(std::move(block)) {}
    [[nodiscard]] BlockContext current() override { return block_; }
    [[nodiscard]] bool is_canonical(const BlockContext& block) override {
        return block == block_;
    }

private:
    BlockContext block_;
};

class FixtureTokens final : public TokenMetadataProvider {
public:
    std::map<std::string, Token> values;

    [[nodiscard]] Token get(std::string_view token_id) override {
        return values.at(std::string(token_id));
    }
};

class FixtureQuotes final : public ExactInputQuoteProvider {
public:
    std::map<std::string, ExactInputQuote> values;

    [[nodiscard]] ExactInputQuote quote(const QuoteRequest& request) override {
        return values.at(request.route.id + ":" + std::to_string(request.amount_in));
    }
};

class FixtureCosts final : public GasCostProvider {
public:
    BlockContext block;
    std::int64_t observed_epoch_ms{0};
    std::uint64_t gas_units{0};
    Amount native_wei{0};
    Amount input_token_cost{0};
    std::string provenance;
    std::string hash;

    [[nodiscard]] GasCostQuote estimate(const CostRequest&) override {
        return {
            .block = block,
            .gas_units = gas_units,
            .native_wei = native_wei,
            .input_token_cost = input_token_cost,
            .observed_epoch_ms = observed_epoch_ms,
            .conversion_provenance = provenance,
            .quote_hash = hash,
        };
    }
};

class ReplayAudit final : public AuditStore {
public:
    void initialize(std::int64_t) override {}
    [[nodiscard]] SearcherSnapshot load() const override { return snapshot; }
    void record_decision(const Decision&, const BlockContext&) override {}
    [[nodiscard]] bool claim(const ArbitragePlan& plan) override {
        if (!snapshot.claimed_plan_ids.insert(plan.id).second) {
            return false;
        }
        snapshot.pending_plan_ids.insert(plan.id);
        return true;
    }
    void complete(const std::string& plan_id) override {
        snapshot.pending_plan_ids.erase(plan_id);
    }
    void record_paper_result(
        const PaperResult& result,
        std::string_view day,
        std::string_view token) override {
        snapshot.daily_pnl[std::string(day) + ":" + std::string(token)] +=
            result.realized_pnl;
    }
    void record_incident(std::string, std::string, std::int64_t) override {}
    void latch_kill(std::string reason, std::int64_t epoch_ms) override {
        snapshot.kill = {true, std::move(reason), epoch_ms};
    }

    SearcherSnapshot snapshot;
};

class DeterministicPaperExecutor final : public PaperExecutor {
public:
    explicit DeterministicPaperExecutor(std::int64_t now) : now_(now) {}

    [[nodiscard]] PaperResult execute(const ArbitragePlan& plan) override {
        const Amount final_amount =
            plan.amount_in + static_cast<Amount>(plan.expected_net);
        return {
            .plan_id = plan.id,
            .first_leg_filled = true,
            .second_leg_filled = true,
            .atomic = true,
            .final_amount = final_amount,
            .realized_pnl = plan.expected_net,
            .settled_epoch_ms = now_ + 1,
            .incident = "",
        };
    }

private:
    std::int64_t now_;
};

Route parse_route(const Json& value) {
    return {
        .id = value.at("id").get<std::string>(),
        .venue_id = value.at("venue_id").get<std::string>(),
        .token_in = value.at("token_in").get<std::string>(),
        .token_out = value.at("token_out").get<std::string>(),
    };
}

BlockContext parse_block(const Json& value) {
    return {
        .number = value.at("number").get<std::uint64_t>(),
        .hash = value.at("hash").get<std::string>(),
        .parent_hash = value.at("parent_hash").get<std::string>(),
        .status = BlockStatus::confirmed,
        .observed_epoch_ms = value.at("observed_epoch_ms").get<std::int64_t>(),
    };
}

void write_report(
    const Json& fixture,
    const SearchResult& result,
    const std::filesystem::path& output_directory) {
    std::size_t accepted = 0;
    for (const auto& decision : result.decisions) {
        accepted += decision.plan.has_value() ? 1U : 0U;
    }
    const Json report = {
        {"schema_version", 1},
        {"evidence_class", "sanitized_fixture_test_evidence_not_market_evidence"},
        {"fixture_label", fixture.at("label")},
        {"block_number", result.block.number},
        {"block_hash", result.block.hash},
        {"evaluated_candidates", result.decisions.size()},
        {"accepted_candidates", accepted},
        {"rejected_candidates", result.decisions.size() - accepted},
        {"paper_cycle_executed", result.paper_result.has_value()},
        {"selected_plan",
         result.selected_plan.has_value() ? plan_json(*result.selected_plan) : Json(nullptr)},
        {"paper_result",
         result.paper_result.has_value()
             ? paper_result_json(*result.paper_result)
             : Json(nullptr)},
    };
    std::error_code error;
    std::filesystem::create_directories(output_directory, error);
    if (error) {
        throw SearcherError("cannot create replay output: " + error.message());
    }
    {
        std::ofstream output(output_directory / "summary.json", std::ios::binary);
        if (!output) {
            throw SearcherError("cannot write replay JSON summary");
        }
        output << report.dump(2) << '\n';
    }
    {
        std::ofstream output(output_directory / "summary.csv", std::ios::binary);
        if (!output) {
            throw SearcherError("cannot write replay CSV summary");
        }
        output
            << "evidence_class,fixture_label,block_number,evaluated_candidates,"
               "accepted_candidates,rejected_candidates,paper_cycle_executed,"
               "expected_net_base_units,realized_pnl_base_units\n";
        output
            << "sanitized_fixture_test_evidence_not_market_evidence,"
            << fixture.at("label").get<std::string>() << ','
            << result.block.number << ',' << result.decisions.size() << ','
            << accepted << ',' << result.decisions.size() - accepted << ','
            << (result.paper_result.has_value() ? "true" : "false") << ','
            << (result.selected_plan.has_value()
                    ? std::to_string(result.selected_plan->expected_net)
                    : "")
            << ','
            << (result.paper_result.has_value()
                    ? std::to_string(result.paper_result->realized_pnl)
                    : "")
            << '\n';
    }
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 3) {
            std::cerr
                << "usage: polygon-searcher-replay <fixture.json> <output-directory>\n";
            return 2;
        }
        std::ifstream input(argv[1], std::ios::binary);
        if (!input) {
            throw SearcherError("cannot read replay fixture");
        }
        const Json fixture = Json::parse(input);
        if (fixture.at("schema_version").get<int>() != 1 ||
            fixture.at("evidence_class").get<std::string>() !=
                "sanitized_fixture_test_evidence_not_market_evidence") {
            throw SearcherError("unsupported or unsafely labeled replay fixture");
        }
        const std::int64_t now = fixture.at("now_epoch_ms").get<std::int64_t>();
        const BlockContext block = parse_block(fixture.at("block"));
        FixtureClock clock(now);
        FixtureBlocks blocks(block);
        FixtureTokens tokens;
        SearchConfig config;
        for (const Json& value : fixture.at("tokens")) {
            Token token{
                .id = value.at("id").get<std::string>(),
                .symbol = value.at("symbol").get<std::string>(),
                .decimals = value.at("decimals").get<std::uint8_t>(),
            };
            config.allowed_tokens.insert(token.id);
            config.max_input_by_token[token.id] =
                parse_amount(value.at("max_input"));
            config.daily_loss_limit_by_token[token.id] =
                parse_amount(value.at("daily_loss_limit"));
            tokens.values.emplace(token.id, std::move(token));
        }
        for (const Json& value : fixture.at("venues")) {
            config.allowed_venues.insert(value.at("id").get<std::string>());
        }
        std::vector<Route> routes;
        std::map<std::string, Route> route_index;
        for (const Json& value : fixture.at("routes")) {
            Route route = parse_route(value);
            route_index.emplace(route.id, route);
            routes.push_back(std::move(route));
        }
        std::map<std::string, std::vector<Amount>> sizes;
        for (const auto& [token, values] : fixture.at("input_sizes").items()) {
            for (const Json& value : values) {
                sizes[token].push_back(parse_amount(value));
            }
        }
        FixtureQuotes quotes;
        for (const Json& value : fixture.at("quotes")) {
            const Route route = route_index.at(value.at("route_id").get<std::string>());
            const Amount amount_in = parse_amount(value.at("amount_in"));
            quotes.values.emplace(
                route.id + ":" + std::to_string(amount_in),
                ExactInputQuote{
                    .route = route,
                    .amount_in = amount_in,
                    .amount_out = parse_amount(value.at("amount_out")),
                    .max_supported_input = parse_amount(value.at("max_supported_input")),
                    .confidence_bps = value.at("confidence_bps").get<std::uint32_t>(),
                    .block = block,
                    .observed_epoch_ms =
                        value.at("observed_epoch_ms").get<std::int64_t>(),
                    .provider = value.at("provider").get<std::string>(),
                    .provenance = value.at("provenance").get<std::string>(),
                    .quote_hash = value.at("quote_hash").get<std::string>(),
                });
        }
        const Json& cost = fixture.at("gas_cost");
        FixtureCosts costs;
        costs.block = block;
        costs.observed_epoch_ms = cost.at("observed_epoch_ms").get<std::int64_t>();
        costs.gas_units = cost.at("gas_units").get<std::uint64_t>();
        costs.native_wei = parse_amount(cost.at("native_wei"));
        costs.input_token_cost = parse_amount(cost.at("input_token_cost"));
        costs.provenance = cost.at("conversion_provenance").get<std::string>();
        costs.hash = cost.at("quote_hash").get<std::string>();
        ReplayAudit audit;
        DeterministicPaperExecutor executor(now);
        audit.initialize(now);
        Searcher searcher(
            blocks, tokens, quotes, costs, clock, audit, executor, config);
        const SearchResult result = searcher.scan(std::move(routes), std::move(sizes));
        write_report(fixture, result, argv[2]);
        std::cout << "wrote sanitized fixture test evidence to " << argv[2] << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "replay failed: " << error.what() << '\n';
        return 1;
    }
}
