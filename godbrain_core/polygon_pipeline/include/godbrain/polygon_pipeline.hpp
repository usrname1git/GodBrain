#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "godbrain/polygon_observer.hpp"
#include "polygon_searcher/searcher.hpp"

namespace godbrain::polygon::pipeline {

namespace observer = godbrain::polygon::observer;
namespace searcher = godbrain::polygon::searcher;
using Json = nlohmann::json;

class PipelineError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct EvidenceSource {
    std::string url;
    std::string sha256;
};

struct TokenConfig {
    std::string address;
    std::string symbol;
    std::uint8_t decimals{0};
};

struct VenueConfig {
    std::string address;
    std::string kind;
};

struct RouteConfig {
    std::string id;
    std::string venue;
    std::string token_in;
    std::string token_out;
};

struct CycleConfig {
    std::string id;
    std::string first_route;
    std::string second_route;
};

struct GasConversionConfig {
    std::string wrapped_native;
    std::string input_token;
    std::string route_id;
};

struct PipelineConfig {
    std::uint32_t schema_version{1};
    std::uint64_t chain_id{137};
    std::string evidence_revision;
    EvidenceSource source;
    std::uint64_t confirmation_depth{0};
    std::uint64_t maximum_block_age_seconds{0};
    std::uint64_t maximum_future_seconds{0};
    std::uint64_t maximum_quote_amount{0};
    std::size_t maximum_calldata_bytes{0};
    std::uint64_t gas_units_ceiling{0};
    std::vector<TokenConfig> tokens;
    std::vector<VenueConfig> venues;
    std::vector<RouteConfig> routes;
    std::vector<CycleConfig> cycles;
    GasConversionConfig gas_conversion;

    static PipelineConfig from_json(const Json& value);
    [[nodiscard]] Json to_json() const;
    [[nodiscard]] const TokenConfig& token(std::string_view address) const;
    [[nodiscard]] const VenueConfig& venue(std::string_view address) const;
    [[nodiscard]] const RouteConfig& route(std::string_view id) const;
};

[[nodiscard]] std::string sha256_hex(std::string_view input);
[[nodiscard]] std::string canonical_block_number_tag(std::uint64_t number);
[[nodiscard]] Json build_get_block_params(std::uint64_t number);
[[nodiscard]] Json build_get_code_params(
    std::string_view address, std::string_view block_tag);
[[nodiscard]] Json build_eth_call_params(
    std::string_view to, std::string_view data, std::string_view block_tag);

[[nodiscard]] std::string encode_get_amounts_out(
    std::uint64_t amount_in,
    std::string_view token_in,
    std::string_view token_out,
    std::size_t maximum_calldata_bytes);
[[nodiscard]] std::uint64_t decode_get_amounts_out(
    std::string_view result, std::uint64_t expected_amount_in);

class ReadOnlyRpc {
public:
    virtual ~ReadOnlyRpc() = default;
    [[nodiscard]] virtual Json get_block(std::uint64_t number) = 0;
    [[nodiscard]] virtual std::string get_code(
        std::string_view address, std::uint64_t number) = 0;
    [[nodiscard]] virtual std::string eth_call(
        std::string_view to,
        std::string_view data,
        std::uint64_t number) = 0;
};

class ObserverReadOnlyRpc final : public ReadOnlyRpc {
public:
    ObserverReadOnlyRpc(
        observer::RpcTransport& transport,
        observer::Endpoint endpoint,
        observer::TransportLimits limits = {});

    [[nodiscard]] Json get_block(std::uint64_t number) override;
    [[nodiscard]] std::string get_code(
        std::string_view address, std::uint64_t number) override;
    [[nodiscard]] std::string eth_call(
        std::string_view to,
        std::string_view data,
        std::uint64_t number) override;

private:
    observer::RpcClient client_;
};

class HealthGate {
public:
    virtual ~HealthGate() = default;
    [[nodiscard]] virtual observer::HealthSnapshot inspect() = 0;
};

class ObserverHealthGate final : public HealthGate {
public:
    explicit ObserverHealthGate(observer::HealthObserver& health);
    [[nodiscard]] observer::HealthSnapshot inspect() override;

private:
    observer::HealthObserver& health_;
};

class ConfirmedBlockProvider final : public searcher::BlockProvider {
public:
    ConfirmedBlockProvider(
        HealthGate& health,
        ReadOnlyRpc& rpc,
        const observer::Clock& clock,
        const PipelineConfig& config);

    [[nodiscard]] searcher::BlockContext current() override;
    [[nodiscard]] bool is_canonical(const searcher::BlockContext& block) override;
    [[nodiscard]] std::uint64_t base_fee_per_gas(
        const searcher::BlockContext& block) const;

private:
    HealthGate& health_;
    ReadOnlyRpc& rpc_;
    const observer::Clock& clock_;
    const PipelineConfig& config_;
    mutable std::mutex mutex_;
    std::map<std::string, std::uint64_t> base_fees_;
};

class ConfigTokenMetadataProvider final : public searcher::TokenMetadataProvider {
public:
    explicit ConfigTokenMetadataProvider(const PipelineConfig& config);
    [[nodiscard]] searcher::Token get(std::string_view token_id) override;

private:
    const PipelineConfig& config_;
};

class ObserverClockAdapter final : public searcher::Clock {
public:
    explicit ObserverClockAdapter(const observer::Clock& clock);
    [[nodiscard]] std::int64_t now_epoch_ms() const override;

private:
    const observer::Clock& clock_;
};

class UniswapV2QuoteProvider final : public searcher::ExactInputQuoteProvider {
public:
    UniswapV2QuoteProvider(
        ReadOnlyRpc& rpc,
        searcher::BlockProvider& blocks,
        searcher::Clock& clock,
        const PipelineConfig& config);
    [[nodiscard]] searcher::ExactInputQuote quote(
        const searcher::QuoteRequest& request) override;

private:
    ReadOnlyRpc& rpc_;
    searcher::BlockProvider& blocks_;
    searcher::Clock& clock_;
    const PipelineConfig& config_;
};

class ConservativeGasCostProvider final : public searcher::GasCostProvider {
public:
    ConservativeGasCostProvider(
        ConfirmedBlockProvider& blocks,
        searcher::ExactInputQuoteProvider& quotes,
        searcher::Clock& clock,
        const PipelineConfig& config);
    [[nodiscard]] searcher::GasCostQuote estimate(
        const searcher::CostRequest& request) override;

private:
    ConfirmedBlockProvider& blocks_;
    searcher::ExactInputQuoteProvider& quotes_;
    searcher::Clock& clock_;
    const PipelineConfig& config_;
};

[[nodiscard]] std::uint64_t checked_base_fee_cost(
    std::uint64_t gas_units, std::uint64_t base_fee_per_gas);
class DeterministicPaperExecutor final : public searcher::PaperExecutor {
public:
    explicit DeterministicPaperExecutor(searcher::Clock& clock);
    [[nodiscard]] searcher::PaperResult execute(
        const searcher::ArbitragePlan& plan) override;

private:
    searcher::Clock& clock_;
};

[[nodiscard]] Json atlas_simulation_plan(
    const searcher::ArbitragePlan& plan, std::string_view evidence_revision);

struct ReplayOutput {
    Json json;
    std::string csv;
};

[[nodiscard]] ReplayOutput replay_offline(
    const PipelineConfig& config, const Json& sanitized_fixture);
void write_replay_output(
    const ReplayOutput& output, const std::filesystem::path& output_prefix);

}  // namespace godbrain::polygon::pipeline
