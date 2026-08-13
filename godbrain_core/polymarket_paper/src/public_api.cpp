#include "polymarket/paper.hpp"

#include <algorithm>
#include <cctype>
#include <charconv>
#include <limits>

namespace polymarket::paper {
namespace {

std::string required_string(const Json& object, const char* key) {
    if (!object.contains(key)) {
        throw PaperError(std::string("missing field: ") + key);
    }
    const Json& value = object.at(key);
    if (value.is_string() && !value.get_ref<const std::string&>().empty()) {
        return value.get<std::string>();
    }
    if (value.is_number_integer() || value.is_number_unsigned()) {
        return value.dump();
    }
    throw PaperError(std::string("invalid string field: ") + key);
}

bool required_bool(const Json& object, const char* key) {
    if (!object.contains(key) || !object.at(key).is_boolean()) {
        throw PaperError(std::string("invalid boolean field: ") + key);
    }
    return object.at(key).get<bool>();
}

Decimal required_decimal(const Json& object, const char* key, bool round_up = false) {
    if (!object.contains(key)) {
        throw PaperError(std::string("missing decimal field: ") + key);
    }
    const Json& value = object.at(key);
    if (value.is_string()) {
        return Decimal::parse(value.get_ref<const std::string&>(), round_up);
    }
    if (value.is_number()) {
        return Decimal::parse(value.dump(), round_up);
    }
    throw PaperError(std::string("invalid decimal field: ") + key);
}

Json decoded_array(const Json& object, const char* key) {
    if (!object.contains(key)) {
        throw PaperError(std::string("missing array field: ") + key);
    }
    const Json& value = object.at(key);
    if (value.is_array()) {
        return value;
    }
    if (value.is_string()) {
        try {
            Json parsed = Json::parse(value.get_ref<const std::string&>());
            if (parsed.is_array()) {
                return parsed;
            }
        } catch (const Json::exception&) {
        }
    }
    throw PaperError(std::string("invalid array field: ") + key);
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::int64_t parse_epoch_ms(const Json& value) {
    std::string text;
    if (value.is_string()) {
        text = value.get<std::string>();
    } else if (value.is_number_integer() || value.is_number_unsigned()) {
        text = value.dump();
    } else {
        throw PaperError("book timestamp must be epoch milliseconds");
    }
    std::int64_t timestamp = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), timestamp);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size() ||
        timestamp < 1'500'000'000'000LL) {
        throw PaperError("invalid book epoch-millisecond timestamp");
    }
    return timestamp;
}

std::vector<Level> levels(const Json& book, const char* key, bool asks) {
    if (!book.contains(key) || !book.at(key).is_array()) {
        throw PaperError(std::string("invalid book levels: ") + key);
    }
    std::vector<Level> parsed;
    parsed.reserve(book.at(key).size());
    for (const Json& item : book.at(key)) {
        if (!item.is_object()) {
            throw PaperError("book level must be an object");
        }
        const Decimal price = required_decimal(item, "price", asks);
        const Decimal size = required_decimal(item, "size");
        if (price <= Decimal::from_raw(0) || price >= Decimal::parse("1") ||
            size <= Decimal::from_raw(0)) {
            throw PaperError("book level is outside valid bounds");
        }
        parsed.push_back({price, size});
    }
    std::sort(parsed.begin(), parsed.end(), [asks](const Level& left, const Level& right) {
        return asks ? left.price < right.price : left.price > right.price;
    });
    return parsed;
}

Market parse_market(const Json& item) {
    if (!item.is_object()) {
        throw PaperError("market entry must be an object");
    }
    const Json outcomes = decoded_array(item, "outcomes");
    const Json tokens = decoded_array(item, "clobTokenIds");
    if (outcomes.size() != 2 || tokens.size() != 2 ||
        !outcomes[0].is_string() || !outcomes[1].is_string() ||
        !tokens[0].is_string() || !tokens[1].is_string()) {
        throw PaperError("market must contain exactly two named outcome tokens");
    }

    const std::string first = lower(outcomes[0].get<std::string>());
    const std::string second = lower(outcomes[1].get<std::string>());
    std::size_t yes_index = 0;
    std::size_t no_index = 1;
    if (first == "no" && second == "yes") {
        yes_index = 1;
        no_index = 0;
    } else if (first != "yes" || second != "no") {
        throw PaperError("market outcomes are not complementary YES/NO");
    }

    Market market{
        .id = required_string(item, "id"),
        .condition_id = required_string(item, "conditionId"),
        .question = required_string(item, "question"),
        .yes_token_id = tokens[yes_index].get<std::string>(),
        .no_token_id = tokens[no_index].get<std::string>(),
        .accepting_orders = required_bool(item, "acceptingOrders"),
        .active = required_bool(item, "active"),
        .closed = required_bool(item, "closed"),
        .archived = required_bool(item, "archived"),
        .restricted = required_bool(item, "restricted"),
        .order_book_enabled = required_bool(item, "enableOrderBook"),
        .negative_risk = required_bool(item, "negRisk"),
        .tick_size = required_decimal(item, "orderPriceMinTickSize", true),
        .min_order_size = required_decimal(item, "orderMinSize", true),
    };
    if (!market.supported()) {
        throw PaperError("market is not active, ordinary, and binary");
    }
    return market;
}

}  // namespace

PublicApi::PublicApi(PublicTransport& transport, DiscoveryConfig config)
    : transport_(transport), config_(config) {
    if (config_.page_size == 0 || config_.page_size > 100 ||
        config_.max_pages == 0 || config_.max_pages > 20) {
        throw PaperError("unsafe discovery bounds");
    }
}

std::vector<Market> PublicApi::discover_binary_markets() {
    std::vector<Market> markets;
    std::string cursor;
    std::set<std::string> observed_cursors;
    for (std::size_t page = 0; page < config_.max_pages; ++page) {
        std::map<std::string, std::string> query{
            {"closed", "false"},
            {"limit", std::to_string(config_.page_size)},
        };
        if (!cursor.empty()) {
            query.emplace("after_cursor", cursor);
        }
        const Json response = transport_.get(
            PublicService::gamma,
            "/markets/keyset",
            query);
        if (!response.is_object() || !response.contains("markets") ||
            !response.at("markets").is_array()) {
            throw PaperError("Gamma keyset response must contain a markets array");
        }
        const Json& page_markets = response.at("markets");
        for (const Json& item : page_markets) {
            try {
                markets.push_back(parse_market(item));
            } catch (const PaperError&) {
                // Malformed and unsupported markets are excluded, never guessed.
            }
        }
        if (page_markets.size() < config_.page_size ||
            !response.contains("next_cursor")) {
            break;
        }
        if (!response.at("next_cursor").is_string() ||
            response.at("next_cursor").get_ref<const std::string&>().empty()) {
            throw PaperError("Gamma keyset cursor is malformed");
        }
        cursor = response.at("next_cursor").get<std::string>();
        if (!observed_cursors.insert(cursor).second) {
            throw PaperError("Gamma keyset cursor repeated");
        }
    }
    return markets;
}

Book PublicApi::order_book(const std::string& token_id) {
    if (token_id.empty() || token_id.size() > 256 ||
        !std::all_of(token_id.begin(), token_id.end(), [](unsigned char character) {
            return std::isdigit(character) != 0;
        })) {
        throw PaperError("invalid public token identifier");
    }
    const Json response = transport_.get(
        PublicService::clob, "/book", {{"token_id", token_id}});
    if (!response.is_object()) {
        throw PaperError("CLOB book response must be an object");
    }
    const std::string asset_id = required_string(response, "asset_id");
    if (asset_id != token_id) {
        throw PaperError("CLOB book token does not match request");
    }
    Book book{
        .token_id = asset_id,
        .condition_id = required_string(response, "market"),
        .hash = required_string(response, "hash"),
        .observed_epoch_ms = parse_epoch_ms(response.at("timestamp")),
        .asks = levels(response, "asks", true),
        .bids = levels(response, "bids", false),
        .tick_size = required_decimal(response, "tick_size", true),
        .min_order_size = required_decimal(response, "min_order_size", true),
    };
    if (required_bool(response, "neg_risk")) {
        throw PaperError("negative-risk public book rejected");
    }
    const Decimal last_trade = required_decimal(response, "last_trade_price");
    if (last_trade < Decimal::from_raw(0) || last_trade > Decimal::parse("1")) {
        throw PaperError("invalid last trade price");
    }
    if (book.tick_size <= Decimal::from_raw(0) ||
        book.min_order_size <= Decimal::from_raw(0)) {
        throw PaperError("invalid book constraints");
    }
    const auto aligned = [&](const Level& level) {
        return level.price.raw() % book.tick_size.raw() == 0;
    };
    if (!std::all_of(book.asks.begin(), book.asks.end(), aligned) ||
        !std::all_of(book.bids.begin(), book.bids.end(), aligned)) {
        throw PaperError("book price is not aligned to tick size");
    }
    if (!book.asks.empty() && !book.bids.empty() &&
        book.bids.front().price >= book.asks.front().price) {
        throw PaperError("crossed or locked public book rejected");
    }
    return book;
}

}  // namespace polymarket::paper
