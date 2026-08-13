#include "polymarket/paper.hpp"

#include <algorithm>
#include <charconv>
#include <cstdlib>
#include <ctime>
#include <iomanip>
#include <limits>
#include <sstream>

namespace polymarket::paper {
namespace {

constexpr Decimal zero = Decimal::from_raw(0);
constexpr Decimal one = Decimal::from_raw(Decimal::scale);
constexpr std::int64_t basis_points = 10'000;

bool is_fresh(const Book& book, std::int64_t now_ms, std::int64_t maximum_age_ms) {
    const std::int64_t age = now_ms - book.observed_epoch_ms;
    return age >= 0 && age <= maximum_age_ms;
}

bool book_matches(const Book& book, const Market& market, const std::string& token_id) {
    return book.token_id == token_id && book.condition_id == market.condition_id &&
        book.tick_size == market.tick_size && book.min_order_size == market.min_order_size;
}

std::int64_t checked_add(std::int64_t left, std::int64_t right) {
    if ((right > 0 && left > std::numeric_limits<std::int64_t>::max() - right) ||
        (right < 0 && left < std::numeric_limits<std::int64_t>::min() - right)) {
        throw PaperError("fixed-point addition overflow");
    }
    return left + right;
}

std::int64_t checked_mul(std::int64_t left, std::int64_t right) {
    bool overflow = false;
    if (left > 0) {
        overflow = right > 0
            ? left > std::numeric_limits<std::int64_t>::max() / right
            : right < std::numeric_limits<std::int64_t>::min() / left;
    } else if (left < 0) {
        overflow = right > 0
            ? left < std::numeric_limits<std::int64_t>::min() / right
            : right < 0 && left < std::numeric_limits<std::int64_t>::max() / right;
    }
    if (overflow) {
        throw PaperError("fixed-point multiplication overflow");
    }
    return left * right;
}

Decimal walk(
    const std::vector<Level>& levels,
    Decimal requested,
    bool buying,
    Decimal fee_rate,
    std::int64_t slippage_bps,
    Decimal* filled,
    Decimal* fees) {
    Decimal remaining = requested;
    Decimal notional = zero;
    *filled = zero;
    *fees = zero;
    for (const auto& level : levels) {
        if (remaining <= zero) {
            break;
        }
        const Decimal take =
            Decimal::from_raw(std::min(remaining.raw(), level.size.raw()));
        Decimal adjusted = level.price;
        if (slippage_bps > 0) {
            const Decimal buffer = Decimal::from_raw(
                (level.price.raw() * slippage_bps + basis_points - 1) / basis_points);
            adjusted = buying ? level.price + buffer : level.price - buffer;
        }
        if (adjusted <= zero || adjusted >= one) {
            break;
        }
        notional = notional +
            (buying ? multiply_up(take, adjusted) : multiply_down(take, adjusted));
        Decimal fee = multiply_up(
            multiply_up(multiply_up(take, fee_rate), adjusted),
            one - adjusted);
        if (fee > zero) {
            constexpr std::int64_t fee_quantum = 10;  // Official fees round to 5 decimals.
            fee = Decimal::from_raw(
                ((fee.raw() + fee_quantum - 1) / fee_quantum) * fee_quantum);
        }
        *fees = *fees + fee;
        *filled = *filled + take;
        remaining = remaining - take;
    }
    return notional;
}

Decimal acquisition_cost(
    const Book& yes,
    const Book& no,
    Decimal quantity,
    const StrategyConfig& config,
    Decimal* yes_cost,
    Decimal* no_cost,
    Decimal* fees,
    Decimal* slippage) {
    Decimal yes_filled;
    Decimal no_filled;
    Decimal yes_fees;
    Decimal no_fees;
    *yes_cost = walk(
        yes.asks, quantity, true, config.fee_rate, 0, &yes_filled, &yes_fees);
    *no_cost = walk(
        no.asks, quantity, true, config.fee_rate, 0, &no_filled, &no_fees);
    if (yes_filled != quantity || no_filled != quantity) {
        throw PaperError("insufficient book depth");
    }
    const Decimal raw = *yes_cost + *no_cost;
    *fees = yes_fees + no_fees;
    *slippage = Decimal::from_raw(
        (raw.raw() * config.slippage_bps_per_leg + basis_points - 1) / basis_points);
    return raw + *fees + *slippage;
}

Decimal prorate_up(Decimal total, Decimal part, Decimal whole) {
    if (part < zero || whole <= zero || part > whole) {
        throw PaperError("invalid fixed-point proration");
    }
    return Decimal::from_raw(
        (total.raw() * part.raw() + whole.raw() - 1) / whole.raw());
}

std::string getenv_string(const char* key, std::string fallback) {
    const char* value = std::getenv(key);
    return value != nullptr && *value != '\0' ? std::string(value) : std::move(fallback);
}

std::int64_t getenv_i64(const char* key, std::int64_t fallback) {
    const std::string value = getenv_string(key, "");
    if (value.empty()) {
        return fallback;
    }
    std::int64_t parsed = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
        throw PaperError(std::string(key) + " must be an integer");
    }
    return parsed;
}

Decimal getenv_decimal(const char* key, std::string_view fallback) {
    return Decimal::parse(getenv_string(key, std::string(fallback)));
}

Json opportunity_json(const Opportunity& opportunity) {
    return {
        {"opportunity_id", opportunity.id},
        {"market_id", opportunity.market.id},
        {"condition_id", opportunity.market.condition_id},
        {"quantity", opportunity.quantity.str()},
        {"yes_cost", opportunity.yes_cost.str()},
        {"no_cost", opportunity.no_cost.str()},
        {"fee_reserve", opportunity.fee_reserve.str()},
        {"slippage_reserve", opportunity.slippage_reserve.str()},
        {"all_in_cost", opportunity.all_in_cost.str()},
        {"merge_value", opportunity.merge_value.str()},
        {"expected_profit", opportunity.expected_profit.str()},
        {"net_edge", opportunity.net_edge.str()},
        {"yes_book_hash", opportunity.yes_book_hash},
        {"no_book_hash", opportunity.no_book_hash},
        {"evaluated_epoch_ms", opportunity.evaluated_epoch_ms},
    };
}

}  // namespace

Decimal Decimal::parse(std::string_view text, bool round_up) {
    if (text.empty()) {
        throw PaperError("empty decimal");
    }
    const std::size_t exponent_marker = text.find_first_of("eE");
    if (exponent_marker != std::string_view::npos) {
        if (text.find_first_of("eE", exponent_marker + 1) != std::string_view::npos) {
            throw PaperError("invalid decimal exponent");
        }
        const std::string_view mantissa = text.substr(0, exponent_marker);
        const std::string_view exponent_text = text.substr(exponent_marker + 1);
        int exponent = 0;
        const auto exponent_result = std::from_chars(
            exponent_text.data(), exponent_text.data() + exponent_text.size(), exponent);
        if (exponent_text.empty() || exponent_result.ec != std::errc{} ||
            exponent_result.ptr != exponent_text.data() + exponent_text.size() ||
            exponent < -18 || exponent > 18) {
            throw PaperError("invalid decimal exponent");
        }

        bool negative_exponent_value = false;
        std::size_t mantissa_index = 0;
        if (!mantissa.empty() && (mantissa.front() == '-' || mantissa.front() == '+')) {
            negative_exponent_value = mantissa.front() == '-';
            mantissa_index = 1;
        }
        std::string digits;
        std::size_t integer_digits = 0;
        bool decimal_seen = false;
        for (; mantissa_index < mantissa.size(); ++mantissa_index) {
            const char character = mantissa[mantissa_index];
            if (character == '.' && !decimal_seen) {
                decimal_seen = true;
                integer_digits = digits.size();
                continue;
            }
            if (character < '0' || character > '9') {
                throw PaperError("invalid decimal mantissa");
            }
            digits.push_back(character);
        }
        if (!decimal_seen) {
            integer_digits = digits.size();
        }
        if (digits.empty()) {
            throw PaperError("invalid decimal mantissa");
        }
        const auto shifted = static_cast<long long>(integer_digits) + exponent;
        std::string normalized = negative_exponent_value ? "-" : "";
        if (shifted <= 0) {
            normalized += "0.";
            normalized.append(static_cast<std::size_t>(-shifted), '0');
            normalized += digits;
        } else if (static_cast<std::size_t>(shifted) >= digits.size()) {
            normalized += digits;
            normalized.append(static_cast<std::size_t>(shifted) - digits.size(), '0');
        } else {
            normalized.append(digits, 0, static_cast<std::size_t>(shifted));
            normalized.push_back('.');
            normalized.append(digits, static_cast<std::size_t>(shifted), std::string::npos);
        }
        return Decimal::parse(normalized, round_up);
    }
    bool negative = false;
    std::size_t index = 0;
    if (text.front() == '-') {
        negative = true;
        index = 1;
    } else if (text.front() == '+') {
        index = 1;
    }
    if (index == text.size()) {
        throw PaperError("invalid decimal");
    }

    std::int64_t whole = 0;
    bool saw_digit = false;
    while (index < text.size() && text[index] != '.') {
        const char value = text[index++];
        if (value < '0' || value > '9') {
            throw PaperError("invalid decimal");
        }
        saw_digit = true;
        if (whole > 1'000'000'000LL) {
            throw PaperError("decimal exceeds supported range");
        }
        whole = whole * 10 + (value - '0');
    }
    std::int64_t fraction = 0;
    int digits = 0;
    bool discarded_nonzero = false;
    if (index < text.size() && text[index] == '.') {
        ++index;
        while (index < text.size()) {
            const char value = text[index++];
            if (value < '0' || value > '9') {
                throw PaperError("invalid decimal");
            }
            saw_digit = true;
            if (digits < 6) {
                fraction = fraction * 10 + (value - '0');
                ++digits;
            } else if (value != '0') {
                discarded_nonzero = true;
            }
        }
    }
    if (!saw_digit) {
        throw PaperError("invalid decimal");
    }
    while (digits++ < 6) {
        fraction *= 10;
    }
    std::int64_t raw = checked_add(checked_mul(whole, scale), fraction);
    if (round_up && discarded_nonzero) {
        raw = checked_add(raw, 1);
    }
    return Decimal::from_raw(negative ? -raw : raw);
}

std::string Decimal::str() const {
    const bool negative = raw_ < 0;
    const std::uint64_t absolute =
        negative ? static_cast<std::uint64_t>(-(raw_ + 1)) + 1 : static_cast<std::uint64_t>(raw_);
    const auto whole = absolute / scale;
    const auto fraction = absolute % scale;
    std::ostringstream output;
    if (negative) {
        output << '-';
    }
    output << whole;
    if (fraction != 0) {
        output << '.' << std::setw(6) << std::setfill('0') << fraction;
        std::string text = output.str();
        while (text.back() == '0') {
            text.pop_back();
        }
        return text;
    }
    return output.str();
}

Decimal operator+(Decimal left, Decimal right) {
    return Decimal::from_raw(checked_add(left.raw(), right.raw()));
}

Decimal operator-(Decimal left, Decimal right) {
    return Decimal::from_raw(checked_add(left.raw(), -right.raw()));
}

Decimal operator*(Decimal left, std::int64_t right) {
    return Decimal::from_raw(checked_mul(left.raw(), right));
}

Decimal operator/(Decimal left, std::int64_t right) {
    if (right == 0) {
        throw PaperError("division by zero");
    }
    return Decimal::from_raw(left.raw() / right);
}

Decimal multiply_down(Decimal left, Decimal right) {
    return Decimal::from_raw(checked_mul(left.raw(), right.raw()) / Decimal::scale);
}

Decimal multiply_up(Decimal left, Decimal right) {
    const auto product = checked_mul(left.raw(), right.raw());
    return Decimal::from_raw((product + Decimal::scale - 1) / Decimal::scale);
}

Decimal ratio_down(Decimal numerator, Decimal denominator) {
    if (denominator <= zero) {
        throw PaperError("ratio denominator must be positive");
    }
    return Decimal::from_raw(
        checked_mul(numerator.raw(), Decimal::scale) / denominator.raw());
}

bool Market::supported() const {
    return !id.empty() && !condition_id.empty() && !question.empty() &&
        !yes_token_id.empty() && !no_token_id.empty() && yes_token_id != no_token_id &&
        accepting_orders && active && !closed && !archived && !restricted &&
        order_book_enabled && !negative_risk && tick_size > zero && min_order_size > zero;
}

Evaluation evaluate_pair(
    const Market& market,
    const Book& yes,
    const Book& no,
    std::int64_t now_epoch_ms,
    const StrategyConfig& config) {
    if (!market.supported()) {
        return {.rejection = "unsupported_market"};
    }
    if (yes.token_id != market.yes_token_id || no.token_id != market.no_token_id ||
        yes.condition_id != market.condition_id || no.condition_id != market.condition_id) {
        return {.rejection = "token_mismatch"};
    }
    if (yes.asks.empty() || no.asks.empty()) {
        return {.rejection = "missing_asks"};
    }
    const auto yes_age = now_epoch_ms - yes.observed_epoch_ms;
    const auto no_age = now_epoch_ms - no.observed_epoch_ms;
    if (yes_age < 0 || no_age < 0 || yes_age > config.stale_book_ms ||
        no_age > config.stale_book_ms) {
        return {.rejection = "stale_book"};
    }
    if (yes.tick_size != market.tick_size || no.tick_size != market.tick_size ||
        yes.min_order_size != market.min_order_size ||
        no.min_order_size != market.min_order_size) {
        return {.rejection = "market_constraints_changed"};
    }

    Decimal yes_depth;
    for (const auto& level : yes.asks) {
        yes_depth = yes_depth + level.size;
    }
    Decimal no_depth;
    for (const auto& level : no.asks) {
        no_depth = no_depth + level.size;
    }
    Decimal high = Decimal::from_raw(std::min(yes_depth.raw(), no_depth.raw()));
    if (high < market.min_order_size) {
        return {.rejection = "insufficient_depth"};
    }

    Decimal low = market.min_order_size;
    Decimal best = zero;
    while (low <= high) {
        const Decimal candidate =
            Decimal::from_raw(low.raw() + (high.raw() - low.raw()) / 2);
        Decimal yes_cost;
        Decimal no_cost;
        Decimal fees;
        Decimal slippage;
        const Decimal all_in = acquisition_cost(
            yes, no, candidate, config, &yes_cost, &no_cost, &fees, &slippage);
        if (all_in <= config.max_pair_gross) {
            best = candidate;
            low = Decimal::from_raw(candidate.raw() + 1);
        } else {
            high = Decimal::from_raw(candidate.raw() - 1);
        }
    }
    if (best < market.min_order_size) {
        return {.rejection = "pair_cap"};
    }

    Decimal yes_cost;
    Decimal no_cost;
    Decimal fees;
    Decimal slippage;
    const Decimal all_in =
        acquisition_cost(yes, no, best, config, &yes_cost, &no_cost, &fees, &slippage);
    const Decimal merge_value = best;
    const Decimal profit = merge_value - all_in;
    const Decimal edge = profit > zero ? ratio_down(profit, all_in) : zero;
    if (edge < config.min_net_edge) {
        return {.rejection = "edge_below_threshold"};
    }

    const std::string id = market.id + ":" + yes.hash + ":" + no.hash + ":" + best.str();
    return {
        .opportunity = Opportunity{
            .id = id,
            .market = market,
            .quantity = best,
            .yes_cost = yes_cost,
            .no_cost = no_cost,
            .fee_reserve = fees,
            .slippage_reserve = slippage,
            .all_in_cost = all_in,
            .merge_value = merge_value,
            .expected_profit = profit,
            .net_edge = edge,
            .evaluated_epoch_ms = now_epoch_ms,
            .yes_book_hash = yes.hash,
            .no_book_hash = no.hash,
        },
    };
}

TimePoint SystemClock::now() const {
    return std::chrono::system_clock::now();
}

Config Config::from_environment() {
    Config config;
    if (std::getenv("POLYMARKET_LIVE_ENABLED") != nullptr ||
        std::getenv("POLYMARKET_PRIVATE_KEY") != nullptr ||
        std::getenv("POLYMARKET_API_KEY") != nullptr ||
        std::getenv("POLYMARKET_API_SECRET") != nullptr ||
        std::getenv("POLYMARKET_API_PASSPHRASE") != nullptr ||
        std::getenv("POLYMARKET_FUNDER_ADDRESS") != nullptr ||
        std::getenv("POLYMARKET_WALLET_ADDRESS") != nullptr) {
        throw PaperError("live or credential environment variables are forbidden");
    }
    config.max_pair_gross = getenv_decimal("POLYMARKET_PAPER_MAX_PAIR_GROSS", "5");
    config.max_total_exposure = getenv_decimal("POLYMARKET_PAPER_MAX_TOTAL_EXPOSURE", "10");
    config.max_daily_loss = getenv_decimal("POLYMARKET_PAPER_MAX_DAILY_LOSS", "5");
    config.strategy.max_pair_gross = config.max_pair_gross;
    config.strategy.min_net_edge = getenv_decimal("POLYMARKET_PAPER_MIN_NET_EDGE", "0.02");
    config.strategy.fee_rate =
        getenv_decimal("POLYMARKET_PAPER_FEE_RATE", "0.07");
    config.strategy.slippage_bps_per_leg =
        getenv_i64("POLYMARKET_PAPER_SLIPPAGE_BPS_PER_LEG", 50);
    config.strategy.stale_book_ms = getenv_i64("POLYMARKET_PAPER_STALE_BOOK_MS", 2'000);
    config.strategy.settlement_delay_ms =
        getenv_i64("POLYMARKET_PAPER_SETTLEMENT_DELAY_MS", 30'000);
    config.discovery.page_size = static_cast<std::size_t>(
        getenv_i64("POLYMARKET_PAPER_DISCOVERY_PAGE_SIZE", 50));
    config.discovery.max_pages = static_cast<std::size_t>(
        getenv_i64("POLYMARKET_PAPER_DISCOVERY_MAX_PAGES", 1));
    config.scan_interval_ms = getenv_i64("POLYMARKET_PAPER_SCAN_INTERVAL_MS", 3'000);
    config.state_directory =
        getenv_string("POLYMARKET_PAPER_STATE_DIR", "polymarket-paper-state");
    const std::string kill_file = getenv_string("POLYMARKET_PAPER_KILL_SWITCH_FILE", "");
    if (!kill_file.empty()) {
        config.kill_switch_file = std::filesystem::path(kill_file);
    }
    config.startup_kill =
        getenv_string("POLYMARKET_PAPER_KILL_SWITCH", "0") == "1";
    config.validate();
    return config;
}

void Config::validate() const {
    if (max_pair_gross <= zero || max_pair_gross.raw() > hard_pair_micros) {
        throw PaperError("paper pair cap must be in (0, 5] pUSD");
    }
    if (max_total_exposure <= zero || max_total_exposure.raw() > hard_total_micros) {
        throw PaperError("paper total exposure cap must be in (0, 10] pUSD");
    }
    if (max_daily_loss <= zero || max_daily_loss.raw() > hard_daily_loss_micros) {
        throw PaperError("paper daily loss cap must be in (0, 5] pUSD");
    }
    if (strategy.max_pair_gross != max_pair_gross) {
        throw PaperError("strategy and risk pair caps must match");
    }
    if (strategy.min_net_edge < Decimal::parse("0.02") ||
        strategy.min_net_edge > Decimal::parse("0.25")) {
        throw PaperError("minimum edge must be between 2% and 25%");
    }
    if (strategy.fee_rate < zero || strategy.fee_rate > Decimal::parse("0.25") ||
        strategy.slippage_bps_per_leg < 0 || strategy.slippage_bps_per_leg > 500) {
        throw PaperError("fee or slippage reserve is out of bounds");
    }
    if (strategy.stale_book_ms <= 0 || strategy.stale_book_ms > 10'000 ||
        strategy.settlement_delay_ms < 0) {
        throw PaperError("invalid freshness or settlement delay");
    }
    if (discovery.page_size == 0 || discovery.page_size > 100 ||
        discovery.max_pages == 0 || discovery.max_pages > 20) {
        throw PaperError("discovery bounds exceed safe limits");
    }
    if (scan_interval_ms < 1'000) {
        throw PaperError("scan interval must be at least one second");
    }
    const auto books_per_scan = static_cast<std::int64_t>(
        discovery.page_size * discovery.max_pages * 2);
    if (books_per_scan * 10'000 > scan_interval_ms * 1'000) {
        throw PaperError("discovery and scan interval exceed conservative public rate budget");
    }
    if (state_directory.empty()) {
        throw PaperError("paper state directory cannot be empty");
    }
}

SimulatedFill ConservativeFillModel::buy(
    const Book& fresh_book,
    Decimal requested,
    Decimal fee_rate,
    std::int64_t slippage_bps) {
    Decimal filled;
    Decimal fees;
    const Decimal notional = walk(
        fresh_book.asks, requested, true, fee_rate, slippage_bps, &filled, &fees);
    return {
        .quantity = filled,
        .notional = notional,
        .fee = fees,
        .complete = filled == requested,
        .reason = filled == requested ? "filled" : "insufficient_ask_depth",
    };
}

SimulatedFill ConservativeFillModel::sell(
    const Book& fresh_book,
    Decimal requested,
    Decimal fee_rate,
    std::int64_t slippage_bps) {
    Decimal filled;
    Decimal fees;
    const Decimal notional = walk(
        fresh_book.bids, requested, false, fee_rate, slippage_bps, &filled, &fees);
    return {
        .quantity = filled,
        .notional = notional,
        .fee = fees,
        .complete = filled == requested,
        .reason = filled == requested ? "filled" : "insufficient_bid_depth",
    };
}

PaperEngine::PaperEngine(
    Config config,
    PublicApi& api,
    Repository& repository,
    FillModel& fill_model,
    Clock& clock)
    : config_(std::move(config)),
      api_(api),
      repository_(repository),
      fill_model_(fill_model),
      clock_(clock) {
    config_.validate();
}

void PaperEngine::initialize() {
    repository_.initialize();
    const auto now_ms = epoch_ms(clock_.now());
    const auto day = utc_day(now_ms);
    Snapshot snapshot = repository_.load();
    if (snapshot.kill.active && snapshot.kill.reason == "daily_loss" &&
        snapshot.kill.trading_day < day) {
        repository_.clear_utc_rollover(day, now_ms);
        snapshot = repository_.load();
    }
    std::error_code kill_file_error;
    const bool file_kill = config_.kill_switch_file &&
        std::filesystem::exists(*config_.kill_switch_file, kill_file_error);
    if (kill_file_error) {
        throw PaperError("cannot inspect paper kill-switch file");
    }
    if (config_.startup_kill || file_kill) {
        repository_.latch_kill("operator", day, now_ms);
    }
    if (!snapshot.pending_opportunities.empty()) {
        repository_.record_event("reconciliation_incident", {
            {"reason", "interrupted_pending_cycle"},
            {"pending_opportunities", snapshot.pending_opportunities},
        });
        repository_.latch_kill("reconciliation_failure", day, now_ms);
    }
    repository_.reconcile(now_ms);
    initialized_ = true;
    refresh_health(now_ms);
}

void PaperEngine::scan_once() {
    if (!initialized_) {
        throw PaperError("engine must be initialized");
    }
    const auto now_ms = epoch_ms(clock_.now());
    const auto day = utc_day(now_ms);
    health_.scanning = true;
    health_.last_error.clear();
    try {
        Snapshot snapshot = repository_.load();
        std::error_code kill_file_error;
        if (config_.kill_switch_file &&
            std::filesystem::exists(*config_.kill_switch_file, kill_file_error)) {
            repository_.latch_kill("operator", day, now_ms);
            snapshot = repository_.load();
        }
        if (kill_file_error) {
            throw PaperError("cannot inspect paper kill-switch file");
        }
        if (snapshot.kill.active && snapshot.kill.reason == "daily_loss" &&
            snapshot.kill.trading_day < day) {
            repository_.clear_utc_rollover(day, now_ms);
            snapshot = repository_.load();
        }
        settle_due(now_ms, day);
        snapshot = repository_.load();
        if (snapshot.kill.active) {
            refresh_health(now_ms);
            health_.scanning = false;
            return;
        }
        const Decimal day_pnl = snapshot.realized_pnl.contains(day)
            ? snapshot.realized_pnl.at(day)
            : zero;
        if (day_pnl <= Decimal::from_raw(-config_.max_daily_loss.raw())) {
            repository_.latch_kill("daily_loss", day, now_ms);
            refresh_health(now_ms);
            health_.scanning = false;
            return;
        }

        for (const auto& market : api_.discover_binary_markets()) {
            const Book yes = api_.order_book(market.yes_token_id);
            const Book no = api_.order_book(market.no_token_id);
            const auto evaluation_ms = epoch_ms(clock_.now());
            const Evaluation evaluation =
                evaluate_pair(market, yes, no, evaluation_ms, config_.strategy);
            if (!evaluation.opportunity) {
                repository_.record_event("opportunity_rejected", {
                    {"market_id", market.id},
                    {"reason", evaluation.rejection},
                    {"evaluated_epoch_ms", now_ms},
                });
                continue;
            }
            const Opportunity& opportunity = *evaluation.opportunity;
            snapshot = repository_.load();
            if (exposure(snapshot) + opportunity.all_in_cost >
                config_.max_total_exposure) {
                repository_.record_event("risk_rejected", {
                    {"opportunity_id", opportunity.id},
                    {"reason", "total_exposure_cap"},
                    {"exposure", exposure(snapshot).str()},
                    {"prospective", opportunity.all_in_cost.str()},
                });
                continue;
            }
            if (!repository_.claim(opportunity)) {
                repository_.record_event("duplicate_suppressed", {
                    {"opportunity_id", opportunity.id},
                });
                continue;
            }
            repository_.record_event("opportunity_detected", opportunity_json(opportunity));
            try {
                simulate(opportunity, evaluation_ms, day);
                repository_.complete_claim(opportunity.id);
            } catch (...) {
                repository_.latch_kill("reconciliation_failure", day, evaluation_ms);
                throw;
            }
            break;  // One non-atomic paper cycle at a time.
        }
        repository_.reconcile(now_ms);
        refresh_health(now_ms);
        health_.data_fresh = true;
    } catch (const std::exception& error) {
        health_.last_error = error.what();
        health_.data_fresh = false;
        health_.reconciliation_ok = false;
        health_.updated_epoch_ms = now_ms;
        health_.scanning = false;
        throw;
    }
    health_.scanning = false;
}

void PaperEngine::simulate(
    const Opportunity& opportunity,
    std::int64_t now_ms,
    const std::string& day) {
    repository_.record_event("paper_intent", opportunity_json(opportunity));
    const Decimal starting_exposure = exposure(repository_.load());

    const Book yes_fresh = api_.order_book(opportunity.market.yes_token_id);
    const auto yes_check_ms = epoch_ms(clock_.now());
    if (!book_matches(
            yes_fresh, opportunity.market, opportunity.market.yes_token_id) ||
        !is_fresh(yes_fresh, yes_check_ms, config_.strategy.stale_book_ms)) {
        repository_.record_event("paper_intent_rejected", {
            {"opportunity_id", opportunity.id},
            {"reason", "stale_yes_before_leg"},
        });
        return;
    }
    const SimulatedFill yes = fill_model_.buy(
        yes_fresh,
        opportunity.quantity,
        config_.strategy.fee_rate,
        config_.strategy.slippage_bps_per_leg);
    const Decimal yes_fee = yes.fee;
    const Decimal yes_cost = yes.notional + yes_fee;
    repository_.record_event("paper_fill", {
        {"opportunity_id", opportunity.id},
        {"leg", "YES"},
        {"quantity", yes.quantity.str()},
        {"notional", yes.notional.str()},
        {"fee", yes_fee.str()},
        {"all_in_cost", yes_cost.str()},
        {"complete", yes.complete},
        {"reason", yes.reason},
    });
    if (yes_cost > config_.max_pair_gross ||
        starting_exposure + yes_cost > config_.max_total_exposure) {
        repository_.record_event("paper_fill_rejected", {
            {"opportunity_id", opportunity.id},
            {"leg", "YES"},
            {"reason", "fresh_fill_risk_cap"},
            {"projected_cost", yes_cost.str()},
            {"starting_exposure", starting_exposure.str()},
        });
        return;
    }
    if (!yes.complete) {
        if (yes.quantity > zero) {
            const Book recovery_book = api_.order_book(opportunity.market.yes_token_id);
            const auto recovery_check_ms = epoch_ms(clock_.now());
            const bool recovery_stale =
                !book_matches(
                    recovery_book, opportunity.market, opportunity.market.yes_token_id) ||
                !is_fresh(
                    recovery_book, recovery_check_ms, config_.strategy.stale_book_ms);
            const SimulatedFill recovery = recovery_stale
                ? SimulatedFill{.reason = "stale_recovery_book"}
                : fill_model_.sell(
                      recovery_book,
                      yes.quantity,
                      config_.strategy.fee_rate,
                      config_.strategy.slippage_bps_per_leg);
            const Decimal recovery_fee = recovery.fee;
            const Decimal net_proceeds = recovery.notional - recovery_fee;
            const Decimal recovered_cost =
                prorate_up(yes_cost, recovery.quantity, yes.quantity);
            const Decimal recovery_pnl = net_proceeds - recovered_cost;
            repository_.record_event("paper_recovery", {
                {"opportunity_id", opportunity.id},
                {"source", "partial_first_leg"},
                {"quantity", recovery.quantity.str()},
                {"notional", recovery.notional.str()},
                {"fee", recovery_fee.str()},
                {"complete", recovery.complete},
                {"realized_pnl", recovery_pnl.str()},
            });
            if (recovery.quantity > zero) {
                repository_.record_pnl(
                    opportunity.id + ":first-leg-recovery",
                    day,
                    recovery_pnl,
                    now_ms);
            }
            const Decimal stranded = yes.quantity - recovery.quantity;
            if (stranded > zero) {
                repository_.save_position({
                    .id = opportunity.id + ":stranded-first",
                    .opportunity_id = opportunity.id,
                    .market_id = opportunity.market.id,
                    .condition_id = opportunity.market.condition_id,
                    .quantity = stranded,
                    .acquisition_cost = yes_cost - recovered_cost,
                    .yes_quantity = stranded,
                    .no_quantity = zero,
                    .opened_epoch_ms = now_ms,
                    .settle_after_epoch_ms = 0,
                    .state = PositionState::stranded,
                });
            }
            repository_.latch_kill("non_atomic_leg_failure", day, now_ms);
        }
        repository_.record_event("paper_cycle_rejected", {
            {"opportunity_id", opportunity.id},
            {"reason", "first_leg_incomplete"},
        });
        return;
    }

    const Book no_fresh = api_.order_book(opportunity.market.no_token_id);
    const auto no_check_ms = epoch_ms(clock_.now());
    const bool no_stale =
        !book_matches(no_fresh, opportunity.market, opportunity.market.no_token_id) ||
        !is_fresh(no_fresh, no_check_ms, config_.strategy.stale_book_ms);
    SimulatedFill no = no_stale
        ? SimulatedFill{.reason = "stale_no_before_leg"}
        : fill_model_.buy(
              no_fresh,
              opportunity.quantity,
              config_.strategy.fee_rate,
              config_.strategy.slippage_bps_per_leg);
    Decimal no_fee = no.fee;
    Decimal no_cost = no.notional + no_fee;
    if (no_cost > zero &&
        (yes_cost + no_cost > config_.max_pair_gross ||
         starting_exposure + yes_cost + no_cost > config_.max_total_exposure)) {
        repository_.record_event("paper_fill_rejected", {
            {"opportunity_id", opportunity.id},
            {"leg", "NO"},
            {"reason", "fresh_fill_risk_cap"},
            {"projected_quantity", no.quantity.str()},
            {"projected_cost", no_cost.str()},
            {"first_leg_cost", yes_cost.str()},
            {"starting_exposure", starting_exposure.str()},
        });
        no = {
            .reason = "fresh_fill_risk_cap",
        };
        no_fee = zero;
        no_cost = zero;
    }
    repository_.record_event("paper_fill", {
        {"opportunity_id", opportunity.id},
        {"leg", "NO"},
        {"quantity", no.quantity.str()},
        {"notional", no.notional.str()},
        {"fee", no_fee.str()},
        {"all_in_cost", no_cost.str()},
        {"complete", no.complete},
        {"reason", no.reason},
    });

    if (!no.complete) {
        const Decimal matched = Decimal::from_raw(
            std::min(yes.quantity.raw(), no.quantity.raw()));
        const Decimal matched_yes_cost = prorate_up(yes_cost, matched, yes.quantity);
        if (matched > zero) {
            repository_.save_position({
                .id = opportunity.id + ":paired-partial",
                .opportunity_id = opportunity.id,
                .market_id = opportunity.market.id,
                .condition_id = opportunity.market.condition_id,
                .quantity = matched,
                .acquisition_cost = matched_yes_cost + no_cost,
                .yes_quantity = matched,
                .no_quantity = matched,
                .opened_epoch_ms = now_ms,
                .settle_after_epoch_ms = now_ms + config_.strategy.settlement_delay_ms,
                .state = PositionState::paired,
            });
        }

        const Decimal excess_yes = yes.quantity - matched;
        SimulatedFill recovery{.complete = true, .reason = "no_excess"};
        if (excess_yes > zero) {
            const Book recovery_book = api_.order_book(opportunity.market.yes_token_id);
            const auto recovery_check_ms = epoch_ms(clock_.now());
            const bool recovery_stale =
                !book_matches(
                    recovery_book, opportunity.market, opportunity.market.yes_token_id) ||
                !is_fresh(
                    recovery_book, recovery_check_ms, config_.strategy.stale_book_ms);
            recovery = recovery_stale
                ? SimulatedFill{.reason = "stale_recovery_book"}
                : fill_model_.sell(
                      recovery_book,
                      excess_yes,
                      config_.strategy.fee_rate,
                      config_.strategy.slippage_bps_per_leg);
        }
        const Decimal recovery_fee = recovery.fee;
        const Decimal recovery_source_cost = yes_cost - matched_yes_cost;
        const Decimal recovered_cost = excess_yes > zero
            ? prorate_up(recovery_source_cost, recovery.quantity, excess_yes)
            : zero;
        const Decimal recovery_pnl =
            recovery.notional - recovery_fee - recovered_cost;
        repository_.record_event("paper_recovery", {
            {"opportunity_id", opportunity.id},
            {"source", "second_leg_failure"},
            {"quantity", recovery.quantity.str()},
            {"notional", recovery.notional.str()},
            {"fee", recovery_fee.str()},
            {"complete", recovery.complete},
            {"realized_pnl", recovery_pnl.str()},
        });
        if (recovery.quantity > zero) {
            repository_.record_pnl(
                opportunity.id + ":recovery", day, recovery_pnl, now_ms);
        }
        const Decimal stranded = excess_yes - recovery.quantity;
        if (stranded > zero) {
            repository_.save_position({
                .id = opportunity.id + ":stranded",
                .opportunity_id = opportunity.id,
                .market_id = opportunity.market.id,
                .condition_id = opportunity.market.condition_id,
                .quantity = stranded,
                .acquisition_cost = recovery_source_cost - recovered_cost,
                .yes_quantity = stranded,
                .no_quantity = zero,
                .opened_epoch_ms = now_ms,
                .settle_after_epoch_ms = 0,
                .state = PositionState::stranded,
            });
        }
        repository_.latch_kill("non_atomic_leg_failure", day, now_ms);
        return;
    }

    repository_.save_position({
        .id = opportunity.id + ":paired",
        .opportunity_id = opportunity.id,
        .market_id = opportunity.market.id,
        .condition_id = opportunity.market.condition_id,
        .quantity = opportunity.quantity,
        .acquisition_cost = yes_cost + no_cost,
        .yes_quantity = yes.quantity,
        .no_quantity = no.quantity,
        .opened_epoch_ms = now_ms,
        .settle_after_epoch_ms = now_ms + config_.strategy.settlement_delay_ms,
        .state = PositionState::paired,
    });
}

void PaperEngine::settle_due(std::int64_t now_ms, const std::string& day) {
    const Snapshot snapshot = repository_.load();
    for (auto position : snapshot.positions) {
        if (position.state != PositionState::paired ||
            position.settle_after_epoch_ms > now_ms) {
            continue;
        }
        const Decimal matched = Decimal::from_raw(
            std::min(position.yes_quantity.raw(), position.no_quantity.raw()));
        if (matched <= zero) {
            continue;
        }
        const Decimal pnl = matched - position.acquisition_cost;
        position.state = PositionState::merged;
        repository_.update_position(position);
        repository_.record_pnl(position.id + ":merge", day, pnl, now_ms);
        repository_.record_event("paper_merge_settled", {
            {"position_id", position.id},
            {"quantity", matched.str()},
            {"merge_value", matched.str()},
            {"realized_pnl", pnl.str()},
        });
        const Snapshot after = repository_.load();
        const Decimal day_pnl = after.realized_pnl.contains(day)
            ? after.realized_pnl.at(day)
            : zero;
        if (day_pnl <= Decimal::from_raw(-config_.max_daily_loss.raw())) {
            repository_.latch_kill("daily_loss", day, now_ms);
            return;
        }
    }
}

Decimal PaperEngine::exposure(const Snapshot& snapshot) const {
    Decimal total;
    for (const auto& position : snapshot.positions) {
        if (position.state == PositionState::paired ||
            position.state == PositionState::stranded) {
            total = total + position.acquisition_cost;
        }
    }
    return total;
}

void PaperEngine::refresh_health(std::int64_t now_ms) {
    const Snapshot snapshot = repository_.load();
    const std::string day = utc_day(now_ms);
    health_.exposure = exposure(snapshot);
    health_.realized_pnl =
        snapshot.realized_pnl.contains(day) ? snapshot.realized_pnl.at(day) : zero;
    health_.unrealized_pnl = zero;
    for (const auto& position : snapshot.positions) {
        if (position.state == PositionState::paired) {
            const Decimal matched = Decimal::from_raw(
                std::min(position.yes_quantity.raw(), position.no_quantity.raw()));
            health_.unrealized_pnl =
                health_.unrealized_pnl + matched - position.acquisition_cost;
        } else if (position.state == PositionState::stranded) {
            health_.unrealized_pnl =
                health_.unrealized_pnl - position.acquisition_cost;
        }
    }
    health_.kill = snapshot.kill;
    health_.reconciliation_ok =
        snapshot.last_reconciliation_epoch_ms > 0 &&
        snapshot.pending_opportunities.empty();
    health_.updated_epoch_ms = now_ms;
}

Health PaperEngine::health() const {
    return health_;
}

std::string PaperEngine::utc_day(std::int64_t epoch_ms_value) const {
    const std::time_t value = static_cast<std::time_t>(epoch_ms_value / 1'000);
    std::tm utc{};
#ifdef _WIN32
    if (gmtime_s(&utc, &value) != 0) {
        throw PaperError("failed to derive UTC trading day");
    }
#else
    if (gmtime_r(&value, &utc) == nullptr) {
        throw PaperError("failed to derive UTC trading day");
    }
#endif
    std::ostringstream output;
    output << std::put_time(&utc, "%Y-%m-%d");
    return output.str();
}

Json health_json(const Health& health) {
    return {
        {"mode", health.mode},
        {"scanning", health.scanning},
        {"public_data_fresh", health.data_fresh},
        {"reconciliation_ok", health.reconciliation_ok},
        {"simulated_exposure", health.exposure.str()},
        {"daily_realized_pnl", health.realized_pnl.str()},
        {"unrealized_pnl", health.unrealized_pnl.str()},
        {"kill_switch", {
            {"active", health.kill.active},
            {"reason", health.kill.reason},
            {"trading_day", health.kill.trading_day},
            {"latched_epoch_ms", health.kill.latched_epoch_ms},
        }},
        {"last_error", health.last_error},
        {"updated_epoch_ms", health.updated_epoch_ms},
    };
}

std::int64_t epoch_ms(TimePoint point) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        point.time_since_epoch()).count();
}

std::string position_state_name(PositionState state) {
    switch (state) {
    case PositionState::paired:
        return "paired";
    case PositionState::stranded:
        return "stranded";
    case PositionState::recovered:
        return "recovered";
    case PositionState::merged:
        return "merged";
    }
    throw PaperError("unknown position state");
}

PositionState parse_position_state(std::string_view state) {
    if (state == "paired") {
        return PositionState::paired;
    }
    if (state == "stranded") {
        return PositionState::stranded;
    }
    if (state == "recovered") {
        return PositionState::recovered;
    }
    if (state == "merged") {
        return PositionState::merged;
    }
    throw PaperError("invalid position state");
}

}  // namespace polymarket::paper
