#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "json.hpp"

namespace godbrain::polygon::observer {

using Json = nlohmann::json;

class ObserverError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class EndpointError final : public ObserverError {
public:
    using ObserverError::ObserverError;
};

class TransportError final : public ObserverError {
public:
    using ObserverError::ObserverError;
};

class RpcProtocolError final : public ObserverError {
public:
    using ObserverError::ObserverError;
};

class RpcRemoteError final : public ObserverError {
public:
    RpcRemoteError(std::int64_t code, std::string message);
    [[nodiscard]] std::int64_t code() const noexcept;

private:
    std::int64_t code_;
};

struct Endpoint {
    bool secure{false};
    std::string host;
    std::uint16_t port{0};
    std::string path;

    friend bool operator==(const Endpoint&, const Endpoint&) = default;
};

Endpoint parse_local_endpoint(std::string_view value);
std::string endpoint_display(const Endpoint& endpoint);

struct TransportLimits {
    std::chrono::milliseconds resolve_timeout{2'000};
    std::chrono::milliseconds connect_timeout{2'000};
    std::chrono::milliseconds send_timeout{3'000};
    std::chrono::milliseconds receive_timeout{5'000};
    std::size_t maximum_request_bytes{64 * 1024};
    std::size_t maximum_response_bytes{1024 * 1024};
    std::size_t maximum_json_depth{32};
};

struct HttpResponse {
    unsigned int status{0};
    std::string body;
    std::chrono::milliseconds latency{0};
};

class RpcTransport {
public:
    virtual ~RpcTransport() = default;
    virtual HttpResponse post(
        const Endpoint& endpoint,
        std::string_view body,
        const TransportLimits& limits) = 0;
    virtual HttpResponse get(
        const Endpoint& endpoint,
        const TransportLimits& limits) = 0;
};

class WinHttpRpcTransport final : public RpcTransport {
public:
    HttpResponse post(
        const Endpoint& endpoint,
        std::string_view body,
        const TransportLimits& limits) override;
    HttpResponse get(
        const Endpoint& endpoint,
        const TransportLimits& limits) override;
};

enum class RpcMethod {
    web3_client_version,
    eth_chain_id,
    eth_block_number,
    eth_syncing,
    net_peer_count,
    eth_get_block_by_number,
    eth_get_code,
    eth_call,
    eth_get_transaction_receipt,
};

std::string_view rpc_method_name(RpcMethod method);
const std::set<std::string>& read_only_rpc_method_names();
std::string canonical_block_number_tag(std::uint64_t block_number);
Json build_get_block_params(std::uint64_t block_number);
Json build_get_code_params(
    std::string_view canonical_address,
    std::string_view canonical_block_tag);
Json build_eth_call_params(
    std::string_view canonical_to,
    std::string_view canonical_calldata,
    std::string_view canonical_block_tag);

class RpcClient {
public:
    RpcClient(
        RpcTransport& transport,
        Endpoint endpoint,
        TransportLimits limits = {});

    Json call(RpcMethod method, Json params = Json::array());
    [[nodiscard]] std::chrono::milliseconds last_latency() const noexcept;

private:
    RpcTransport& transport_;
    Endpoint endpoint_;
    TransportLimits limits_;
    std::uint64_t next_id_{1};
    std::chrono::milliseconds last_latency_{0};
};

class Clock {
public:
    virtual ~Clock() = default;
    [[nodiscard]] virtual std::chrono::system_clock::time_point now() const = 0;
};

class SystemClock final : public Clock {
public:
    [[nodiscard]] std::chrono::system_clock::time_point now() const override;
};

class HeimdallStatusClient {
public:
    HeimdallStatusClient(
        RpcTransport& transport,
        Endpoint endpoint,
        TransportLimits limits = {});
    bool synced();
    [[nodiscard]] std::chrono::milliseconds last_latency() const noexcept;

private:
    RpcTransport& transport_;
    Endpoint endpoint_;
    TransportLimits limits_;
    std::chrono::milliseconds last_latency_{0};
};

struct SyncState {
    bool syncing{true};
    std::optional<std::uint64_t> current_block;
    std::optional<std::uint64_t> highest_block;
};

struct HealthPolicy {
    std::uint64_t required_chain_id{137};
    std::string required_client_product{"bor"};
    std::set<std::string> accepted_client_versions{"2.10.0"};
    std::chrono::seconds maximum_block_age{120};
    std::chrono::milliseconds maximum_rpc_latency{5'000};
    bool require_peers{true};
};

struct HealthSnapshot {
    bool reachable{false};
    bool ready{false};
    bool heimdall_reachable{false};
    bool heimdall_synced{false};
    std::string client_version;
    bool client_supported{false};
    std::optional<std::uint64_t> chain_id;
    std::optional<std::uint64_t> reported_block_number;
    SyncState sync;
    std::optional<std::uint64_t> peer_count;
    std::optional<std::uint64_t> latest_block_number;
    std::string latest_block_hash;
    std::optional<std::int64_t> latest_block_timestamp;
    std::optional<std::int64_t> latest_block_age_seconds;
    std::chrono::milliseconds rpc_latency{0};
    std::vector<std::string> readiness_reasons;
};

class HealthObserver {
public:
    HealthObserver(
        RpcClient& client,
        HeimdallStatusClient& heimdall,
        const Clock& clock,
        HealthPolicy policy = {});

    HealthSnapshot inspect();

private:
    RpcClient& client_;
    HeimdallStatusClient& heimdall_;
    const Clock& clock_;
    HealthPolicy policy_;
};

Json health_to_json(const HealthSnapshot& health);

struct OperatorConfig {
    std::filesystem::path bor_executable;
    std::filesystem::path bor_data_directory;
    std::filesystem::path heimdall_executable;
    std::filesystem::path heimdall_home_directory;
    std::string heimdall_rest_endpoint;
    std::string heimdall_comet_endpoint;
    std::string ethereum_l1_endpoint;
    std::uint16_t bor_http_port{8545};
    std::string bor_http_path{"/"};
    std::vector<std::string> bor_http_api{"eth", "net", "web3", "bor"};
    std::uint64_t minimum_free_space_gib{0};

    static OperatorConfig from_json(const Json& value);
    void validate() const;
};

struct RenderedOperatorConfig {
    std::vector<std::string> bor_arguments;
    std::vector<std::string> heimdall_arguments;
    std::string bor_powershell_preview;
    std::string heimdall_powershell_preview;
    Json manifest;
};

RenderedOperatorConfig render_operator_config(const OperatorConfig& config);
void reject_sensitive_config_names(const Json& value);

class SanitizedLogger {
public:
    explicit SanitizedLogger(bool enabled = true);
    void event(std::string_view level, std::string_view name, std::string_view detail = {}) const;

private:
    bool enabled_;
};

struct AllowlistEntry {
    std::string address;
    std::string label;
    std::string source_url;
    std::string source_sha256;
    std::optional<unsigned int> decimals;
};

class VerifiedAllowlist {
public:
    static VerifiedAllowlist from_json(const Json& value);
    [[nodiscard]] bool has_venue(std::string_view address) const;
    [[nodiscard]] bool has_token(std::string_view address) const;
    [[nodiscard]] const AllowlistEntry& venue(std::string_view address) const;
    [[nodiscard]] const AllowlistEntry& token(std::string_view address) const;
    [[nodiscard]] const std::string& revision() const noexcept;

private:
    std::string revision_;
    std::map<std::string, AllowlistEntry> venues_;
    std::map<std::string, AllowlistEntry> tokens_;
};

struct TokenDelta {
    std::string token;
    std::string raw_amount;
};

struct ConfirmedAction {
    std::uint64_t chain_id{0};
    std::uint64_t block_number{0};
    std::string block_hash;
    std::int64_t block_timestamp{0};
    std::uint64_t observed_head{0};
    std::string transaction_hash;
    std::uint64_t transaction_index{0};
    std::string actor;
    std::string executor;
    std::vector<std::string> venues;
    std::vector<TokenDelta> token_deltas;
    std::vector<std::uint64_t> venue_log_indices;
    std::vector<std::uint64_t> transfer_log_indices;
    bool receipt_success{false};
    bool costs_accounted{false};
    std::string allowlist_revision;
    unsigned int confidence_bps{0};
};

struct ObservationPolicy {
    std::uint64_t minimum_confirmations{128};
};

ConfirmedAction parse_confirmed_action(
    const Json& value,
    const VerifiedAllowlist& allowlist,
    const ObservationPolicy& policy = {});
Json confirmed_action_to_json(const ConfirmedAction& action);

class ActionRegistry {
public:
    explicit ActionRegistry(std::filesystem::path directory);
    void initialize();
    bool append(const ConfirmedAction& action);
    [[nodiscard]] std::vector<ConfirmedAction> load() const;

private:
    std::filesystem::path directory_;
};

Json build_rankings(
    const std::vector<ConfirmedAction>& actions,
    const VerifiedAllowlist& allowlist,
    std::int64_t as_of_epoch_seconds,
    unsigned int window_days = 7);
std::string rankings_to_csv(const Json& rankings);
Json build_tuning_export(
    const std::vector<ConfirmedAction>& actions,
    const VerifiedAllowlist& allowlist,
    std::int64_t as_of_epoch_seconds,
    unsigned int window_days = 7);

}  // namespace godbrain::polygon::observer
