#include "polygon_searcher/searcher.hpp"

#include <algorithm>
#include <array>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

namespace godbrain::polygon {
namespace {

constexpr std::uint64_t basis_points = 10'000;

Amount checked_add(Amount left, Amount right) {
    if (left > std::numeric_limits<Amount>::max() - right) {
        throw SearcherError("amount addition overflow");
    }
    return left + right;
}

struct MulDivResult {
    Amount quotient{0};
    Amount remainder{0};
};

MulDivResult mul_div(
    Amount value,
    std::uint64_t multiplier,
    std::uint64_t divisor) {
    if (divisor == 0) {
        throw SearcherError("division by zero");
    }
    if (multiplier > basis_points) {
        throw SearcherError("fixed-point multiplier exceeds compiled bound");
    }
    const Amount whole = value / divisor;
    const Amount remainder = value % divisor;
    if (multiplier != 0 && whole > std::numeric_limits<Amount>::max() / multiplier) {
        throw SearcherError("fixed-point multiplication overflow");
    }
    Amount fractional_quotient = 0;
    Amount fractional_remainder = 0;
    for (std::uint64_t index = 0; index < multiplier; ++index) {
        if (remainder == 0) {
            break;
        }
        if (fractional_remainder >= divisor - remainder) {
            fractional_remainder -= divisor - remainder;
            fractional_quotient = checked_add(fractional_quotient, 1);
        } else {
            fractional_remainder += remainder;
        }
    }
    return {
        checked_add(whole * multiplier, fractional_quotient),
        fractional_remainder,
    };
}

Amount mul_div_down(Amount value, std::uint64_t multiplier, std::uint64_t divisor) {
    return mul_div(value, multiplier, divisor).quotient;
}

Amount mul_div_up(Amount value, std::uint64_t multiplier, std::uint64_t divisor) {
    const MulDivResult result = mul_div(value, multiplier, divisor);
    if (result.remainder != 0) {
        return checked_add(result.quotient, 1);
    }
    return result.quotient;
}

std::uint32_t ratio_bps_down(Amount numerator, Amount denominator) {
    if (denominator == 0) {
        throw SearcherError("zero edge denominator");
    }
    const Amount value = mul_div_down(numerator, basis_points, denominator);
    return static_cast<std::uint32_t>(
        std::min<Amount>(value, std::numeric_limits<std::uint32_t>::max()));
}

bool valid_identifier(std::string_view value) {
    if (value.empty() || value.size() > 128) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' ||
            character == '_' || character == ':' || character == '.';
    });
}

bool valid_evidence_hash(std::string_view value) {
    return value.size() >= 3 && value.size() <= 128 &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f') ||
                (character >= 'A' && character <= 'F') || character == 'x';
        });
}

bool valid_block_hash(std::string_view value) {
    return value.size() == 66 && value.starts_with("0x") &&
        std::all_of(value.begin() + 2, value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f') ||
                (character >= 'A' && character <= 'F');
        });
}

bool valid_audit_text(std::string_view value) {
    if (value.empty() || value.size() > 256) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' ||
            character == '_' || character == ':' || character == '.' ||
            character == '/' || character == '#';
    });
}

bool context_matches(const BlockContext& left, const BlockContext& right) {
    return left.number == right.number && left.hash == right.hash &&
        left.parent_hash == right.parent_hash &&
        left.status == BlockStatus::confirmed && right.status == BlockStatus::confirmed;
}

bool fresh(std::int64_t observed_ms, std::int64_t now_ms, std::int64_t maximum_age_ms) {
    const std::int64_t age = now_ms - observed_ms;
    return age >= 0 && age <= maximum_age_ms;
}

std::string pair_name(const Route& first, const Route& second) {
    return first.id + ">" + second.id;
}

std::string block_status_name(BlockStatus status) {
    switch (status) {
        case BlockStatus::confirmed:
            return "confirmed";
        case BlockStatus::pending:
            return "pending";
        case BlockStatus::unknown:
            return "unknown";
        case BlockStatus::reorged:
            return "reorged";
    }
    throw SearcherError("invalid block status");
}

std::int64_t realized_delta(Amount final_amount, Amount initial_amount) {
    if (final_amount >= initial_amount) {
        const Amount difference = final_amount - initial_amount;
        if (difference > static_cast<Amount>(std::numeric_limits<std::int64_t>::max())) {
            throw SearcherError("positive paper result exceeds signed PnL range");
        }
        return static_cast<std::int64_t>(difference);
    }
    const Amount difference = initial_amount - final_amount;
    constexpr Amount minimum_magnitude =
        static_cast<Amount>(std::numeric_limits<std::int64_t>::max()) + 1;
    if (difference > minimum_magnitude) {
        throw SearcherError("negative paper result exceeds signed PnL range");
    }
    if (difference == minimum_magnitude) {
        return std::numeric_limits<std::int64_t>::min();
    }
    return -static_cast<std::int64_t>(difference);
}

}  // namespace

Amount CostBreakdown::total() const {
    return checked_add(
        checked_add(checked_add(gas, atlas_bid_reserve), safety_margin),
        checked_add(adverse_slippage, execution_failure_reserve));
}

Amount token_whole_limit(const Token& token, Amount whole_tokens) {
    if (token.decimals > SearchConfig::hard_max_token_decimals) {
        throw SearcherError("token decimals exceed hard ceiling");
    }
    Amount scale = 1;
    for (std::uint8_t index = 0; index < token.decimals; ++index) {
        if (scale > std::numeric_limits<Amount>::max() / 10) {
            throw SearcherError("token decimal scale overflow");
        }
        scale *= 10;
    }
    if (whole_tokens != 0 && scale > std::numeric_limits<Amount>::max() / whole_tokens) {
        return std::numeric_limits<Amount>::max();
    }
    return scale * whole_tokens;
}

void SearchConfig::validate(const std::map<std::string, Token>& tokens) const {
    if (max_routes == 0 || max_routes > hard_max_routes ||
        max_candidates_per_block == 0 ||
        max_candidates_per_block > hard_max_candidates_per_block ||
        max_gas_units == 0 || max_gas_units > hard_max_gas_units ||
        max_quote_age_ms <= 0 || max_quote_age_ms > hard_max_quote_age_ms ||
        max_block_age_ms <= 0 || max_block_age_ms > hard_max_quote_age_ms ||
        plan_ttl_ms <= 0 || plan_ttl_ms > hard_max_quote_age_ms ||
        min_confidence_bps > basis_points ||
        min_net_edge_bps < hard_min_net_edge_bps ||
        slippage_bps_per_leg > hard_max_slippage_bps_per_leg ||
        safety_margin_bps > hard_max_safety_bps ||
        execution_failure_reserve_bps > hard_max_failure_reserve_bps ||
        atlas_bid_reserve_bps > hard_max_bid_reserve_bps) {
        throw SearcherError("search configuration exceeds compiled risk bounds");
    }
    if (allowed_tokens.empty() || allowed_venues.empty()) {
        throw SearcherError("token and venue allowlists must be explicit");
    }
    for (const auto& token_id : allowed_tokens) {
        const auto found = tokens.find(token_id);
        if (found == tokens.end() || !valid_identifier(found->second.id) ||
            found->second.id != token_id || found->second.symbol.empty()) {
            throw SearcherError("allowed token metadata is missing or malformed");
        }
        const auto max_input = max_input_by_token.find(token_id);
        const auto daily_loss = daily_loss_limit_by_token.find(token_id);
        if (max_input == max_input_by_token.end() || max_input->second == 0 ||
            max_input->second >
                token_whole_limit(found->second, hard_max_whole_tokens)) {
            throw SearcherError("token notional limit is missing or exceeds hard ceiling");
        }
        if (daily_loss == daily_loss_limit_by_token.end() || daily_loss->second == 0 ||
            daily_loss->second >
                token_whole_limit(found->second, hard_max_daily_loss_whole_tokens) ||
            daily_loss->second > static_cast<Amount>(std::numeric_limits<std::int64_t>::max())) {
            throw SearcherError("daily loss limit is missing or exceeds hard ceiling");
        }
    }
    for (const auto& venue : allowed_venues) {
        if (!valid_identifier(venue)) {
            throw SearcherError("venue allowlist contains malformed identifier");
        }
    }
}

Json plan_json(const ArbitragePlan& plan) {
    return {
        {"schema_version", plan.schema_version},
        {"idempotency_id", plan.id},
        {"block", {
            {"number", plan.block.number},
            {"hash", plan.block.hash},
            {"parent_hash", plan.block.parent_hash},
            {"status", block_status_name(plan.block.status)},
            {"observed_epoch_ms", plan.block.observed_epoch_ms},
        }},
        {"input_token", {
            {"id", plan.input_token.id},
            {"symbol", plan.input_token.symbol},
            {"decimals", plan.input_token.decimals},
        }},
        {"intermediate_token", {
            {"id", plan.intermediate_token.id},
            {"symbol", plan.intermediate_token.symbol},
            {"decimals", plan.intermediate_token.decimals},
        }},
        {"routes", {
            {
                {"id", plan.first.id},
                {"venue_id", plan.first.venue_id},
                {"token_in", plan.first.token_in},
                {"token_out", plan.first.token_out},
            },
            {
                {"id", plan.second.id},
                {"venue_id", plan.second.venue_id},
                {"token_in", plan.second.token_in},
                {"token_out", plan.second.token_out},
            },
        }},
        {"amounts", {
            {"amount_in", std::to_string(plan.amount_in)},
            {"first_quote_out", std::to_string(plan.first_quote_out)},
            {"gross_amount_out", std::to_string(plan.gross_amount_out)},
            {"gross_profit", std::to_string(plan.gross_profit)},
            {"expected_net", std::to_string(plan.expected_net)},
            {"net_edge_bps", plan.net_edge_bps},
        }},
        {"costs", {
            {"gas", std::to_string(plan.costs.gas)},
            {"atlas_bid_reserve", std::to_string(plan.costs.atlas_bid_reserve)},
            {"safety_margin", std::to_string(plan.costs.safety_margin)},
            {"adverse_slippage", std::to_string(plan.costs.adverse_slippage)},
            {"execution_failure_reserve",
             std::to_string(plan.costs.execution_failure_reserve)},
            {"total", std::to_string(plan.costs.total())},
        }},
        {"quotes", {
            {
                {"provider", plan.first_quote_provider},
                {"provenance", plan.first_quote_provenance},
                {"hash", plan.first_quote_hash},
                {"observed_epoch_ms", plan.first_quote_observed_epoch_ms},
            },
            {
                {"provider", plan.second_quote_provider},
                {"provenance", plan.second_quote_provenance},
                {"hash", plan.second_quote_hash},
                {"observed_epoch_ms", plan.second_quote_observed_epoch_ms},
            },
        }},
        {"gas", {
            {"conversion_provenance", plan.gas_conversion_provenance},
            {"quote_hash", plan.gas_quote_hash},
            {"observed_epoch_ms", plan.gas_quote_observed_epoch_ms},
        }},
        {"constraints", {
            {"created_epoch_ms", plan.created_epoch_ms},
            {"deadline_epoch_ms", plan.deadline_epoch_ms},
            {"min_confidence_bps", plan.min_confidence_bps},
            {"max_gas_units", plan.max_gas_units},
        }},
    };
}

Json decision_json(const Decision& decision) {
    Json value = {
        {"accepted", decision.plan.has_value()},
        {"reason", decision.reason},
        {"route_pair", decision.route_pair},
        {"amount_in", std::to_string(decision.amount_in)},
    };
    if (decision.plan.has_value()) {
        value["plan"] = plan_json(*decision.plan);
    }
    return value;
}

Json paper_result_json(const PaperResult& result) {
    return {
        {"plan_id", result.plan_id},
        {"first_leg_filled", result.first_leg_filled},
        {"second_leg_filled", result.second_leg_filled},
        {"atomic", result.atomic},
        {"final_amount", std::to_string(result.final_amount)},
        {"realized_pnl", std::to_string(result.realized_pnl)},
        {"settled_epoch_ms", result.settled_epoch_ms},
        {"incident", result.incident},
    };
}

std::string deterministic_plan_id(const ArbitragePlan& plan) {
    const std::array<std::string, 12> fields{
        std::to_string(plan.schema_version),
        std::to_string(plan.block.number),
        plan.block.hash,
        plan.first.id,
        plan.second.id,
        std::to_string(plan.amount_in),
        std::to_string(plan.first_quote_out),
        std::to_string(plan.gross_amount_out),
        plan.first_quote_hash,
        plan.second_quote_hash,
        plan.gas_quote_hash,
        plan.input_token.id,
    };
    std::uint64_t hash = 14695981039346656037ULL;
    for (const auto& field : fields) {
        for (const unsigned char character : field) {
            hash ^= character;
            hash *= 1099511628211ULL;
        }
        hash ^= 0xffU;
        hash *= 1099511628211ULL;
    }
    std::ostringstream output;
    output << "arb-v1-" << std::hex << std::setw(16) << std::setfill('0') << hash;
    return output.str();
}

Searcher::Searcher(
    BlockProvider& blocks,
    TokenMetadataProvider& tokens,
    ExactInputQuoteProvider& quotes,
    GasCostProvider& costs,
    Clock& clock,
    AuditStore& audit,
    PaperExecutor& executor,
    SearchConfig config)
    : blocks_(blocks),
      tokens_(tokens),
      quotes_(quotes),
      costs_(costs),
      clock_(clock),
      audit_(audit),
      executor_(executor),
      config_(std::move(config)) {}

Decision Searcher::evaluate(
    const Route& first,
    const Route& second,
    Amount amount_in,
    const BlockContext& block,
    const std::map<std::string, Token>& token_metadata) {
    Decision rejected{
        .plan = std::nullopt,
        .reason = "",
        .route_pair = pair_name(first, second),
        .amount_in = amount_in,
    };
    const auto reject = [&](std::string reason) {
        rejected.reason = std::move(reason);
        return rejected;
    };
    if (first.venue_id == second.venue_id || first.token_out != second.token_in ||
        first.token_in != second.token_out) {
        return reject("not_two_venue_two_token_cycle");
    }
    if (!config_.allowed_tokens.contains(first.token_in) ||
        !config_.allowed_tokens.contains(first.token_out) ||
        !config_.allowed_venues.contains(first.venue_id) ||
        !config_.allowed_venues.contains(second.venue_id)) {
        return reject("not_allowlisted");
    }
    if (amount_in == 0 ||
        amount_in > config_.max_input_by_token.at(first.token_in)) {
        return reject("notional_limit");
    }

    const std::int64_t now = clock_.now_epoch_ms();
    ExactInputQuote first_quote;
    ExactInputQuote second_quote;
    GasCostQuote cost;
    try {
        first_quote = quotes_.quote({first, amount_in, block});
        if (first_quote.route != first || first_quote.amount_in != amount_in ||
            first_quote.amount_out == 0 ||
            first_quote.amount_in > first_quote.max_supported_input ||
            first_quote.confidence_bps < config_.min_confidence_bps ||
            first_quote.confidence_bps > basis_points ||
            !context_matches(first_quote.block, block) ||
            !fresh(first_quote.observed_epoch_ms, now, config_.max_quote_age_ms) ||
            !valid_identifier(first_quote.provider) ||
            !valid_audit_text(first_quote.provenance) ||
            !valid_evidence_hash(first_quote.quote_hash)) {
            return reject("malformed_or_low_confidence_first_quote");
        }
        second_quote =
            quotes_.quote({second, first_quote.amount_out, block});
        if (second_quote.route != second ||
            second_quote.amount_in != first_quote.amount_out ||
            second_quote.amount_out == 0 ||
            second_quote.amount_in > second_quote.max_supported_input ||
            second_quote.confidence_bps < config_.min_confidence_bps ||
            second_quote.confidence_bps > basis_points ||
            !context_matches(second_quote.block, block) ||
            !fresh(second_quote.observed_epoch_ms, now, config_.max_quote_age_ms) ||
            !valid_identifier(second_quote.provider) ||
            !valid_audit_text(second_quote.provenance) ||
            !valid_evidence_hash(second_quote.quote_hash)) {
            return reject("malformed_or_low_confidence_second_quote");
        }
        cost = costs_.estimate({
            first,
            second,
            token_metadata.at(first.token_in),
            amount_in,
            block,
        });
        if (!context_matches(cost.block, block) ||
            cost.gas_units == 0 || cost.gas_units > config_.max_gas_units ||
            !fresh(cost.observed_epoch_ms, now, config_.max_quote_age_ms) ||
            !valid_audit_text(cost.conversion_provenance) ||
            !valid_evidence_hash(cost.quote_hash)) {
            return reject("malformed_or_excessive_gas_quote");
        }
    } catch (const std::exception&) {
        return reject("provider_error");
    }

    if (second_quote.amount_out <= amount_in) {
        return reject("no_gross_profit");
    }
    const Amount gross_profit = second_quote.amount_out - amount_in;
    CostBreakdown breakdown{
        .gas = cost.input_token_cost,
        .atlas_bid_reserve =
            mul_div_up(gross_profit, config_.atlas_bid_reserve_bps, basis_points),
        .safety_margin =
            mul_div_up(amount_in, config_.safety_margin_bps, basis_points),
        .adverse_slippage = mul_div_up(
            second_quote.amount_out,
            static_cast<std::uint64_t>(config_.slippage_bps_per_leg) * 2,
            basis_points),
        .execution_failure_reserve = mul_div_up(
            amount_in, config_.execution_failure_reserve_bps, basis_points),
    };
    const Amount modeled_costs = breakdown.total();
    if (modeled_costs >= gross_profit ||
        gross_profit - modeled_costs >
            static_cast<Amount>(std::numeric_limits<std::int64_t>::max())) {
        return reject("not_profitable_after_costs");
    }
    const Amount expected = gross_profit - modeled_costs;
    const std::uint32_t edge = ratio_bps_down(expected, amount_in);
    if (expected == 0 || edge < config_.min_net_edge_bps) {
        return reject("edge_below_threshold");
    }

    ArbitragePlan plan{
        .schema_version = 1,
        .id = "",
        .block = block,
        .input_token = token_metadata.at(first.token_in),
        .intermediate_token = token_metadata.at(first.token_out),
        .first = first,
        .second = second,
        .amount_in = amount_in,
        .first_quote_out = first_quote.amount_out,
        .gross_amount_out = second_quote.amount_out,
        .gross_profit = gross_profit,
        .costs = breakdown,
        .expected_net = static_cast<std::int64_t>(expected),
        .net_edge_bps = edge,
        .created_epoch_ms = now,
        .deadline_epoch_ms = now + config_.plan_ttl_ms,
        .first_quote_provider = first_quote.provider,
        .first_quote_provenance = first_quote.provenance,
        .first_quote_hash = first_quote.quote_hash,
        .first_quote_observed_epoch_ms = first_quote.observed_epoch_ms,
        .second_quote_provider = second_quote.provider,
        .second_quote_provenance = second_quote.provenance,
        .second_quote_hash = second_quote.quote_hash,
        .second_quote_observed_epoch_ms = second_quote.observed_epoch_ms,
        .gas_conversion_provenance = cost.conversion_provenance,
        .gas_quote_hash = cost.quote_hash,
        .gas_quote_observed_epoch_ms = cost.observed_epoch_ms,
        .min_confidence_bps = config_.min_confidence_bps,
        .max_gas_units = config_.max_gas_units,
    };
    plan.id = deterministic_plan_id(plan);
    return {
        .plan = std::move(plan),
        .reason = "accepted",
        .route_pair = pair_name(first, second),
        .amount_in = amount_in,
    };
}

SearchResult Searcher::scan(
    std::vector<Route> routes,
    std::map<std::string, std::vector<Amount>> input_sizes) {
    const std::lock_guard<std::mutex> cycle(cycle_mutex_);
    const std::int64_t now = clock_.now_epoch_ms();
    const BlockContext block = blocks_.current();
    SearchResult result{.block = block};
    if (config_.emergency_kill) {
        audit_.latch_kill("emergency_kill", now);
        throw SearcherError("emergency kill switch is active");
    }
    const SearcherSnapshot initial = audit_.load();
    if (initial.kill.active) {
        throw SearcherError("paper search is latched: " + initial.kill.reason);
    }
    if (!initial.pending_plan_ids.empty()) {
        audit_.latch_kill("ambiguous_pending_cycle", now);
        throw SearcherError("unreconciled pending paper cycle");
    }
    if (block.status != BlockStatus::confirmed || block.number == 0 ||
        !valid_block_hash(block.hash) || !valid_block_hash(block.parent_hash) ||
        !fresh(block.observed_epoch_ms, now, config_.max_block_age_ms) ||
        !blocks_.is_canonical(block)) {
        throw SearcherError("block context is pending, unknown, reorged, stale, or noncanonical");
    }
    if (routes.empty() || routes.size() > config_.max_routes) {
        throw SearcherError("route set is empty or exceeds configured bound");
    }

    std::sort(routes.begin(), routes.end(), [](const Route& left, const Route& right) {
        return left.id < right.id;
    });
    for (std::size_t index = 1; index < routes.size(); ++index) {
        if (routes[index - 1].id == routes[index].id) {
            throw SearcherError("duplicate route identifier");
        }
    }
    std::map<std::string, Token> metadata;
    for (const auto& route : routes) {
        if (!valid_identifier(route.id) || !valid_identifier(route.venue_id) ||
            !valid_identifier(route.token_in) || !valid_identifier(route.token_out) ||
            route.token_in == route.token_out) {
            throw SearcherError("malformed route");
        }
        if (!metadata.contains(route.token_in)) {
            metadata.emplace(route.token_in, tokens_.get(route.token_in));
        }
        if (!metadata.contains(route.token_out)) {
            metadata.emplace(route.token_out, tokens_.get(route.token_out));
        }
    }
    config_.validate(metadata);

    std::size_t candidates = 0;
    for (const auto& first : routes) {
        auto sizes = input_sizes[first.token_in];
        std::sort(sizes.begin(), sizes.end());
        sizes.erase(std::unique(sizes.begin(), sizes.end()), sizes.end());
        if (sizes.empty() || sizes.size() > SearchConfig::hard_max_input_sizes) {
            throw SearcherError("input-size set is empty or exceeds hard bound");
        }
        for (const auto& second : routes) {
            if (first.venue_id == second.venue_id ||
                first.token_out != second.token_in ||
                first.token_in != second.token_out) {
                continue;
            }
            for (const Amount amount : sizes) {
                if (++candidates > config_.max_candidates_per_block) {
                    throw SearcherError("candidate set exceeds configured per-block bound");
                }
                Decision decision =
                    evaluate(first, second, amount, block, metadata);
                audit_.record_decision(decision, block);
                result.decisions.push_back(std::move(decision));
            }
        }
    }
    if (result.decisions.empty()) {
        throw SearcherError("no valid two-venue cyclic route pairs");
    }

    const ArbitragePlan* best = nullptr;
    for (const auto& decision : result.decisions) {
        if (!decision.plan.has_value()) {
            continue;
        }
        const auto& plan = *decision.plan;
        if (best == nullptr || plan.net_edge_bps > best->net_edge_bps ||
            (plan.net_edge_bps == best->net_edge_bps &&
             plan.input_token.id == best->input_token.id &&
             plan.expected_net > best->expected_net) ||
            (plan.net_edge_bps == best->net_edge_bps &&
             (plan.input_token.id != best->input_token.id ||
              plan.expected_net == best->expected_net) &&
             plan.id < best->id)) {
            best = &plan;
        }
    }
    if (best == nullptr) {
        return result;
    }

    const std::string day = utc_day(now);
    const std::string pnl_key = day + ":" + best->input_token.id;
    const SearcherSnapshot before_execution = audit_.load();
    const std::int64_t pnl = before_execution.daily_pnl.contains(pnl_key)
        ? before_execution.daily_pnl.at(pnl_key)
        : 0;
    const auto loss_limit =
        config_.daily_loss_limit_by_token.at(best->input_token.id);
    if (pnl <= -static_cast<std::int64_t>(loss_limit)) {
        audit_.latch_kill("daily_paper_loss", now);
        throw SearcherError("daily paper loss latch reached");
    }
    result.selected_plan = *best;
    if (!blocks_.is_canonical(block)) {
        audit_.record_incident("block_reorg_before_paper_execution", best->id, now);
        audit_.latch_kill("block_reorg", now);
        throw SearcherError("block became noncanonical before paper execution");
    }
    const std::int64_t execution_time = clock_.now_epoch_ms();
    if (execution_time > best->deadline_epoch_ms ||
        !fresh(block.observed_epoch_ms, execution_time, config_.max_block_age_ms) ||
        !fresh(
            best->first_quote_observed_epoch_ms,
            execution_time,
            config_.max_quote_age_ms) ||
        !fresh(
            best->second_quote_observed_epoch_ms,
            execution_time,
            config_.max_quote_age_ms) ||
        !fresh(
            best->gas_quote_observed_epoch_ms,
            execution_time,
            config_.max_quote_age_ms)) {
        audit_.record_incident("plan_expired_before_paper_execution", best->id, execution_time);
        return result;
    }
    if (!audit_.claim(*best)) {
        return result;
    }

    PaperResult paper;
    try {
        paper = executor_.execute(*best);
    } catch (const std::exception& error) {
        audit_.record_incident("paper_executor_error", best->id, now);
        audit_.latch_kill("paper_executor_error", now);
        throw SearcherError(std::string("paper executor failed: ") + error.what());
    }
    bool result_is_consistent = false;
    try {
        result_is_consistent =
            paper.realized_pnl == realized_delta(paper.final_amount, best->amount_in);
    } catch (const SearcherError&) {
        result_is_consistent = false;
    }
    if (paper.plan_id != best->id || paper.settled_epoch_ms < execution_time ||
        !result_is_consistent ||
        (!paper.incident.empty() && !valid_audit_text(paper.incident))) {
        audit_.record_incident("malformed_paper_result", best->id, now);
        audit_.latch_kill("malformed_paper_result", now);
        throw SearcherError("paper executor returned malformed result");
    }
    audit_.record_paper_result(paper, day, best->input_token.id);
    const SearcherSnapshot after_result = audit_.load();
    const std::int64_t updated_pnl = after_result.daily_pnl.contains(pnl_key)
        ? after_result.daily_pnl.at(pnl_key)
        : 0;
    if (updated_pnl <= -static_cast<std::int64_t>(loss_limit)) {
        audit_.latch_kill("daily_paper_loss", paper.settled_epoch_ms);
    }
    if (!paper.atomic || !paper.first_leg_filled || !paper.second_leg_filled ||
        !paper.incident.empty()) {
        const std::string incident =
            paper.incident.empty() ? "non_atomic_or_partial_paper_cycle" : paper.incident;
        audit_.record_incident(incident, best->id, paper.settled_epoch_ms);
        audit_.latch_kill("paper_execution_incident", paper.settled_epoch_ms);
    }
    audit_.complete(best->id);
    result.paper_result = std::move(paper);
    return result;
}

std::string utc_day(std::int64_t epoch_ms) {
    if (epoch_ms < 0) {
        throw SearcherError("negative epoch time");
    }
    const std::int64_t days = epoch_ms / 86'400'000;
    std::int64_t z = days + 719468;
    const std::int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned day_of_era = static_cast<unsigned>(z - era * 146097);
    const unsigned year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 -
         day_of_era / 146096) /
        365;
    std::int64_t year = static_cast<std::int64_t>(year_of_era) + era * 400;
    const unsigned day_of_year =
        day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const unsigned month_prime = (5 * day_of_year + 2) / 153;
    const unsigned day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    const unsigned month = month_prime < 10 ? month_prime + 3 : month_prime - 9;
    year += month <= 2;
    std::ostringstream output;
    output << std::setw(4) << std::setfill('0') << year << '-'
           << std::setw(2) << month << '-' << std::setw(2) << day;
    return output.str();
}

}  // namespace godbrain::polygon
