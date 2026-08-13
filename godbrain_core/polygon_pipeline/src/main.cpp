#include "godbrain/polygon_pipeline.hpp"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <set>

namespace pipeline = godbrain::polygon::pipeline;
namespace observer = godbrain::polygon::observer;
namespace searcher = godbrain::polygon::searcher;
using Json = nlohmann::json;

namespace {

Json read_json(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw pipeline::PipelineError("unable to open JSON input");
    }
    Json value;
    input >> value;
    if (!input) {
        throw pipeline::PipelineError("unable to parse JSON input");
    }
    return value;
}

struct LocalState {
    observer::Endpoint rpc;
    observer::Endpoint heimdall;
    std::uint64_t amount_in{0};
    std::filesystem::path audit_directory;
};

std::filesystem::path validated_audit_directory(const Json& value) {
    if (!value.is_string()) {
        throw pipeline::PipelineError("state audit_directory must be a string");
    }
    const std::string text = value.get<std::string>();
    if (text.empty() || text.size() > 1'024U) {
        throw pipeline::PipelineError("state audit_directory is invalid");
    }
    const std::filesystem::path path(text);
    if (!path.is_absolute() || path != path.lexically_normal() ||
        path == path.root_path() || path.filename().empty()) {
        throw pipeline::PipelineError(
            "state audit_directory must be an absolute normalized child path");
    }
    for (const auto& component : path) {
        if (component == "..") {
            throw pipeline::PipelineError("state audit_directory cannot traverse");
        }
    }
    const auto parent = path.parent_path();
    if (!std::filesystem::exists(parent) ||
        !std::filesystem::is_directory(parent) ||
        std::filesystem::is_symlink(parent) ||
        (std::filesystem::exists(path) &&
         (!std::filesystem::is_directory(path) ||
          std::filesystem::is_symlink(path)))) {
        throw pipeline::PipelineError(
            "state audit_directory parent or target is unsafe");
    }
    for (auto ancestor = parent;; ancestor = ancestor.parent_path()) {
        if (std::filesystem::exists(ancestor) &&
            std::filesystem::is_symlink(ancestor)) {
            throw pipeline::PipelineError(
                "state audit_directory cannot cross a symlink");
        }
        const auto next = ancestor.parent_path();
        if (next.empty() || next == ancestor) {
            break;
        }
    }
    return path;
}

LocalState read_state(const std::filesystem::path& path) {
    const Json value = read_json(path);
    static const std::set<std::string> keys{
        "amount_in",
        "audit_directory",
        "heimdall_endpoint",
        "rpc_endpoint",
        "schema_version"};
    if (!value.is_object() || value.size() != keys.size()) {
        throw pipeline::PipelineError("state has missing or unknown fields");
    }
    for (const auto& [key, unused] : value.items()) {
        (void)unused;
        if (!keys.contains(key)) {
            throw pipeline::PipelineError("state has an unknown field");
        }
    }
    if (!value.at("schema_version").is_number_unsigned() ||
        value.at("schema_version").get<std::uint64_t>() != 1U ||
        !value.at("rpc_endpoint").is_string() ||
        !value.at("heimdall_endpoint").is_string() ||
        !value.at("amount_in").is_number_unsigned()) {
        throw pipeline::PipelineError("state fields are invalid");
    }
    const auto amount = value.at("amount_in").get<std::uint64_t>();
    if (amount == 0U) {
        throw pipeline::PipelineError("state amount_in must be positive");
    }
    return {
        .rpc = observer::parse_local_endpoint(
            value.at("rpc_endpoint").get<std::string>()),
        .heimdall = observer::parse_local_endpoint(
            value.at("heimdall_endpoint").get<std::string>()),
        .amount_in = amount,
        .audit_directory = validated_audit_directory(
            value.at("audit_directory")),
    };
}

struct LiveContext {
    observer::WinHttpRpcTransport transport;
    observer::SystemClock clock;
    observer::RpcClient health_rpc;
    observer::HeimdallStatusClient heimdall;
    observer::HealthObserver health;
    pipeline::ObserverHealthGate gate;
    pipeline::ObserverReadOnlyRpc read_only;
    pipeline::ConfirmedBlockProvider blocks;
    pipeline::ObserverClockAdapter search_clock;
    pipeline::UniswapV2QuoteProvider quotes;
    pipeline::ConfigTokenMetadataProvider tokens;
    pipeline::ConservativeGasCostProvider costs;

    LiveContext(const pipeline::PipelineConfig& config, const LocalState& state)
        : health_rpc(transport, state.rpc),
          heimdall(transport, state.heimdall),
          health(
              health_rpc,
              heimdall,
              clock,
              observer::HealthPolicy{
                  .required_chain_id = config.chain_id,
                  .required_client_product = "bor",
                  .accepted_client_versions = {"2.10.0"},
                  .maximum_block_age =
                      std::chrono::seconds(config.maximum_block_age_seconds),
                  .maximum_rpc_latency = std::chrono::milliseconds(5'000),
                  .require_peers = true,
              }),
          gate(health),
          read_only(transport, state.rpc),
          blocks(gate, read_only, clock, config),
          search_clock(clock),
          quotes(read_only, blocks, search_clock, config),
          tokens(config),
          costs(blocks, quotes, search_clock, config) {}
};

std::vector<searcher::Route> reviewed_cycle_routes(
    const pipeline::PipelineConfig& config) {
    std::map<std::string, searcher::Route> unique;
    for (const auto& cycle : config.cycles) {
        for (const auto* route :
             {&config.route(cycle.first_route),
              &config.route(cycle.second_route)}) {
            unique.emplace(
                route->id,
                searcher::Route{
                    .id = route->id,
                    .venue_id = route->venue,
                    .token_in = route->token_in,
                    .token_out = route->token_out,
                });
        }
    }
    std::vector<searcher::Route> routes;
    for (const auto& [unused, route] : unique) {
        (void)unused;
        routes.push_back(route);
    }
    return routes;
}

searcher::SearchConfig search_config(
    const pipeline::PipelineConfig& pipeline_config,
    const std::vector<searcher::Route>& routes,
    std::uint64_t amount_in) {
    searcher::SearchConfig config;
    config.max_routes = routes.size();
    config.max_candidates_per_block =
        std::min<std::size_t>(
            searcher::SearchConfig::hard_max_candidates_per_block,
            routes.size() * routes.size());
    config.max_gas_units = pipeline_config.gas_units_ceiling;
    config.max_quote_age_ms = searcher::SearchConfig::hard_max_quote_age_ms;
    config.max_block_age_ms = searcher::SearchConfig::hard_max_quote_age_ms;
    config.plan_ttl_ms = 1'000;
    for (const auto& route : routes) {
        config.allowed_tokens.insert(route.token_in);
        config.allowed_tokens.insert(route.token_out);
        config.allowed_venues.insert(route.venue_id);
    }
    for (const auto& token_id : config.allowed_tokens) {
        const auto& token = pipeline_config.token(token_id);
        const searcher::Token metadata{
            .id = token.address,
            .symbol = token.symbol,
            .decimals = token.decimals,
        };
        const auto hard_limit = searcher::token_whole_limit(
            metadata, searcher::SearchConfig::hard_max_whole_tokens);
        if (amount_in > hard_limit) {
            throw pipeline::PipelineError(
                "state amount exceeds searcher token notional hard limit");
        }
        config.max_input_by_token[token_id] = amount_in;
        config.daily_loss_limit_by_token[token_id] =
            searcher::token_whole_limit(metadata, 1U);
    }
    return config;
}

void usage() {
    std::cerr
        << "usage:\n"
        << "  godbrain-polygon-pipeline validate-config <config.json>\n"
        << "  godbrain-polygon-pipeline replay <config.json> <fixture.json> "
           "<output-prefix>\n"
        << "  godbrain-polygon-pipeline status <config.json> <state.json>\n"
        << "  godbrain-polygon-pipeline scan-once <config.json> <state.json>\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 3) {
            usage();
            return 2;
        }
        const std::string command = argv[1];
        const auto config =
            pipeline::PipelineConfig::from_json(read_json(argv[2]));
        if (command == "validate-config" && argc == 3) {
            std::cout << Json{
                             {"valid", true},
                             {"chain_id", config.chain_id},
                             {"evidence_revision", config.evidence_revision},
                         }
                              .dump()
                      << '\n';
            return 0;
        }
        if (command == "replay" && argc == 5) {
            const auto output = pipeline::replay_offline(config, read_json(argv[3]));
            pipeline::write_replay_output(output, argv[4]);
            std::cout << Json{
                             {"mode", "offline"},
                             {"replay_sha256", output.json.at("replay_sha256")},
                             {"records", output.json.at("records").size()},
                         }
                              .dump()
                      << '\n';
            return 0;
        }
        if ((command == "status" || command == "scan-once") && argc == 4) {
            const auto state = read_state(argv[3]);
            LiveContext live(config, state);
            if (command == "status") {
                const auto health = live.gate.inspect();
                std::cout << Json{
                                 {"mode", "read_only"},
                                 {"health", observer::health_to_json(health)},
                                 {"evidence_revision", config.evidence_revision},
                             }
                                  .dump()
                          << '\n';
                return health.ready ? 0 : 1;
            }
            if (state.amount_in > config.maximum_quote_amount) {
                throw pipeline::PipelineError(
                    "state amount exceeds maximum_quote_amount");
            }
            const auto routes = reviewed_cycle_routes(config);
            auto risk = search_config(config, routes, state.amount_in);
            std::map<std::string, std::vector<searcher::Amount>> input_sizes;
            for (const auto& token : risk.allowed_tokens) {
                input_sizes[token] = {state.amount_in};
            }
            searcher::FileAuditStore audit(state.audit_directory);
            audit.initialize(live.search_clock.now_epoch_ms());
            pipeline::DeterministicPaperExecutor paper(live.search_clock);
            searcher::Searcher scanner(
                live.blocks,
                live.tokens,
                live.quotes,
                live.costs,
                live.search_clock,
                audit,
                paper,
                std::move(risk));
            const auto result = scanner.scan(routes, std::move(input_sizes));
            Json decisions = Json::array();
            for (const auto& decision : result.decisions) {
                decisions.push_back(searcher::decision_json(decision));
            }
            Json output{
                             {"mode", "paper_read_only"},
                             {"block",
                              {{"number", result.block.number},
                               {"hash", result.block.hash}}},
                             {"decisions", std::move(decisions)},
                             {"selected_paper_plan",
                              result.selected_plan.has_value()
                                  ? searcher::plan_json(*result.selected_plan)
                                  : Json(nullptr)},
                             {"paper_result",
                              result.paper_result.has_value()
                                  ? searcher::paper_result_json(*result.paper_result)
                                  : Json(nullptr)},
                             {"evidence_revision", config.evidence_revision},
                         };
            output["atlas_simulation_plan"] =
                result.selected_plan.has_value()
                ? pipeline::atlas_simulation_plan(
                      *result.selected_plan, config.evidence_revision)
                : Json(nullptr);
            std::cout << output.dump() << '\n';
            return 0;
        }
        usage();
        return 2;
    } catch (const std::exception& error) {
        std::cerr << Json{{"ok", false}, {"error", error.what()}}.dump() << '\n';
        return 1;
    }
}
