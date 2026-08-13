#include "godbrain/polygon_pipeline.hpp"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <limits>
#include <set>
#include <sstream>
#include <tuple>

namespace godbrain::polygon::pipeline {
namespace {

constexpr std::string_view selector = "d06ca61f";
constexpr std::size_t encoded_call_bytes = 164U;

bool is_lower_hex(std::string_view value) {
    return !value.empty() &&
        std::all_of(value.begin(), value.end(), [](const unsigned char character) {
            return (character >= static_cast<unsigned char>('0') &&
                    character <= static_cast<unsigned char>('9')) ||
                (character >= static_cast<unsigned char>('a') &&
                 character <= static_cast<unsigned char>('f'));
        });
}

void require_exact_keys(const Json& value, const std::set<std::string>& keys) {
    if (!value.is_object() || value.size() != keys.size()) {
        throw PipelineError("JSON object has missing or unknown fields");
    }
    for (const auto& [key, unused] : value.items()) {
        (void)unused;
        if (!keys.contains(key)) {
            throw PipelineError("JSON object has an unknown field: " + key);
        }
    }
}

std::uint64_t require_uint64(const Json& value, std::string_view field) {
    if (!value.is_number_integer()) {
        throw PipelineError(std::string(field) + " must be an integer");
    }
    if (value.is_number_unsigned()) {
        return value.get<std::uint64_t>();
    }
    const auto number = value.get<std::int64_t>();
    if (number < 0) {
        throw PipelineError(std::string(field) + " must not be negative");
    }
    return static_cast<std::uint64_t>(number);
}

std::string require_string(
    const Json& value, std::string_view field, std::size_t maximum = 128U) {
    if (!value.is_string()) {
        throw PipelineError(std::string(field) + " must be a string");
    }
    const std::string result = value.get<std::string>();
    if (result.empty() || result.size() > maximum ||
        !std::all_of(result.begin(), result.end(), [](const unsigned char character) {
            return character >= 0x20U && character <= 0x7eU;
        })) {
        throw PipelineError(std::string(field) + " is invalid");
    }
    return result;
}

std::string require_address(const Json& value, std::string_view field) {
    const std::string address = require_string(value, field, 42U);
    if (address.size() != 42U || !address.starts_with("0x") ||
        !is_lower_hex(std::string_view(address).substr(2U))) {
        throw PipelineError(
            std::string(field) + " must be a canonical lowercase address");
    }
    return address;
}

std::string require_hash(const Json& value, std::string_view field) {
    const std::string hash = require_string(value, field, 66U);
    if (hash.size() != 66U || !hash.starts_with("0x") ||
        !is_lower_hex(std::string_view(hash).substr(2U))) {
        throw PipelineError(std::string(field) + " must be a lowercase hash");
    }
    return hash;
}

std::string require_digest(const Json& value, std::string_view field) {
    const std::string digest = require_string(value, field, 64U);
    if (digest.size() != 64U || !is_lower_hex(digest)) {
        throw PipelineError(
            std::string(field) + " must be a lowercase SHA-256 digest");
    }
    return digest;
}

std::string require_https(const Json& value) {
    const std::string url = require_string(value, "source.url", 2'048U);
    if (!url.starts_with("https://") ||
        url.find_first_of(" @#?\\") != std::string::npos) {
        throw PipelineError("source.url must be an immutable explicit HTTPS URL");
    }
    return url;
}

std::uint64_t parse_quantity_text(std::string_view value, std::string_view field) {
    if (value.size() < 3U || !value.starts_with("0x") ||
        !is_lower_hex(value.substr(2U)) ||
        (value.size() > 3U && value[2] == '0')) {
        throw PipelineError(std::string(field) + " is not a canonical hex quantity");
    }
    std::uint64_t result = 0;
    const auto parsed = std::from_chars(
        value.data() + 2, value.data() + value.size(), result, 16);
    if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) {
        throw PipelineError(std::string(field) + " is out of range");
    }
    return result;
}

std::uint64_t parse_quantity_json(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw PipelineError(std::string(field) + " must be a string");
    }
    return parse_quantity_text(value.get_ref<const std::string&>(), field);
}

std::string uint256_word(std::uint64_t value) {
    std::ostringstream output;
    output << std::hex << std::setfill('0') << std::setw(64) << value;
    return output.str();
}

std::string address_word(std::string_view value) {
    (void)require_address(Json(value), "ABI address");
    return std::string(24U, '0') + std::string(value.substr(2U));
}

std::uint64_t word_uint64(std::string_view word, std::string_view field) {
    if (word.size() != 64U || !is_lower_hex(word) ||
        !std::all_of(word.begin(), word.begin() + 48, [](const char character) {
            return character == '0';
        })) {
        throw PipelineError(std::string(field) + " is not a bounded uint256");
    }
    std::uint64_t result = 0;
    const auto tail = word.substr(48U);
    const auto parsed =
        std::from_chars(tail.data(), tail.data() + tail.size(), result, 16);
    if (parsed.ec != std::errc{} || parsed.ptr != tail.data() + tail.size()) {
        throw PipelineError(std::string(field) + " is out of range");
    }
    return result;
}

bool empty_code(std::string_view code) {
    if (code == "0x") {
        return true;
    }
    const auto body = code.substr(2U);
    return std::all_of(body.begin(), body.end(), [](char value) {
        return value == '0';
    });
}

void validate_code(std::string_view code) {
    if (!code.starts_with("0x") || code.size() < 4U ||
        ((code.size() - 2U) % 2U) != 0U || !is_lower_hex(code.substr(2U)) ||
        empty_code(code)) {
        throw PipelineError("venue has empty or malformed bytecode at pinned block");
    }
}

Json quote_binding(
    const PipelineConfig& config,
    const searcher::Route& route,
    const searcher::BlockContext& block,
    std::uint64_t amount,
    std::string_view calldata,
    std::string_view response,
    std::int64_t observed_epoch_ms) {
    return {
        {"schema_version", 1},
        {"chain_id", config.chain_id},
        {"block_number", block.number},
        {"block_hash", block.hash},
        {"router", route.venue_id},
        {"path", Json::array({route.token_in, route.token_out})},
        {"amount_in", std::to_string(amount)},
        {"calldata", calldata},
        {"response", response},
        {"evidence_revision", config.evidence_revision},
        {"observed_epoch_ms", observed_epoch_ms},
    };
}

searcher::Route to_route(const RouteConfig& route) {
    return {
        .id = route.id,
        .venue_id = route.venue,
        .token_in = route.token_in,
        .token_out = route.token_out,
    };
}

std::int64_t clock_epoch_ms(const observer::Clock& clock) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               clock.now().time_since_epoch())
        .count();
}

std::uint64_t multiply_checked(
    std::uint64_t left, std::uint64_t right, std::string_view field) {
    if (left != 0U && right > std::numeric_limits<std::uint64_t>::max() / left) {
        throw PipelineError(std::string(field) + " overflows uint64");
    }
    return left * right;
}

Json parse_replay_block(const Json& value) {
    require_exact_keys(
        value, {"hash", "number", "observed_epoch_ms", "parent_hash"});
    return {
        {"number", require_uint64(value.at("number"), "replay block.number")},
        {"hash", require_hash(value.at("hash"), "replay block.hash")},
        {"parent_hash",
         require_hash(value.at("parent_hash"), "replay block.parent_hash")},
        {"observed_epoch_ms",
         require_uint64(
             value.at("observed_epoch_ms"), "replay block.observed_epoch_ms")},
    };
}

}  // namespace

PipelineConfig PipelineConfig::from_json(const Json& value) {
    require_exact_keys(
        value,
        {"chain_id",
         "confirmation_depth",
         "cycles",
         "evidence_revision",
         "gas_conversion",
         "gas_units_ceiling",
         "maximum_block_age_seconds",
         "maximum_calldata_bytes",
         "maximum_future_seconds",
         "maximum_quote_amount",
         "routes",
         "schema_version",
         "source",
         "tokens",
         "venues"});

    PipelineConfig config;
    const auto schema_version =
        require_uint64(value.at("schema_version"), "schema_version");
    config.chain_id = require_uint64(value.at("chain_id"), "chain_id");
    if (schema_version != 1U || config.chain_id != 137U) {
        throw PipelineError("only pipeline schema 1 for chain 137 is supported");
    }
    config.schema_version = 1U;
    config.evidence_revision =
        require_digest(value.at("evidence_revision"), "evidence_revision");
    require_exact_keys(value.at("source"), {"sha256", "url"});
    config.source = {
        .url = require_https(value.at("source").at("url")),
        .sha256 =
            require_digest(value.at("source").at("sha256"), "source.sha256"),
    };
    config.confirmation_depth =
        require_uint64(value.at("confirmation_depth"), "confirmation_depth");
    config.maximum_block_age_seconds = require_uint64(
        value.at("maximum_block_age_seconds"), "maximum_block_age_seconds");
    config.maximum_future_seconds =
        require_uint64(value.at("maximum_future_seconds"), "maximum_future_seconds");
    config.maximum_quote_amount =
        require_uint64(value.at("maximum_quote_amount"), "maximum_quote_amount");
    config.maximum_calldata_bytes = static_cast<std::size_t>(
        require_uint64(value.at("maximum_calldata_bytes"), "maximum_calldata_bytes"));
    config.gas_units_ceiling =
        require_uint64(value.at("gas_units_ceiling"), "gas_units_ceiling");
    if (config.confirmation_depth == 0U || config.maximum_block_age_seconds == 0U ||
        config.confirmation_depth > 100'000U ||
        config.maximum_block_age_seconds > 86'400U ||
        config.maximum_future_seconds > 30U ||
        config.maximum_quote_amount == 0U ||
        config.maximum_calldata_bytes < encoded_call_bytes ||
        config.maximum_calldata_bytes > 4'096U ||
        config.gas_units_ceiling == 0U ||
        config.gas_units_ceiling > searcher::SearchConfig::hard_max_gas_units) {
        throw PipelineError("pipeline numeric safety limits are invalid");
    }

    if (!value.at("tokens").is_array() || value.at("tokens").empty() ||
        value.at("tokens").size() > searcher::SearchConfig::hard_max_routes) {
        throw PipelineError("tokens must be a non-empty array");
    }
    std::set<std::string> addresses;
    for (const auto& entry : value.at("tokens")) {
        require_exact_keys(entry, {"address", "decimals", "symbol"});
        const auto decimals = require_uint64(entry.at("decimals"), "token.decimals");
        if (decimals > 18U) {
            throw PipelineError("token decimals exceed 18");
        }
        TokenConfig token{
            .address = require_address(entry.at("address"), "token.address"),
            .symbol = require_string(entry.at("symbol"), "token.symbol", 24U),
            .decimals = static_cast<std::uint8_t>(decimals),
        };
        if (!addresses.insert(token.address).second) {
            throw PipelineError("duplicate configured address");
        }
        config.tokens.push_back(std::move(token));
    }

    if (!value.at("venues").is_array() || value.at("venues").empty() ||
        value.at("venues").size() > searcher::SearchConfig::hard_max_routes) {
        throw PipelineError("venues must be a non-empty array");
    }
    for (const auto& entry : value.at("venues")) {
        require_exact_keys(entry, {"address", "kind"});
        VenueConfig venue{
            .address = require_address(entry.at("address"), "venue.address"),
            .kind = require_string(entry.at("kind"), "venue.kind"),
        };
        if (venue.kind != "uniswap_v2_get_amounts_out") {
            throw PipelineError("venue adapter kind is not reviewed");
        }
        if (!addresses.insert(venue.address).second) {
            throw PipelineError("duplicate configured address");
        }
        config.venues.push_back(std::move(venue));
    }

    if (!value.at("routes").is_array() || value.at("routes").empty() ||
        value.at("routes").size() > searcher::SearchConfig::hard_max_routes) {
        throw PipelineError("routes must be a non-empty array");
    }
    std::set<std::string> route_ids;
    std::set<std::tuple<std::string, std::string, std::string>> route_keys;
    for (const auto& entry : value.at("routes")) {
        require_exact_keys(entry, {"id", "token_in", "token_out", "venue"});
        RouteConfig route{
            .id = require_string(entry.at("id"), "route.id", 80U),
            .venue = require_address(entry.at("venue"), "route.venue"),
            .token_in = require_address(entry.at("token_in"), "route.token_in"),
            .token_out = require_address(entry.at("token_out"), "route.token_out"),
        };
        if (route.token_in == route.token_out || !route_ids.insert(route.id).second ||
            !route_keys
                 .emplace(route.venue, route.token_in, route.token_out)
                 .second) {
            throw PipelineError("duplicate or self-referential route");
        }
        (void)config.venue(route.venue);
        (void)config.token(route.token_in);
        (void)config.token(route.token_out);
        config.routes.push_back(std::move(route));
    }

    if (!value.at("cycles").is_array() || value.at("cycles").empty() ||
        value.at("cycles").size() >
            searcher::SearchConfig::hard_max_candidates_per_block) {
        throw PipelineError("cycles must be a non-empty array");
    }
    std::set<std::string> cycle_ids;
    std::set<std::pair<std::string, std::string>> cycle_pairs;
    for (const auto& entry : value.at("cycles")) {
        require_exact_keys(entry, {"first_route", "id", "second_route"});
        CycleConfig cycle{
            .id = require_string(entry.at("id"), "cycle.id", 80U),
            .first_route =
                require_string(entry.at("first_route"), "cycle.first_route", 80U),
            .second_route =
                require_string(entry.at("second_route"), "cycle.second_route", 80U),
        };
        if (cycle.first_route == cycle.second_route ||
            !cycle_ids.insert(cycle.id).second ||
            !cycle_pairs.emplace(cycle.first_route, cycle.second_route).second) {
            throw PipelineError("duplicate or malformed cycle");
        }
        const auto& first = config.route(cycle.first_route);
        const auto& second = config.route(cycle.second_route);
        if (first.token_out != second.token_in ||
            second.token_out != first.token_in ||
            first.venue == second.venue) {
            throw PipelineError("cycle routes do not form a closed two-leg cycle");
        }
        config.cycles.push_back(std::move(cycle));
    }

    const auto& conversion = value.at("gas_conversion");
    require_exact_keys(
        conversion,
        {"input_token", "route_id", "wrapped_native"});
    config.gas_conversion = {
        .wrapped_native =
            require_address(conversion.at("wrapped_native"), "gas wrapped_native"),
        .input_token =
            require_address(conversion.at("input_token"), "gas input_token"),
        .route_id =
            require_string(conversion.at("route_id"), "gas route_id", 80U),
    };
    (void)config.token(config.gas_conversion.wrapped_native);
    (void)config.token(config.gas_conversion.input_token);
    const auto& conversion_route = config.route(config.gas_conversion.route_id);
    if (config.gas_conversion.wrapped_native ==
            config.gas_conversion.input_token ||
        conversion_route.token_in != config.gas_conversion.wrapped_native ||
        conversion_route.token_out != config.gas_conversion.input_token) {
        throw PipelineError("gas conversion quote is invalid");
    }
    for (const auto& cycle : config.cycles) {
        if (config.route(cycle.first_route).token_in !=
            config.gas_conversion.input_token) {
            throw PipelineError(
                "cycle input token does not match gas conversion input token");
        }
    }
    return config;
}

Json PipelineConfig::to_json() const {
    Json token_values = Json::array();
    for (const auto& value : tokens) {
        token_values.push_back(
            {{"address", value.address},
             {"decimals", value.decimals},
             {"symbol", value.symbol}});
    }
    Json venue_values = Json::array();
    for (const auto& value : venues) {
        venue_values.push_back(
            {{"address", value.address}, {"kind", value.kind}});
    }
    Json route_values = Json::array();
    for (const auto& value : routes) {
        route_values.push_back(
            {{"id", value.id},
             {"venue", value.venue},
             {"token_in", value.token_in},
             {"token_out", value.token_out}});
    }
    Json cycle_values = Json::array();
    for (const auto& value : cycles) {
        cycle_values.push_back(
            {{"id", value.id},
             {"first_route", value.first_route},
             {"second_route", value.second_route}});
    }
    return {
        {"schema_version", schema_version},
        {"chain_id", chain_id},
        {"evidence_revision", evidence_revision},
        {"source", {{"url", source.url}, {"sha256", source.sha256}}},
        {"confirmation_depth", confirmation_depth},
        {"maximum_block_age_seconds", maximum_block_age_seconds},
        {"maximum_future_seconds", maximum_future_seconds},
        {"maximum_quote_amount", maximum_quote_amount},
        {"maximum_calldata_bytes", maximum_calldata_bytes},
        {"gas_units_ceiling", gas_units_ceiling},
        {"tokens", std::move(token_values)},
        {"venues", std::move(venue_values)},
        {"routes", std::move(route_values)},
        {"cycles", std::move(cycle_values)},
        {"gas_conversion",
         {{"wrapped_native", gas_conversion.wrapped_native},
          {"input_token", gas_conversion.input_token},
          {"route_id", gas_conversion.route_id}}},
    };
}

const TokenConfig& PipelineConfig::token(std::string_view address) const {
    const auto found = std::find_if(tokens.begin(), tokens.end(), [&](const auto& item) {
        return item.address == address;
    });
    if (found == tokens.end()) {
        throw PipelineError("unknown token address");
    }
    return *found;
}

const VenueConfig& PipelineConfig::venue(std::string_view address) const {
    const auto found =
        std::find_if(venues.begin(), venues.end(), [&](const auto& item) {
            return item.address == address;
        });
    if (found == venues.end()) {
        throw PipelineError("unknown venue address");
    }
    return *found;
}

const RouteConfig& PipelineConfig::route(std::string_view id) const {
    const auto found = std::find_if(routes.begin(), routes.end(), [&](const auto& item) {
        return item.id == id;
    });
    if (found == routes.end()) {
        throw PipelineError("unknown route id");
    }
    return *found;
}

std::string canonical_block_number_tag(std::uint64_t number) {
    return observer::canonical_block_number_tag(number);
}

Json build_get_block_params(std::uint64_t number) {
    return observer::build_get_block_params(number);
}

Json build_get_code_params(std::string_view address, std::string_view block_tag) {
    return observer::build_get_code_params(address, block_tag);
}

Json build_eth_call_params(
    std::string_view to, std::string_view data, std::string_view block_tag) {
    return observer::build_eth_call_params(to, data, block_tag);
}

std::string encode_get_amounts_out(
    std::uint64_t amount_in,
    std::string_view token_in,
    std::string_view token_out,
    std::size_t maximum_calldata_bytes) {
    if (amount_in == 0U || token_in == token_out ||
        maximum_calldata_bytes < encoded_call_bytes) {
        throw PipelineError("getAmountsOut request violates bounds");
    }
    const std::string result =
        "0x" + std::string(selector) + uint256_word(amount_in) + uint256_word(64U) +
        uint256_word(2U) + address_word(token_in) + address_word(token_out);
    if ((result.size() - 2U) / 2U > maximum_calldata_bytes) {
        throw PipelineError("getAmountsOut calldata exceeds configured bound");
    }
    return result;
}

std::uint64_t decode_get_amounts_out(
    std::string_view result, std::uint64_t expected_amount_in) {
    if (!result.starts_with("0x") || result.size() != 258U ||
        !is_lower_hex(result.substr(2U))) {
        throw PipelineError("getAmountsOut response has an invalid ABI size");
    }
    const auto bytes = result.substr(2U);
    if (word_uint64(bytes.substr(0U, 64U), "ABI offset") != 32U ||
        word_uint64(bytes.substr(64U, 64U), "ABI array length") != 2U ||
        word_uint64(bytes.substr(128U, 64U), "ABI input amount") !=
            expected_amount_in) {
        throw PipelineError("getAmountsOut response has an invalid dynamic array");
    }
    return word_uint64(bytes.substr(192U, 64U), "ABI output amount");
}

ObserverReadOnlyRpc::ObserverReadOnlyRpc(
    observer::RpcTransport& transport,
    observer::Endpoint endpoint,
    observer::TransportLimits limits)
    : client_(transport, std::move(endpoint), limits) {}

Json ObserverReadOnlyRpc::get_block(std::uint64_t number) {
    return client_.call(
        observer::RpcMethod::eth_get_block_by_number,
        observer::build_get_block_params(number));
}

std::string ObserverReadOnlyRpc::get_code(
    std::string_view address, std::uint64_t number) {
    const Json result = client_.call(
        observer::RpcMethod::eth_get_code,
        observer::build_get_code_params(
            address, observer::canonical_block_number_tag(number)));
    if (!result.is_string()) {
        throw PipelineError("eth_getCode result is not a string");
    }
    return result.get<std::string>();
}

std::string ObserverReadOnlyRpc::eth_call(
    std::string_view to, std::string_view data, std::uint64_t number) {
    const Json result = client_.call(
        observer::RpcMethod::eth_call,
        observer::build_eth_call_params(
            to, data, observer::canonical_block_number_tag(number)));
    if (!result.is_string()) {
        throw PipelineError("eth_call result is not a string");
    }
    return result.get<std::string>();
}

ObserverHealthGate::ObserverHealthGate(observer::HealthObserver& health)
    : health_(health) {}

observer::HealthSnapshot ObserverHealthGate::inspect() {
    return health_.inspect();
}

ConfirmedBlockProvider::ConfirmedBlockProvider(
    HealthGate& health,
    ReadOnlyRpc& rpc,
    const observer::Clock& clock,
    const PipelineConfig& config)
    : health_(health), rpc_(rpc), clock_(clock), config_(config) {}

searcher::BlockContext ConfirmedBlockProvider::current() {
    const auto health = health_.inspect();
    if (!health.ready || health.chain_id.value_or(0U) != config_.chain_id ||
        !health.latest_block_number.has_value()) {
        throw PipelineError("observer health gate is not ready for chain 137");
    }
    const std::uint64_t head = *health.latest_block_number;
    if (head < config_.confirmation_depth) {
        throw PipelineError("head is below configured confirmation depth");
    }
    const std::uint64_t number = head - config_.confirmation_depth;
    const Json header = rpc_.get_block(number);
    if (!header.is_object() || !header.contains("number") ||
        !header.contains("hash") || !header.contains("parentHash") ||
        !header.contains("timestamp") || !header.contains("baseFeePerGas")) {
        throw PipelineError("confirmed block header is missing required fields");
    }
    if (parse_quantity_json(header.at("number"), "header.number") != number) {
        throw PipelineError("confirmed block header number mismatch");
    }
    const std::string hash = require_hash(header.at("hash"), "header.hash");
    const std::string parent =
        require_hash(header.at("parentHash"), "header.parentHash");
    const std::uint64_t timestamp =
        parse_quantity_json(header.at("timestamp"), "header.timestamp");
    const std::uint64_t base_fee =
        parse_quantity_json(header.at("baseFeePerGas"), "header.baseFeePerGas");
    if (base_fee == 0U ||
        timestamp > static_cast<std::uint64_t>(
                        std::numeric_limits<std::int64_t>::max())) {
        throw PipelineError("confirmed block header values are invalid");
    }
    const std::int64_t now_ms = clock_epoch_ms(clock_);
    if (now_ms < 0) {
        throw PipelineError("clock is before Unix epoch");
    }
    const std::uint64_t now_seconds = static_cast<std::uint64_t>(now_ms / 1'000);
    if ((timestamp > now_seconds &&
         timestamp - now_seconds > config_.maximum_future_seconds) ||
        (now_seconds > timestamp &&
         now_seconds - timestamp > config_.maximum_block_age_seconds)) {
        throw PipelineError("confirmed block timestamp is stale or future-dated");
    }
    {
        std::lock_guard lock(mutex_);
        base_fees_[hash] = base_fee;
    }
    return {
        .number = number,
        .hash = hash,
        .parent_hash = parent,
        .status = searcher::BlockStatus::confirmed,
        .observed_epoch_ms = now_ms,
    };
}

bool ConfirmedBlockProvider::is_canonical(const searcher::BlockContext& block) {
    if (block.status != searcher::BlockStatus::confirmed) {
        return false;
    }
    try {
        const Json header = rpc_.get_block(block.number);
        return header.is_object() && header.contains("number") &&
            header.contains("hash") &&
            parse_quantity_json(header.at("number"), "canonical.number") ==
            block.number &&
            require_hash(header.at("hash"), "canonical.hash") == block.hash;
    } catch (const std::exception&) {
        return false;
    }
}

std::uint64_t ConfirmedBlockProvider::base_fee_per_gas(
    const searcher::BlockContext& block) const {
    std::lock_guard lock(mutex_);
    const auto found = base_fees_.find(block.hash);
    if (found == base_fees_.end()) {
        throw PipelineError("base fee is unavailable for the exact block");
    }
    return found->second;
}

ConfigTokenMetadataProvider::ConfigTokenMetadataProvider(
    const PipelineConfig& config)
    : config_(config) {}

searcher::Token ConfigTokenMetadataProvider::get(std::string_view token_id) {
    const auto& token = config_.token(token_id);
    return {
        .id = token.address,
        .symbol = token.symbol,
        .decimals = token.decimals,
    };
}

ObserverClockAdapter::ObserverClockAdapter(const observer::Clock& clock)
    : clock_(clock) {}

std::int64_t ObserverClockAdapter::now_epoch_ms() const {
    return clock_epoch_ms(clock_);
}

UniswapV2QuoteProvider::UniswapV2QuoteProvider(
    ReadOnlyRpc& rpc,
    searcher::BlockProvider& blocks,
    searcher::Clock& clock,
    const PipelineConfig& config)
    : rpc_(rpc), blocks_(blocks), clock_(clock), config_(config) {}

searcher::ExactInputQuote UniswapV2QuoteProvider::quote(
    const searcher::QuoteRequest& request) {
    if (request.amount_in == 0U ||
        request.amount_in > config_.maximum_quote_amount ||
        request.block.status != searcher::BlockStatus::confirmed) {
        throw PipelineError("quote request violates configured bounds");
    }
    const auto& configured = config_.route(request.route.id);
    if (request.route != to_route(configured)) {
        throw PipelineError("quote route does not exactly match reviewed config");
    }
    if (!blocks_.is_canonical(request.block)) {
        throw PipelineError("block is not canonical before quote");
    }
    validate_code(rpc_.get_code(request.route.venue_id, request.block.number));
    const std::string calldata = encode_get_amounts_out(
        request.amount_in,
        request.route.token_in,
        request.route.token_out,
        config_.maximum_calldata_bytes);
    const std::string response = rpc_.eth_call(
        request.route.venue_id, calldata, request.block.number);
    const auto amount_out = decode_get_amounts_out(response, request.amount_in);
    const std::int64_t observed = clock_.now_epoch_ms();
    const Json binding = quote_binding(
        config_,
        request.route,
        request.block,
        request.amount_in,
        calldata,
        response,
        observed);
    const std::string provenance = binding.dump();
    const std::string hash = sha256_hex(provenance);
    if (!blocks_.is_canonical(request.block)) {
        throw PipelineError("block is not canonical after quote");
    }
    return {
        .route = request.route,
        .amount_in = request.amount_in,
        .amount_out = amount_out,
        .max_supported_input = config_.maximum_quote_amount,
        .confidence_bps = 10'000U,
        .block = request.block,
        .observed_epoch_ms = observed,
        .provider = "polygon-pipeline-uniswap-v2",
        .provenance = "sha256:" + hash,
        .quote_hash = hash,
    };
}

std::uint64_t checked_base_fee_cost(
    std::uint64_t gas_units, std::uint64_t base_fee_per_gas) {
    if (gas_units == 0U || base_fee_per_gas == 0U) {
        throw PipelineError("gas units and base fee must be positive");
    }
    return multiply_checked(gas_units, base_fee_per_gas, "base-fee gas cost");
}

ConservativeGasCostProvider::ConservativeGasCostProvider(
    ConfirmedBlockProvider& blocks,
    searcher::ExactInputQuoteProvider& quotes,
    searcher::Clock& clock,
    const PipelineConfig& config)
    : blocks_(blocks), quotes_(quotes), clock_(clock), config_(config) {}

searcher::GasCostQuote ConservativeGasCostProvider::estimate(
    const searcher::CostRequest& request) {
    if (request.block.status != searcher::BlockStatus::confirmed ||
        request.input_token.id != config_.gas_conversion.input_token) {
        throw PipelineError("gas request is outside verified conversion config");
    }
    const auto base_fee = blocks_.base_fee_per_gas(request.block);
    const auto native_cost =
        checked_base_fee_cost(config_.gas_units_ceiling, base_fee);
    if (native_cost > config_.maximum_quote_amount) {
        throw PipelineError("native gas cost exceeds conversion quote bound");
    }
    const auto& configured_route =
        config_.route(config_.gas_conversion.route_id);
    const auto conversion = quotes_.quote({
        .route = to_route(configured_route),
        .amount_in = native_cost,
        .block = request.block,
    });
    const std::int64_t observed = clock_.now_epoch_ms();
    if (conversion.route != to_route(configured_route) ||
        conversion.amount_in != native_cost || conversion.amount_out == 0U ||
        conversion.max_supported_input < native_cost ||
        conversion.confidence_bps != 10'000U ||
        conversion.block != request.block ||
        conversion.observed_epoch_ms < 0 ||
        conversion.observed_epoch_ms > observed ||
        conversion.provider != "polygon-pipeline-uniswap-v2" ||
        conversion.provenance != "sha256:" + conversion.quote_hash ||
        conversion.quote_hash.size() != 64U ||
        !is_lower_hex(conversion.quote_hash)) {
        throw PipelineError("block-pinned gas conversion quote is malformed");
    }
    const auto input_cost = conversion.amount_out;
    const Json binding{
        {"schema_version", 1},
        {"model", "base_fee_ceiling_verified_conversion"},
        {"chain_id", config_.chain_id},
        {"block_number", request.block.number},
        {"block_hash", request.block.hash},
        {"base_fee_per_gas", std::to_string(base_fee)},
        {"gas_units_ceiling", config_.gas_units_ceiling},
        {"native_cost", std::to_string(native_cost)},
        {"input_token", request.input_token.id},
        {"input_token_cost", std::to_string(input_cost)},
        {"conversion_route_id", configured_route.id},
        {"conversion_quote_sha256", conversion.quote_hash},
        {"evidence_revision", config_.evidence_revision},
        {"observed_epoch_ms", observed},
    };
    const std::string hash = sha256_hex(binding.dump());
    return {
        .block = request.block,
        .gas_units = config_.gas_units_ceiling,
        .native_wei = native_cost,
        .input_token_cost = input_cost,
        .observed_epoch_ms = observed,
        .conversion_provenance = "sha256:" + conversion.quote_hash,
        .quote_hash = hash,
    };
}

DeterministicPaperExecutor::DeterministicPaperExecutor(searcher::Clock& clock)
    : clock_(clock) {}

searcher::PaperResult DeterministicPaperExecutor::execute(
    const searcher::ArbitragePlan& plan) {
    if (plan.expected_net < 0 ||
        static_cast<std::uint64_t>(plan.expected_net) >
            std::numeric_limits<std::uint64_t>::max() - plan.amount_in) {
        throw PipelineError("paper plan result is out of range");
    }
    const auto final_amount =
        plan.amount_in + static_cast<std::uint64_t>(plan.expected_net);
    return {
        .plan_id = plan.id,
        .first_leg_filled = true,
        .second_leg_filled = true,
        .atomic = true,
        .final_amount = final_amount,
        .realized_pnl = plan.expected_net,
        .settled_epoch_ms = clock_.now_epoch_ms(),
        .incident = "",
    };
}

Json atlas_simulation_plan(
    const searcher::ArbitragePlan& plan, std::string_view evidence_revision) {
    (void)require_digest(Json(evidence_revision), "Atlas evidence revision");
    if (plan.schema_version != 1U ||
        plan.block.status != searcher::BlockStatus::confirmed ||
        plan.id.empty() || plan.amount_in == 0U || plan.deadline_epoch_ms <= 0 ||
        plan.deadline_epoch_ms < plan.created_epoch_ms ||
        plan.first.token_in != plan.input_token.id ||
        plan.first.token_out != plan.intermediate_token.id ||
        plan.second.token_in != plan.intermediate_token.id ||
        plan.second.token_out != plan.input_token.id ||
        plan.first_quote_hash.size() != 64U ||
        !is_lower_hex(plan.first_quote_hash) ||
        plan.second_quote_hash.size() != 64U ||
        !is_lower_hex(plan.second_quote_hash) ||
        plan.gas_quote_hash.size() != 64U ||
        !is_lower_hex(plan.gas_quote_hash) ||
        plan.first_quote_provenance != "sha256:" + plan.first_quote_hash ||
        plan.second_quote_provenance != "sha256:" + plan.second_quote_hash ||
        plan.gas_conversion_provenance.size() != 71U ||
        !plan.gas_conversion_provenance.starts_with("sha256:") ||
        !is_lower_hex(
            std::string_view(plan.gas_conversion_provenance).substr(7U))) {
        throw PipelineError("arbitrage plan is not accepted or internally coherent");
    }
    Json envelope{
        {"schema_version", 1},
        {"kind", "atlas_simulation_plan"},
        {"chain_id", 137},
        {"source_plan_id", plan.id},
        {"block",
         {{"number", plan.block.number},
          {"hash", plan.block.hash},
          {"parent_hash", plan.block.parent_hash}}},
        {"cycle",
         {{"first_route", plan.first.id},
          {"second_route", plan.second.id},
          {"first_venue", plan.first.venue_id},
          {"second_venue", plan.second.venue_id},
          {"input_token", plan.input_token.id},
          {"intermediate_token", plan.intermediate_token.id}}},
        {"amount_constraints",
         {{"amount_in", std::to_string(plan.amount_in)},
          {"first_quote_out", std::to_string(plan.first_quote_out)},
          {"gross_amount_out", std::to_string(plan.gross_amount_out)},
          {"gross_profit", std::to_string(plan.gross_profit)},
          {"minimum_net", std::to_string(plan.expected_net)}}},
        {"quote_provenance",
         Json::array(
             {{{"route", plan.first.id},
               {"provider", plan.first_quote_provider},
               {"provenance", {{"sha256", plan.first_quote_hash}}},
               {"sha256", plan.first_quote_hash},
               {"observed_epoch_ms", plan.first_quote_observed_epoch_ms}},
              {{"route", plan.second.id},
               {"provider", plan.second_quote_provider},
               {"provenance", {{"sha256", plan.second_quote_hash}}},
               {"sha256", plan.second_quote_hash},
               {"observed_epoch_ms", plan.second_quote_observed_epoch_ms}}})},
        {"modeled_limits",
         {{"model", "base_fee_ceiling_verified_conversion"},
          {"gas_units_ceiling", plan.max_gas_units},
          {"gas_cost_limit", std::to_string(plan.costs.gas)},
          {"atlas_bid_reserve_limit",
           std::to_string(plan.costs.atlas_bid_reserve)},
          {"total_cost_limit", std::to_string(plan.costs.total())},
          {"conversion_provenance",
           {{"sha256", plan.gas_conversion_provenance.substr(7U)}}},
          {"gas_quote_sha256", plan.gas_quote_hash}}},
        {"deadline_epoch_ms", plan.deadline_epoch_ms},
        {"evidence_revision", evidence_revision},
    };
    envelope["id"] = sha256_hex(envelope.dump());
    return envelope;
}

ReplayOutput replay_offline(
    const PipelineConfig& config, const Json& sanitized_fixture) {
    require_exact_keys(
        sanitized_fixture, {"evidence_class", "records", "schema_version"});
    if (require_uint64(
            sanitized_fixture.at("schema_version"), "replay schema_version") != 1U ||
        sanitized_fixture.at("evidence_class") !=
            "sanitized_fixture_test_evidence_not_market_evidence" ||
        !sanitized_fixture.at("records").is_array()) {
        throw PipelineError("replay fixture schema is invalid");
    }
    Json rows = Json::array();
    for (const auto& record : sanitized_fixture.at("records")) {
        require_exact_keys(
            record,
            {"amount_in",
             "block",
             "call_result",
             "code_result",
             "observed_epoch_ms",
             "route_id"});
        const auto& route =
            config.route(require_string(record.at("route_id"), "replay route_id"));
        const auto amount =
            require_uint64(record.at("amount_in"), "replay amount_in");
        if (amount == 0U || amount > config.maximum_quote_amount) {
            throw PipelineError("replay amount exceeds configured bound");
        }
        const Json block = parse_replay_block(record.at("block"));
        if (block.at("observed_epoch_ms").get<std::uint64_t>() >
            static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
            throw PipelineError("replay block observation time is out of range");
        }
        const auto observed = require_uint64(
            record.at("observed_epoch_ms"), "replay observed_epoch_ms");
        if (observed >
            static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
            throw PipelineError("replay observation time is out of range");
        }
        const std::string code =
            require_string(record.at("code_result"), "replay code_result", 65'536U);
        validate_code(code);
        const std::string response = require_string(
            record.at("call_result"), "replay call_result", 65'536U);
        const std::string calldata = encode_get_amounts_out(
            amount, route.token_in, route.token_out, config.maximum_calldata_bytes);
        const auto output = decode_get_amounts_out(response, amount);
        const searcher::BlockContext context{
            .number = block.at("number").get<std::uint64_t>(),
            .hash = block.at("hash").get<std::string>(),
            .parent_hash = block.at("parent_hash").get<std::string>(),
            .status = searcher::BlockStatus::confirmed,
            .observed_epoch_ms =
                static_cast<std::int64_t>(block.at("observed_epoch_ms").get<std::uint64_t>()),
        };
        const Json binding = quote_binding(
            config,
            to_route(route),
            context,
            amount,
            calldata,
            response,
            static_cast<std::int64_t>(observed));
        rows.push_back(
            {{"route_id", route.id},
             {"block_number", context.number},
             {"block_hash", context.hash},
             {"amount_in", std::to_string(amount)},
             {"amount_out", std::to_string(output)},
             {"calldata_sha256", sha256_hex(calldata)},
             {"code_sha256", sha256_hex(code)},
             {"quote_sha256", sha256_hex(binding.dump())},
             {"observed_epoch_ms", observed}});
    }
    std::sort(rows.begin(), rows.end(), [](const Json& left, const Json& right) {
        return std::tie(
                   left.at("block_number"),
                   left.at("route_id"),
                   left.at("amount_in")) <
            std::tie(
                   right.at("block_number"),
                   right.at("route_id"),
                   right.at("amount_in"));
    });
    Json output{
        {"schema_version", 1},
        {"kind", "polygon_pipeline_offline_replay"},
        {"evidence_class",
         "sanitized_fixture_test_evidence_not_market_evidence"},
        {"chain_id", config.chain_id},
        {"evidence_revision", config.evidence_revision},
        {"records", rows},
    };
    output["replay_sha256"] = sha256_hex(output.dump());
    std::ostringstream csv;
    csv << "evidence_class,route_id,block_number,block_hash,amount_in,amount_out,"
           "calldata_sha256,code_sha256,quote_sha256,observed_epoch_ms\n";
    for (const auto& row : rows) {
        csv << "sanitized_fixture_test_evidence_not_market_evidence,"
            << row.at("route_id").get<std::string>() << ','
            << row.at("block_number").get<std::uint64_t>() << ','
            << row.at("block_hash").get<std::string>() << ','
            << row.at("amount_in").get<std::string>() << ','
            << row.at("amount_out").get<std::string>() << ','
            << row.at("calldata_sha256").get<std::string>() << ','
            << row.at("code_sha256").get<std::string>() << ','
            << row.at("quote_sha256").get<std::string>() << ','
            << row.at("observed_epoch_ms").get<std::uint64_t>() << '\n';
    }
    return {.json = std::move(output), .csv = csv.str()};
}

void write_replay_output(
    const ReplayOutput& output, const std::filesystem::path& output_prefix) {
    if (output_prefix.empty() || !output_prefix.parent_path().empty()) {
        throw PipelineError("replay output prefix must be a local filename");
    }
    std::ofstream json_file(output_prefix.string() + ".json", std::ios::trunc);
    std::ofstream csv_file(output_prefix.string() + ".csv", std::ios::trunc);
    if (!json_file || !csv_file) {
        throw PipelineError("unable to create replay output files");
    }
    json_file << output.json.dump(2) << '\n';
    csv_file << output.csv;
    if (!json_file || !csv_file) {
        throw PipelineError("unable to write replay output files");
    }
}

}  // namespace godbrain::polygon::pipeline
