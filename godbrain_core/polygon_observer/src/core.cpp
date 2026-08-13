#include "godbrain/polygon_observer.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <iostream>
#include <limits>
#include <sstream>
#include <utility>

namespace godbrain::polygon {
namespace {

constexpr std::size_t maximum_endpoint_length = 2'048;

bool is_ascii_printable(std::string_view value) {
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character >= 0x21 && character <= 0x7e;
    });
}

std::string lower_ascii(std::string_view value) {
    std::string result(value);
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return result;
}

std::uint16_t parse_port(std::string_view value) {
    unsigned int parsed = 0;
    const auto [end, error] =
        std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (value.empty() || error != std::errc{} || end != value.data() + value.size() ||
        parsed == 0 || parsed > std::numeric_limits<std::uint16_t>::max()) {
        throw EndpointError("endpoint requires a valid explicit port");
    }
    return static_cast<std::uint16_t>(parsed);
}

std::uint64_t parse_hex_quantity(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw RpcProtocolError(std::string(field) + " must be a hex quantity string");
    }
    const std::string text = value.get<std::string>();
    if (text.size() < 3 || text[0] != '0' || text[1] != 'x' ||
        (text.size() > 3 && text[2] == '0')) {
        throw RpcProtocolError(std::string(field) + " is not a canonical hex quantity");
    }
    std::uint64_t parsed = 0;
    const auto [end, error] =
        std::from_chars(text.data() + 2, text.data() + text.size(), parsed, 16);
    if (error != std::errc{} || end != text.data() + text.size()) {
        throw RpcProtocolError(std::string(field) + " is not a valid hex quantity");
    }
    return parsed;
}

bool is_hash(std::string_view value) {
    if (value.size() != 66 || value.substr(0, 2) != "0x") {
        return false;
    }
    return std::all_of(value.begin() + 2, value.end(), [](unsigned char character) {
        return std::isxdigit(character) != 0;
    });
}

std::string client_release(std::string_view version) {
    const std::string lower = lower_ascii(version);
    const auto slash = lower.find('/');
    if (slash == std::string::npos) {
        return {};
    }
    std::size_t first = slash + 1;
    if (first < lower.size() && lower[first] == 'v') {
        ++first;
    }
    std::size_t end = first;
    while (end < lower.size() &&
           (std::isdigit(static_cast<unsigned char>(lower[end])) != 0 ||
            lower[end] == '.')) {
        ++end;
    }
    return lower.substr(first, end - first);
}

bool client_is_supported(std::string_view version, const HealthPolicy& policy) {
    const std::string lower = lower_ascii(version);
    if (lower.find(lower_ascii(policy.required_client_product)) == std::string::npos) {
        return false;
    }
    return policy.accepted_client_versions.contains(client_release(version));
}

void update_latency(HealthSnapshot& health, const RpcClient& client) {
    health.rpc_latency = std::max(health.rpc_latency, client.last_latency());
}

bool is_windows_absolute_local_path(const std::filesystem::path& path) {
    const std::string value = path.string();
    if (value.size() < 4 ||
        !std::isalpha(static_cast<unsigned char>(value[0])) ||
        value[1] != ':' || value[2] != '\\' ||
        value.find('/') != std::string::npos) {
        return false;
    }
    if (value.find_first_of("<>\"|?*") != std::string::npos ||
        value.find(':', 2) != std::string::npos) {
        return false;
    }
    std::size_t start = 3;
    while (start <= value.size()) {
        const std::size_t end = value.find('\\', start);
        const std::string_view component(
            value.data() + start,
            (end == std::string::npos ? value.size() : end) - start);
        if (component.empty() || component == "." || component == ".." ||
            component.back() == ' ' || component.back() == '.') {
            return false;
        }
        const std::size_t extension = component.find('.');
        const std::string base = lower_ascii(component.substr(0, extension));
        static const std::set<std::string> reserved{
            "con", "prn", "aux", "nul",
            "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
            "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
        };
        if (reserved.contains(base)) {
            return false;
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return is_ascii_printable(value);
}

std::string powershell_quote(std::string_view value) {
    std::string result("'");
    for (const char character : value) {
        if (character == '\'') {
            result += "''";
        } else {
            result += character;
        }
    }
    result += '\'';
    return result;
}

std::string join(const std::vector<std::string>& values, std::string_view separator) {
    std::ostringstream output;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) {
            output << separator;
        }
        output << values[index];
    }
    return output.str();
}

std::string normalized_key(std::string_view key) {
    std::string result;
    for (const unsigned char character : key) {
        if (std::isalnum(character) != 0) {
            result += static_cast<char>(std::tolower(character));
        }
    }
    return result;
}

void inspect_sensitive_names(const Json& value) {
    static const std::vector<std::string> forbidden{
        "privatekey",
        "mnemonic",
        "seedphrase",
        "credential",
        "password",
        "secret",
        "signer",
        "sendrawtransaction",
        "wallet",
        "unlock",
    };
    if (value.is_object()) {
        for (const auto& [key, child] : value.items()) {
            const std::string normalized = normalized_key(key);
            if (std::any_of(
                    forbidden.begin(), forbidden.end(), [&](const std::string& marker) {
                        return normalized.find(marker) != std::string::npos;
                    })) {
                throw ObserverError("configuration contains a forbidden sensitive key");
            }
            inspect_sensitive_names(child);
        }
    } else if (value.is_array()) {
        for (const auto& child : value) {
            inspect_sensitive_names(child);
        }
    }
}

std::string sanitize_log_text(std::string_view value) {
    std::string result;
    result.reserve(std::min<std::size_t>(value.size(), 160));
    for (const unsigned char character : value.substr(0, 160)) {
        if (std::isalnum(character) != 0 || character == ' ' || character == '_' ||
            character == '-' || character == '.' || character == ':') {
            result += static_cast<char>(character);
        } else {
            result += '?';
        }
    }
    return result;
}

}  // namespace

RpcRemoteError::RpcRemoteError(std::int64_t code, std::string message)
    : ObserverError("JSON-RPC error " + std::to_string(code) + ": " + message),
      code_(code) {}

std::int64_t RpcRemoteError::code() const noexcept {
    return code_;
}

Endpoint parse_local_endpoint(std::string_view value) {
    if (value.empty() || value.size() > maximum_endpoint_length ||
        !is_ascii_printable(value) || value.find_first_of("%\\?#@") != std::string_view::npos) {
        throw EndpointError("endpoint contains prohibited or ambiguous characters");
    }

    bool secure = false;
    std::string_view remainder;
    if (value.starts_with("http://")) {
        remainder = value.substr(7);
    } else if (value.starts_with("https://")) {
        secure = true;
        remainder = value.substr(8);
    } else {
        throw EndpointError("endpoint scheme must be http or https");
    }

    const std::size_t path_start = remainder.find('/');
    if (path_start == std::string_view::npos) {
        throw EndpointError("endpoint requires an explicit path");
    }
    const std::string_view authority = remainder.substr(0, path_start);
    const std::string_view path = remainder.substr(path_start);
    if (path.empty() || path.front() != '/' || path.find("//") != std::string_view::npos ||
        path.find("/../") != std::string_view::npos || path.ends_with("/..")) {
        throw EndpointError("endpoint path is invalid");
    }

    std::string host;
    std::string_view port;
    if (authority.starts_with("[::1]:")) {
        host = "::1";
        port = authority.substr(6);
    } else {
        const std::size_t colon = authority.rfind(':');
        if (colon == std::string_view::npos ||
            authority.find(':') != colon) {
            throw EndpointError("endpoint requires an unambiguous host and explicit port");
        }
        host = lower_ascii(authority.substr(0, colon));
        port = authority.substr(colon + 1);
        if (host != "localhost" && host != "127.0.0.1") {
            throw EndpointError("remote RPC endpoints are prohibited");
        }
    }

    return Endpoint{
        .secure = secure,
        .host = std::move(host),
        .port = parse_port(port),
        .path = std::string(path),
    };
}

std::string endpoint_display(const Endpoint& endpoint) {
    const std::string host = endpoint.host == "::1" ? "[::1]" : endpoint.host;
    return std::string(endpoint.secure ? "https://" : "http://") + host + ":" +
        std::to_string(endpoint.port) + endpoint.path;
}

std::string_view rpc_method_name(RpcMethod method) {
    switch (method) {
    case RpcMethod::web3_client_version:
        return "web3_clientVersion";
    case RpcMethod::eth_chain_id:
        return "eth_chainId";
    case RpcMethod::eth_block_number:
        return "eth_blockNumber";
    case RpcMethod::eth_syncing:
        return "eth_syncing";
    case RpcMethod::net_peer_count:
        return "net_peerCount";
    case RpcMethod::eth_get_block_by_number:
        return "eth_getBlockByNumber";
    case RpcMethod::eth_get_transaction_receipt:
        return "eth_getTransactionReceipt";
    }
    throw ObserverError("unknown RPC method enum");
}

const std::set<std::string>& read_only_rpc_method_names() {
    static const std::set<std::string> names{
        "web3_clientVersion",
        "eth_chainId",
        "eth_blockNumber",
        "eth_syncing",
        "net_peerCount",
        "eth_getBlockByNumber",
        "eth_getTransactionReceipt",
    };
    return names;
}

RpcClient::RpcClient(
    RpcTransport& transport,
    Endpoint endpoint,
    TransportLimits limits)
    : transport_(transport), endpoint_(std::move(endpoint)), limits_(limits) {
    if (limits_.maximum_request_bytes == 0 || limits_.maximum_response_bytes == 0 ||
        limits_.maximum_json_depth == 0) {
        throw ObserverError("transport limits must be positive");
    }
}

Json RpcClient::call(RpcMethod method, Json params) {
    if (!params.is_array()) {
        throw ObserverError("JSON-RPC params must be an array");
    }
    if (next_id_ == std::numeric_limits<std::uint64_t>::max()) {
        throw ObserverError("JSON-RPC request ID space exhausted");
    }
    const std::uint64_t id = next_id_++;
    const Json request{
        {"jsonrpc", "2.0"},
        {"id", id},
        {"method", rpc_method_name(method)},
        {"params", std::move(params)},
    };
    const std::string body = request.dump();
    if (body.size() > limits_.maximum_request_bytes) {
        throw TransportError("JSON-RPC request exceeds size limit");
    }

    const HttpResponse response = transport_.post(endpoint_, body, limits_);
    last_latency_ = response.latency;
    if (response.status >= 300 && response.status < 400) {
        throw TransportError("JSON-RPC redirect rejected");
    }
    if (response.status != 200) {
        throw TransportError("JSON-RPC HTTP status is not 200");
    }
    if (response.body.size() > limits_.maximum_response_bytes) {
        throw TransportError("JSON-RPC response exceeds size limit");
    }

    Json parsed;
    try {
        const auto callback = [&](int depth, Json::parse_event_t event, Json&) {
            if ((event == Json::parse_event_t::object_start ||
                 event == Json::parse_event_t::array_start) &&
                depth >= static_cast<int>(limits_.maximum_json_depth)) {
                throw RpcProtocolError("JSON-RPC response exceeds nesting limit");
            }
            return true;
        };
        parsed = Json::parse(response.body, callback);
    } catch (const RpcProtocolError&) {
        throw;
    } catch (const Json::exception&) {
        throw RpcProtocolError("JSON-RPC response is malformed JSON");
    }

    if (!parsed.is_object() || !parsed.contains("jsonrpc") ||
        parsed.at("jsonrpc") != "2.0" || !parsed.contains("id")) {
        throw RpcProtocolError("JSON-RPC response envelope is invalid");
    }
    const Json& response_id = parsed.at("id");
    const bool id_matches =
        (response_id.is_number_unsigned() && response_id.get<std::uint64_t>() == id) ||
        (response_id.is_number_integer() && response_id.get<std::int64_t>() >= 0 &&
         static_cast<std::uint64_t>(response_id.get<std::int64_t>()) == id);
    if (!id_matches) {
        throw RpcProtocolError("JSON-RPC response ID does not match request");
    }
    const bool has_result = parsed.contains("result");
    const bool has_error = parsed.contains("error");
    if (has_result == has_error) {
        throw RpcProtocolError("JSON-RPC response must contain exactly one of result or error");
    }
    if (has_error) {
        const Json& error = parsed.at("error");
        if (!error.is_object() || !error.contains("code") ||
            !error.at("code").is_number_integer() || !error.contains("message") ||
            !error.at("message").is_string()) {
            throw RpcProtocolError("JSON-RPC error object is invalid");
        }
        throw RpcRemoteError(
            error.at("code").get<std::int64_t>(),
            error.at("message").get<std::string>());
    }
    return parsed.at("result");
}

std::chrono::milliseconds RpcClient::last_latency() const noexcept {
    return last_latency_;
}

std::chrono::system_clock::time_point SystemClock::now() const {
    return std::chrono::system_clock::now();
}

HeimdallStatusClient::HeimdallStatusClient(
    RpcTransport& transport,
    Endpoint endpoint,
    TransportLimits limits)
    : transport_(transport), endpoint_(std::move(endpoint)), limits_(limits) {
    if (endpoint_.path != "/status") {
        throw EndpointError("Heimdall status endpoint path must be /status");
    }
}

bool HeimdallStatusClient::synced() {
    const HttpResponse response = transport_.get(endpoint_, limits_);
    last_latency_ = response.latency;
    if (response.status >= 300 && response.status < 400) {
        throw TransportError("Heimdall status redirect rejected");
    }
    if (response.status != 200 ||
        response.body.size() > limits_.maximum_response_bytes) {
        throw TransportError("Heimdall status response is invalid");
    }
    Json parsed;
    try {
        const auto callback = [&](int depth, Json::parse_event_t event, Json&) {
            if ((event == Json::parse_event_t::object_start ||
                 event == Json::parse_event_t::array_start) &&
                depth >= static_cast<int>(limits_.maximum_json_depth)) {
                throw RpcProtocolError("Heimdall status exceeds nesting limit");
            }
            return true;
        };
        parsed = Json::parse(response.body, callback);
    } catch (const RpcProtocolError&) {
        throw;
    } catch (const Json::exception&) {
        throw RpcProtocolError("Heimdall status is malformed JSON");
    }
    if (!parsed.is_object() || !parsed.contains("result") ||
        !parsed.at("result").is_object() ||
        !parsed.at("result").contains("sync_info") ||
        !parsed.at("result").at("sync_info").is_object() ||
        !parsed.at("result").at("sync_info").contains("catching_up") ||
        !parsed.at("result").at("sync_info").at("catching_up").is_boolean()) {
        throw RpcProtocolError("Heimdall status envelope is invalid");
    }
    return !parsed.at("result").at("sync_info").at("catching_up").get<bool>();
}

std::chrono::milliseconds HeimdallStatusClient::last_latency() const noexcept {
    return last_latency_;
}

HealthObserver::HealthObserver(
    RpcClient& client,
    HeimdallStatusClient& heimdall,
    const Clock& clock,
    HealthPolicy policy)
    : client_(client),
      heimdall_(heimdall),
      clock_(clock),
      policy_(std::move(policy)) {}

HealthSnapshot HealthObserver::inspect() {
    HealthSnapshot health;
    try {
        const Json version = client_.call(RpcMethod::web3_client_version);
        update_latency(health, client_);
        if (!version.is_string()) {
            throw RpcProtocolError("web3_clientVersion result must be a string");
        }
        health.reachable = true;
        health.client_version = version.get<std::string>();
        if (health.client_version.empty() || health.client_version.size() > 256 ||
            !is_ascii_printable(health.client_version)) {
            throw RpcProtocolError("web3_clientVersion result is invalid");
        }
        health.client_supported = client_is_supported(health.client_version, policy_);

        health.chain_id = parse_hex_quantity(
            client_.call(RpcMethod::eth_chain_id), "eth_chainId");
        update_latency(health, client_);
        health.reported_block_number = parse_hex_quantity(
            client_.call(RpcMethod::eth_block_number), "eth_blockNumber");
        update_latency(health, client_);

        const Json syncing = client_.call(RpcMethod::eth_syncing);
        update_latency(health, client_);
        if (syncing.is_boolean() && !syncing.get<bool>()) {
            health.sync.syncing = false;
        } else if (syncing.is_object() && syncing.contains("currentBlock") &&
                   syncing.contains("highestBlock")) {
            health.sync.syncing = true;
            health.sync.current_block =
                parse_hex_quantity(syncing.at("currentBlock"), "sync currentBlock");
            health.sync.highest_block =
                parse_hex_quantity(syncing.at("highestBlock"), "sync highestBlock");
            if (*health.sync.current_block > *health.sync.highest_block) {
                throw RpcProtocolError("eth_syncing block range is invalid");
            }
        } else {
            throw RpcProtocolError("eth_syncing result is invalid");
        }

        health.peer_count = parse_hex_quantity(
            client_.call(RpcMethod::net_peer_count), "net_peerCount");
        update_latency(health, client_);

        const Json block = client_.call(
            RpcMethod::eth_get_block_by_number, Json::array({"latest", false}));
        update_latency(health, client_);
        if (!block.is_object() || !block.contains("number") || !block.contains("hash") ||
            !block.contains("timestamp") || !block.at("hash").is_string()) {
            throw RpcProtocolError("latest block header is incomplete");
        }
        health.latest_block_number =
            parse_hex_quantity(block.at("number"), "latest block number");
        health.latest_block_hash = block.at("hash").get<std::string>();
        if (!is_hash(health.latest_block_hash)) {
            throw RpcProtocolError("latest block hash is invalid");
        }
        const std::uint64_t timestamp =
            parse_hex_quantity(block.at("timestamp"), "latest block timestamp");
        if (timestamp > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
            throw RpcProtocolError("latest block timestamp is out of range");
        }
        health.latest_block_timestamp = static_cast<std::int64_t>(timestamp);
        const auto now_seconds = std::chrono::duration_cast<std::chrono::seconds>(
            clock_.now().time_since_epoch()).count();
        health.latest_block_age_seconds = now_seconds - *health.latest_block_timestamp;

    } catch (const ObserverError&) {
        health.readiness_reasons.push_back("rpc_observation_failed");
        return health;
    }

    try {
        health.heimdall_synced = heimdall_.synced();
        health.heimdall_reachable = true;
        health.rpc_latency =
            std::max(health.rpc_latency, heimdall_.last_latency());
    } catch (const ObserverError&) {
        health.readiness_reasons.push_back("heimdall_status_failed");
    }

    if (health.chain_id != policy_.required_chain_id) {
        health.readiness_reasons.push_back("wrong_chain");
    }
    if (!health.client_supported) {
        health.readiness_reasons.push_back("unsupported_client");
    }
    if (health.sync.syncing) {
        health.readiness_reasons.push_back("node_syncing");
    }
    if (health.heimdall_reachable && !health.heimdall_synced) {
        health.readiness_reasons.push_back("heimdall_syncing");
    }
    if (policy_.require_peers && health.peer_count.value_or(0) == 0) {
        health.readiness_reasons.push_back("no_peers");
    }
    if (!health.latest_block_age_seconds.has_value() ||
        *health.latest_block_age_seconds < -30) {
        health.readiness_reasons.push_back("latest_block_from_future");
    } else if (*health.latest_block_age_seconds > policy_.maximum_block_age.count()) {
        health.readiness_reasons.push_back("latest_block_stale");
    }
    if (health.latest_block_number < health.reported_block_number) {
        health.readiness_reasons.push_back("latest_block_inconsistent");
    }
    if (health.rpc_latency > policy_.maximum_rpc_latency) {
        health.readiness_reasons.push_back("rpc_latency_exceeded");
    }
    health.ready = health.readiness_reasons.empty();
    return health;
}

Json health_to_json(const HealthSnapshot& health) {
    const auto optional_uint = [](const std::optional<std::uint64_t>& value) -> Json {
        return value.has_value() ? Json(*value) : Json(nullptr);
    };
    const auto optional_int = [](const std::optional<std::int64_t>& value) -> Json {
        return value.has_value() ? Json(*value) : Json(nullptr);
    };
    return Json{
        {"schema_version", 1},
        {"reachable", health.reachable},
        {"ready", health.ready},
        {"readiness_reasons", health.readiness_reasons},
        {"heimdall_v2", {
            {"reachable", health.heimdall_reachable},
            {"synced", health.heimdall_synced},
            {"role", "consensus_only"},
        }},
        {"chain", {
            {"required_id", 137},
            {"observed_id", optional_uint(health.chain_id)},
            {"correct", health.chain_id == 137},
        }},
        {"client", {
            {"version", health.client_version},
            {"supported", health.client_supported},
            {"accepted_release", "2.10.0"},
        }},
        {"sync", {
            {"syncing", health.sync.syncing},
            {"current_block", optional_uint(health.sync.current_block)},
            {"highest_block", optional_uint(health.sync.highest_block)},
        }},
        {"peers", optional_uint(health.peer_count)},
        {"head", {
            {"reported_number", optional_uint(health.reported_block_number)},
            {"number", optional_uint(health.latest_block_number)},
            {"hash", health.latest_block_hash},
            {"timestamp", optional_int(health.latest_block_timestamp)},
            {"age_seconds", optional_int(health.latest_block_age_seconds)},
        }},
        {"rpc_latency_ms", health.rpc_latency.count()},
        {"observation_mode", "confirmed_blocks_only"},
    };
}

OperatorConfig OperatorConfig::from_json(const Json& value) {
    reject_sensitive_config_names(value);
    if (!value.is_object()) {
        throw ObserverError("operator configuration must be a JSON object");
    }
    static const std::set<std::string> allowed{
        "bor_executable",
        "bor_data_directory",
        "heimdall_executable",
        "heimdall_home_directory",
        "heimdall_rest_endpoint",
        "heimdall_comet_endpoint",
        "ethereum_l1_endpoint",
        "bor_http_port",
        "bor_http_path",
        "bor_http_api",
        "minimum_free_space_gib",
    };
    for (const auto& [key, unused] : value.items()) {
        (void)unused;
        if (!allowed.contains(key)) {
            throw ObserverError("operator configuration contains an unknown key");
        }
    }
    for (const auto& required : allowed) {
        if (!value.contains(required)) {
            throw ObserverError("operator configuration is missing a required key");
        }
    }
    if (!value.at("bor_executable").is_string() ||
        !value.at("bor_data_directory").is_string() ||
        !value.at("heimdall_executable").is_string() ||
        !value.at("heimdall_home_directory").is_string() ||
        !value.at("heimdall_rest_endpoint").is_string() ||
        !value.at("heimdall_comet_endpoint").is_string() ||
        !value.at("ethereum_l1_endpoint").is_string() ||
        !value.at("bor_http_port").is_number_integer() ||
        !value.at("bor_http_path").is_string() ||
        !value.at("bor_http_api").is_array() ||
        !value.at("minimum_free_space_gib").is_number_integer()) {
        throw ObserverError("operator configuration contains an invalid value type");
    }

    OperatorConfig config;
    config.bor_executable = value.at("bor_executable").get<std::string>();
    config.bor_data_directory = value.at("bor_data_directory").get<std::string>();
    config.heimdall_executable = value.at("heimdall_executable").get<std::string>();
    config.heimdall_home_directory =
        value.at("heimdall_home_directory").get<std::string>();
    config.heimdall_rest_endpoint =
        value.at("heimdall_rest_endpoint").get<std::string>();
    config.heimdall_comet_endpoint =
        value.at("heimdall_comet_endpoint").get<std::string>();
    config.ethereum_l1_endpoint =
        value.at("ethereum_l1_endpoint").get<std::string>();
    const auto port = value.at("bor_http_port").get<std::int64_t>();
    if (port <= 0 || port > std::numeric_limits<std::uint16_t>::max()) {
        throw ObserverError("Bor HTTP port is out of range");
    }
    config.bor_http_port = static_cast<std::uint16_t>(port);
    config.bor_http_path = value.at("bor_http_path").get<std::string>();
    const auto minimum_free_space =
        value.at("minimum_free_space_gib").get<std::int64_t>();
    if (minimum_free_space <= 0) {
        throw ObserverError("minimum_free_space_gib must be positive");
    }
    config.minimum_free_space_gib =
        static_cast<std::uint64_t>(minimum_free_space);
    config.bor_http_api.clear();
    for (const auto& entry : value.at("bor_http_api")) {
        if (!entry.is_string()) {
            throw ObserverError("Bor HTTP APIs must be strings");
        }
        config.bor_http_api.push_back(entry.get<std::string>());
    }
    config.validate();
    return config;
}

void OperatorConfig::validate() const {
    if (!is_windows_absolute_local_path(bor_executable) ||
        lower_ascii(bor_executable.extension().string()) != ".exe") {
        throw ObserverError("Bor executable must be an absolute local Windows .exe path");
    }
    if (!is_windows_absolute_local_path(bor_data_directory)) {
        throw ObserverError("Bor data directory must be an absolute local Windows path");
    }
    if (!is_windows_absolute_local_path(heimdall_executable) ||
        lower_ascii(heimdall_executable.extension().string()) != ".exe") {
        throw ObserverError(
            "Heimdall executable must be an absolute local Windows .exe path");
    }
    if (!is_windows_absolute_local_path(heimdall_home_directory)) {
        throw ObserverError(
            "Heimdall home directory must be an absolute local Windows path");
    }
    (void)parse_local_endpoint(heimdall_rest_endpoint);
    (void)parse_local_endpoint(heimdall_comet_endpoint);
    (void)parse_local_endpoint(ethereum_l1_endpoint);
    if (bor_http_port == 0) {
        throw ObserverError("Bor HTTP port must be non-zero");
    }
    if (bor_http_path != "/") {
        throw ObserverError("Bor HTTP path must be explicitly set to /");
    }
    if (minimum_free_space_gib == 0) {
        throw ObserverError("minimum_free_space_gib must be an explicit positive expectation");
    }

    static const std::set<std::string> permitted{"eth", "net", "web3", "bor"};
    std::set<std::string> unique;
    for (const auto& api : bor_http_api) {
        if (!permitted.contains(api) || !unique.insert(api).second) {
            throw ObserverError("Bor HTTP API list is invalid");
        }
    }
    if (!unique.contains("eth") || !unique.contains("net") ||
        !unique.contains("web3")) {
        throw ObserverError("Bor HTTP APIs must include eth, net, and web3");
    }
}

RenderedOperatorConfig render_operator_config(const OperatorConfig& config) {
    config.validate();
    const std::string api = join(config.bor_http_api, ",");
    std::vector<std::string> bor_arguments{
        "server",
        "--chain=mainnet",
        "--datadir=" + config.bor_data_directory.string(),
        "--bor.heimdall=" + config.heimdall_rest_endpoint,
        "--http",
        "--http.addr=127.0.0.1",
        "--http.port=" + std::to_string(config.bor_http_port),
        "--http.api=" + api,
        "--http.vhosts=localhost",
        "--http.corsdomain=localhost",
        "--ipcdisable",
        "--ws=false",
        "--gcmode=full",
        "--syncmode=snap",
        "--snapshot=true",
    };
    std::vector<std::string> heimdall_arguments{
        "start",
        "--home=" + config.heimdall_home_directory.string(),
    };

    std::ostringstream bor_preview;
    bor_preview << "& " << powershell_quote(config.bor_executable.string());
    for (const auto& argument : bor_arguments) {
        bor_preview << ' ' << powershell_quote(argument);
    }
    std::ostringstream heimdall_preview;
    heimdall_preview << "& " << powershell_quote(config.heimdall_executable.string());
    for (const auto& argument : heimdall_arguments) {
        heimdall_preview << ' ' << powershell_quote(argument);
    }

    Json manifest{
        {"schema_version", 1},
        {"render_only", true},
        {"release_assumptions", {
            {"bor", "2.10.0"},
            {"heimdall_v2", "0.10.0"},
        }},
        {"chain", "mainnet"},
        {"required_chain_id", 137},
        {"minimum_free_space_gib_expectation", config.minimum_free_space_gib},
        {"bor", {
            {"executable", config.bor_executable.string()},
            {"data_directory", config.bor_data_directory.string()},
            {"arguments", bor_arguments},
            {"heimdall_rest_endpoint", config.heimdall_rest_endpoint},
        }},
        {"heimdall_v2", {
            {"role", "consensus_only"},
            {"executable", config.heimdall_executable.string()},
            {"home_directory", config.heimdall_home_directory.string()},
            {"arguments", heimdall_arguments},
            {"required_app_toml", {
                {"api.address", "tcp://127.0.0.1:1317"},
                {"custom.bor_rpc_url",
                 "http://127.0.0.1:" + std::to_string(config.bor_http_port)},
                {"custom.eth_rpc_url", config.ethereum_l1_endpoint},
                {"custom.comet_bft_rpc_url", config.heimdall_comet_endpoint},
                {"custom.chain", "mainnet"},
            }},
            {"required_config_toml", {
                {"rpc.laddr", "tcp://127.0.0.1:26657"},
            }},
        }},
        {"bor_http", {
            {"address", "127.0.0.1"},
            {"port", config.bor_http_port},
            {"path", config.bor_http_path},
            {"api", config.bor_http_api},
            {"observer_methods", read_only_rpc_method_names()},
        }},
    };
    return {
        .bor_arguments = std::move(bor_arguments),
        .heimdall_arguments = std::move(heimdall_arguments),
        .bor_powershell_preview = bor_preview.str(),
        .heimdall_powershell_preview = heimdall_preview.str(),
        .manifest = std::move(manifest),
    };
}

void reject_sensitive_config_names(const Json& value) {
    inspect_sensitive_names(value);
}

SanitizedLogger::SanitizedLogger(bool enabled) : enabled_(enabled) {}

void SanitizedLogger::event(
    std::string_view level,
    std::string_view name,
    std::string_view detail) const {
    if (!enabled_) {
        return;
    }
    Json entry{
        {"level", sanitize_log_text(level)},
        {"event", sanitize_log_text(name)},
    };
    if (!detail.empty()) {
        entry["detail"] = sanitize_log_text(detail);
    }
    std::cerr << entry.dump() << '\n';
}

}  // namespace godbrain::polygon
