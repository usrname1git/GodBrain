#include "godbrain/polygon_observer.hpp"

#include <chrono>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

using namespace godbrain::polygon::observer;

namespace {

int failures = 0;
constexpr std::int64_t fixture_now = 1'786'593'600;
const std::string venue_a = "0x1111111111111111111111111111111111111111";
const std::string venue_b = "0x2222222222222222222222222222222222222222";
const std::string token_a = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const std::string token_b = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const std::string actor_a = "0xcccccccccccccccccccccccccccccccccccccccc";
const std::string actor_b = "0xdddddddddddddddddddddddddddddddddddddddd";
const std::string revision(64, 'a');

#define CHECK(expression) \
    do { \
        if (!(expression)) { \
            throw std::runtime_error( \
                std::string("CHECK failed at line ") + std::to_string(__LINE__) + \
                ": " #expression); \
        } \
    } while (false)

template <typename Function>
void expect_throw(Function&& function) {
    bool threw = false;
    try {
        function();
    } catch (const std::exception&) {
        threw = true;
    }
    CHECK(threw);
}

void run(const char* name, const std::function<void()>& test) {
    try {
        test();
        std::cout << "[PASS] " << name << '\n';
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "[FAIL] " << name << ": " << error.what() << '\n';
    }
}

class FixedClock final : public Clock {
public:
    std::chrono::system_clock::time_point now() const override {
        return std::chrono::system_clock::time_point(
            std::chrono::seconds(fixture_now));
    }
};

class FakeTransport final : public RpcTransport {
public:
    std::map<std::string, Json> results;
    std::vector<HttpResponse> raw;
    std::set<std::string> timeout;
    std::vector<Json> requests;
    std::chrono::milliseconds latency{12};
    HttpResponse heimdall_response{
        .status = 200,
        .body = R"({"jsonrpc":"2.0","result":{"sync_info":{"catching_up":false}}})",
        .latency = std::chrono::milliseconds(8),
    };

    HttpResponse post(
        const Endpoint& endpoint,
        std::string_view body,
        const TransportLimits&) override {
        CHECK(endpoint.host == "127.0.0.1");
        const Json request = Json::parse(body);
        requests.push_back(request);
        const std::string method = request.at("method").get<std::string>();
        if (timeout.contains(method)) {
            throw TransportError("fixture timeout");
        }

        if (!raw.empty()) {
            HttpResponse response = std::move(raw.front());
            raw.erase(raw.begin());
            return response;
        }
        return {
            .status = 200,
            .body = Json{
                {"jsonrpc", "2.0"},
                {"id", request.at("id")},
                {"result", results.at(method)},
            }.dump(),
            .latency = latency,
        };
    }

    HttpResponse get(
        const Endpoint& endpoint,
        const TransportLimits&) override {
        CHECK(endpoint.host == "127.0.0.1");
        CHECK(endpoint.path == "/status");
        return heimdall_response;
    }
};

FakeTransport healthy_transport() {
    FakeTransport transport;
    transport.results = {
        {"web3_clientVersion", "bor/v2.10.0/windows-amd64/go1.26"},
        {"eth_chainId", "0x89"},
        {"eth_blockNumber", "0x64"},
        {"eth_syncing", false},
        {"net_peerCount", "0x3"},
        {"eth_getBlockByNumber",
         Json{
             {"number", "0x64"},
             {"hash", "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
             {"timestamp", "0x6a7d4136"},
         }},
        {"eth_getCode", "0x6000"},
        {"eth_call", "0x"},
        {"eth_getTransactionReceipt", Json::object()},
    };
    return transport;
}

Endpoint local_endpoint() {
    return parse_local_endpoint("http://127.0.0.1:8545/");
}

bool has_reason(const HealthSnapshot& health, std::string_view reason) {
    return std::find(
               health.readiness_reasons.begin(),
               health.readiness_reasons.end(),
               reason) != health.readiness_reasons.end();
}

HealthSnapshot inspect(FakeTransport& transport) {
    RpcClient client(transport, local_endpoint());
    HeimdallStatusClient heimdall(
        transport, parse_local_endpoint("http://127.0.0.1:26657/status"));
    FixedClock clock;
    HealthObserver observer(client, heimdall, clock);
    return observer.inspect();
}

Json allowlist_json() {
    const auto venue = [](const std::string& address, std::string label, char digest) {
        return Json{
            {"address", address},
            {"label", std::move(label)},
            {"source_url", "https://fixtures.invalid/venues.json"},
            {"source_sha256", std::string(64, digest)},
        };
    };
    const auto token = [](const std::string& address, std::string label, char digest) {
        return Json{
            {"address", address},
            {"label", std::move(label)},
            {"source_url", "https://fixtures.invalid/tokens.json"},
            {"source_sha256", std::string(64, digest)},
            {"decimals", 18},
        };
    };
    return {
        {"schema_version", 1},
        {"chain_id", 137},
        {"revision", revision},
        {"venues", Json::array({
             venue(venue_a, "Fixture Venue A", 'b'),
             venue(venue_b, "Fixture Venue B", 'c'),
         })},
        {"tokens", Json::array({
             token(token_a, "TKA", 'd'),
             token(token_b, "TKB", 'e'),
         })},
    };
}

Json action_json(
    std::string tx_hash =
        "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    std::string actor = actor_a,
    std::int64_t timestamp = fixture_now - 60,
    std::string amount_a = "100",
    std::string amount_b = "0") {
    return {
        {"schema_version", 1},
        {"chain_id", 137},
        {"block_number", 1'000},
        {"block_hash",
         "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"},
        {"block_timestamp", timestamp},
        {"observed_head", 1'255},
        {"transaction_hash", std::move(tx_hash)},
        {"transaction_index", 7},
        {"actor", actor},
        {"executor", actor},
        {"venues", Json::array({venue_a, venue_b})},
        {"token_deltas", Json{{token_a, amount_a}, {token_b, amount_b}}},
        {"venue_log_indices", Json::array({3, 8})},
        {"transfer_log_indices", Json::array({2, 4, 7, 9})},
        {"receipt_success", true},
        {"costs_accounted", true},
        {"allowlist_revision", revision},
    };
}

Json operator_config_json() {
    return {
        {"bor_executable", "C:\\Polygon_Bor\\build\\bin\\bor.exe"},
        {"bor_data_directory", "D:\\PolygonData\\Bor"},
        {"heimdall_executable", "C:\\Polygon_Heimdall_v2\\build\\heimdalld.exe"},
        {"heimdall_home_directory", "D:\\PolygonData\\Heimdall"},
        {"heimdall_rest_endpoint", "http://127.0.0.1:1317/"},
        {"heimdall_comet_endpoint", "http://127.0.0.1:26657/"},
        {"ethereum_l1_endpoint", "http://127.0.0.1:9545/"},
        {"bor_http_port", 8545},
        {"bor_http_path", "/"},
        {"bor_http_api", Json::array({"eth", "net", "web3", "bor"})},
        {"minimum_free_space_gib", 8'192},
    };
}

Json load_fixture(const std::string& name) {
    const auto path =
        std::filesystem::path(__FILE__).parent_path() / "fixtures" / name;
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open fixture");
    }
    return Json::parse(input);
}

template <typename T>
concept AcceptsStringMethod = requires(T& value) {
    value.call("eth_sendRawTransaction", Json::array());
};

static_assert(!AcceptsStringMethod<RpcClient>);

void endpoint_policy() {
    CHECK(parse_local_endpoint("http://127.0.0.1:8545/").port == 8545);
    CHECK(parse_local_endpoint("https://localhost:9545/rpc").secure);
    CHECK(parse_local_endpoint("http://[::1]:8545/").host == "::1");
    for (const std::string invalid : {
             "http://192.168.1.5:8545/",
             "http://example.com:8545/",
             "ftp://127.0.0.1:8545/",
             "http://user@127.0.0.1:8545/",
             "http://127.0.0.1:8545/#x",
             "http://127.0.0.1:8545/%2e",
             "http://127.0.0.1/",
             "http://127.0.0.1:8545",
         }) {
        expect_throw([&] { (void)parse_local_endpoint(invalid); });
    }
}

void rpc_protocol_is_bounded() {
    FakeTransport transport = healthy_transport();
    RpcClient client(transport, local_endpoint());
    CHECK(client.call(RpcMethod::eth_chain_id) == "0x89");

    transport.raw.push_back({.status = 302, .body = "", .latency = {}});
    expect_throw([&] { (void)client.call(RpcMethod::eth_chain_id); });
    transport.raw.push_back({.status = 200, .body = "{", .latency = {}});
    expect_throw([&] { (void)client.call(RpcMethod::eth_chain_id); });
    transport.raw.push_back({
        .status = 200,
        .body = R"({"jsonrpc":"2.0","id":999,"result":"0x89"})",
        .latency = {},
    });
    expect_throw([&] { (void)client.call(RpcMethod::eth_chain_id); });

    TransportLimits limits;
    limits.maximum_response_bytes = 16;
    RpcClient bounded(transport, local_endpoint(), limits);
    transport.raw.push_back({
        .status = 200,
        .body = std::string(17, 'x'),
        .latency = {},
    });
    expect_throw([&] { (void)bounded.call(RpcMethod::eth_chain_id); });
}

void rpc_surface_is_confirmed_read_only() {
    const auto& methods = read_only_rpc_method_names();
    CHECK(methods.size() == 9);
    CHECK(methods.contains("eth_call"));
    CHECK(methods.contains("eth_getCode"));
    CHECK(methods.contains("eth_getTransactionReceipt"));
    for (const auto& method : methods) {
        CHECK(method.find("txpool") == std::string::npos);
        CHECK(method.find("pending") == std::string::npos);
        CHECK(method.find("send") == std::string::npos);
        CHECK(method.find("sign") == std::string::npos);
        CHECK(method.find("personal") == std::string::npos);
        CHECK(method.find("wallet") == std::string::npos);
        CHECK(method.find("unlock") == std::string::npos);
    }
    FakeTransport transport = healthy_transport();
    RpcClient client(transport, local_endpoint());
    expect_throw([&] {
        (void)client.call(static_cast<RpcMethod>(999), Json::array());
    });
    CHECK(transport.requests.empty());
}

void rpc_parameters_are_method_specific() {
    const std::string address = "0x1111111111111111111111111111111111111111";
    const std::string block_tag = canonical_block_number_tag(16);
    CHECK(block_tag == "0x10");
    CHECK(build_get_block_params(16) == Json::array({"0x10", false}));
    CHECK(
        build_get_code_params(address, block_tag) ==
        Json::array({address, block_tag}));
    CHECK(
        build_eth_call_params(address, "0xd06ca61f", block_tag) ==
        Json::array({
            Json{{"to", address}, {"data", "0xd06ca61f"}},
            block_tag,
        }));

    FakeTransport transport = healthy_transport();
    RpcClient client(transport, local_endpoint());
    CHECK(
        client.call(
            RpcMethod::eth_get_code,
            build_get_code_params(address, block_tag)) == "0x6000");
    CHECK(
        client.call(
            RpcMethod::eth_call,
            build_eth_call_params(address, "0xd06ca61f", block_tag)) == "0x");

    expect_throw([&] {
        (void)client.call(
            RpcMethod::eth_call,
            Json::array({
                Json{{"to", address}, {"data", "0x"}, {"gas", "0x1"}},
                block_tag,
            }));
    });
    expect_throw([&] {
        (void)client.call(
            RpcMethod::eth_call,
            Json::array({
                Json{{"to", address}, {"data", "0x"}},
                "pending",
            }));
    });
    expect_throw([&] {
        (void)client.call(
            RpcMethod::eth_call,
            Json::array({
                Json{{"to", address}, {"data", "0x"}},
                "latest",
            }));
    });
    expect_throw([&] {
        (void)client.call(
            RpcMethod::eth_call,
            Json::array({
                Json{{"to", address}, {"data", "0x"}},
                block_tag,
                Json::object(),
            }));
    });
    expect_throw([&] {
        (void)build_get_code_params(
            "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", block_tag);
    });
    expect_throw([&] {
        (void)build_eth_call_params(address, "0x0", block_tag);
    });
    expect_throw([&] {
        (void)build_eth_call_params(
            address, "0x" + std::string(4 * 1024 * 2 + 2, '0'), block_tag);
    });
    CHECK(transport.requests.size() == 2);
}

void health_fails_closed() {
    FakeTransport transport = healthy_transport();
    const HealthSnapshot healthy = inspect(transport);
    CHECK(healthy.ready);
    CHECK(healthy.chain_id == 137);
    CHECK(transport.requests.at(5)["params"] == Json::array({"latest", false}));
    CHECK(health_to_json(healthy)["observation_mode"] == "confirmed_blocks_only");
    CHECK(healthy.heimdall_reachable);
    CHECK(healthy.heimdall_synced);

    transport = healthy_transport();
    transport.results["eth_chainId"] = "0x1";
    CHECK(has_reason(inspect(transport), "wrong_chain"));

    transport = healthy_transport();
    transport.results["web3_clientVersion"] = "bor/v2.9.0/windows-amd64";
    CHECK(has_reason(inspect(transport), "unsupported_client"));

    transport = healthy_transport();
    transport.results["eth_syncing"] =
        Json{{"currentBlock", "0x50"}, {"highestBlock", "0x64"}};
    CHECK(has_reason(inspect(transport), "node_syncing"));

    transport = healthy_transport();
    transport.results["net_peerCount"] = "0x0";
    CHECK(has_reason(inspect(transport), "no_peers"));

    transport = healthy_transport();
    transport.results["eth_getBlockByNumber"]["timestamp"] = "0x6a7d4014";
    CHECK(has_reason(inspect(transport), "latest_block_stale"));

    transport = healthy_transport();
    transport.timeout.insert("web3_clientVersion");
    const HealthSnapshot unavailable = inspect(transport);
    CHECK(!unavailable.reachable);
    CHECK(has_reason(unavailable, "rpc_observation_failed"));

    transport = healthy_transport();
    transport.heimdall_response.body =
        R"({"jsonrpc":"2.0","result":{"sync_info":{"catching_up":true}}})";
    CHECK(has_reason(inspect(transport), "heimdall_syncing"));

    transport = healthy_transport();
    transport.heimdall_response.status = 503;
    CHECK(has_reason(inspect(transport), "heimdall_status_failed"));
}

void allowlist_is_external_and_strict() {
    const VerifiedAllowlist allowlist =
        VerifiedAllowlist::from_json(allowlist_json());
    CHECK(allowlist.has_venue(venue_a));
    CHECK(allowlist.has_token(token_b));
    CHECK(allowlist.revision() == revision);

    Json wrong_chain = allowlist_json();
    wrong_chain["chain_id"] = 1;
    expect_throw([&] { (void)VerifiedAllowlist::from_json(wrong_chain); });

    Json insecure_source = allowlist_json();
    insecure_source["venues"][0]["source_url"] = "http://fixtures.invalid";
    expect_throw([&] { (void)VerifiedAllowlist::from_json(insecure_source); });

    Json duplicate = allowlist_json();
    duplicate["venues"][1]["address"] = venue_a;
    expect_throw([&] { (void)VerifiedAllowlist::from_json(duplicate); });
}

void fixture_evidence_parses() {
    const VerifiedAllowlist allowlist =
        VerifiedAllowlist::from_json(load_fixture("verified_allowlist.json"));
    const Json actions = load_fixture("confirmed_actions.json");
    CHECK(actions.is_array());
    CHECK(actions.size() == 1);
    const ConfirmedAction action =
        parse_confirmed_action(actions.at(0), allowlist);
    CHECK(action.transaction_index == 7);
    CHECK(action.confidence_bps == 9'000);
}

void confirmed_action_validation() {
    const VerifiedAllowlist allowlist =
        VerifiedAllowlist::from_json(allowlist_json());
    const ConfirmedAction action =
        parse_confirmed_action(action_json(), allowlist);
    CHECK(action.chain_id == 137);
    CHECK(action.confidence_bps == 9'000);
    CHECK(action.venues.size() == 2);
    CHECK(action.token_deltas.size() == 2);

    Json wrong_chain = action_json();
    wrong_chain["chain_id"] = 1;
    expect_throw([&] { (void)parse_confirmed_action(wrong_chain, allowlist); });

    Json shallow = action_json();
    shallow["observed_head"] = 1'001;
    expect_throw([&] { (void)parse_confirmed_action(shallow, allowlist); });

    Json unverified = action_json();
    unverified["venues"][0] = "0x9999999999999999999999999999999999999999";
    expect_throw([&] { (void)parse_confirmed_action(unverified, allowlist); });

    Json failed = action_json();
    failed["receipt_success"] = false;
    expect_throw([&] { (void)parse_confirmed_action(failed, allowlist); });

    Json costs = action_json();
    costs["costs_accounted"] = false;
    expect_throw([&] { (void)parse_confirmed_action(costs, allowlist); });

    Json no_profit = action_json();
    no_profit["token_deltas"][token_a] = "-1";
    no_profit["token_deltas"][token_b] = "0";
    expect_throw([&] { (void)parse_confirmed_action(no_profit, allowlist); });

    Json oversized = action_json();
    oversized["token_deltas"][token_a] =
        "115792089237316195423570985008687907853269984665640564039457584007913129639936";
    expect_throw([&] { (void)parse_confirmed_action(oversized, allowlist); });
}

void registry_is_append_only_and_restart_safe() {
    const VerifiedAllowlist allowlist =
        VerifiedAllowlist::from_json(allowlist_json());
    const ConfirmedAction action =
        parse_confirmed_action(action_json(), allowlist);
    const auto directory = std::filesystem::temp_directory_path() /
        "godbrain-polygon-observer-registry-test";
    std::error_code ignored;
    std::filesystem::remove_all(directory, ignored);

    ActionRegistry registry(directory);
    registry.initialize();
    CHECK(registry.append(action));
    CHECK(!registry.append(action));
    CHECK(registry.load().size() == 1);

    ConfirmedAction conflict = action;
    conflict.block_hash =
        "0xabababababababababababababababababababababababababababababababab";
    expect_throw([&] { (void)registry.append(conflict); });

    const auto concurrent_directory = std::filesystem::temp_directory_path() /
        "godbrain-polygon-observer-concurrent-registry-test";
    std::filesystem::remove_all(concurrent_directory, ignored);
    ActionRegistry concurrent(concurrent_directory);
    concurrent.initialize();
    std::atomic<int> ready{0};
    std::atomic<bool> start{false};
    std::atomic<int> inserted{0};
    std::atomic<int> rejected{0};
    const auto append = [&](const ConfirmedAction& candidate) {
        ++ready;
        while (!start.load()) {
            std::this_thread::yield();
        }
        try {
            if (concurrent.append(candidate)) {
                ++inserted;
            }
        } catch (const ObserverError&) {
            ++rejected;
        }
    };
    std::thread first(append, std::cref(action));
    std::thread second(append, std::cref(conflict));
    while (ready.load() != 2) {
        std::this_thread::yield();
    }
    start = true;
    first.join();
    second.join();
    CHECK(inserted.load() == 1);
    CHECK(rejected.load() == 1);
    CHECK(concurrent.load().size() == 1);

    const auto record = directory /
        (action.transaction_hash.substr(2) + ".json");
    {
        std::ofstream corrupt(record, std::ios::binary | std::ios::trunc);
        corrupt << "{}";
    }
    expect_throw([&] { (void)registry.load(); });
    std::filesystem::remove_all(directory, ignored);
    std::filesystem::remove_all(concurrent_directory, ignored);
}

void rankings_and_tuning_are_deterministic() {
    const VerifiedAllowlist allowlist =
        VerifiedAllowlist::from_json(allowlist_json());
    std::vector<ConfirmedAction> actions;
    actions.push_back(parse_confirmed_action(
        action_json(
            "0x0101010101010101010101010101010101010101010101010101010101010101",
            actor_a,
            fixture_now - 100,
            "100000000000000000000000000000000000000",
            "-5"),
        allowlist));
    actions.push_back(parse_confirmed_action(
        action_json(
            "0x0202020202020202020202020202020202020202020202020202020202020202",
            actor_a,
            fixture_now - 90,
            "50",
            "1"),
        allowlist));
    actions.push_back(parse_confirmed_action(
        action_json(
            "0x0303030303030303030303030303030303030303030303030303030303030303",
            actor_b,
            fixture_now - 80,
            "200000000000000000000000000000000000000",
            "2"),
        allowlist));
    actions.push_back(parse_confirmed_action(
        action_json(
            "0x0404040404040404040404040404040404040404040404040404040404040404",
            actor_b,
            fixture_now - 8 * 86'400,
            "999999999999999999999999999999999999999",
            "9"),
        allowlist));

    const Json first = build_rankings(actions, allowlist, fixture_now, 7);
    const Json second = build_rankings(actions, allowlist, fixture_now, 7);
    CHECK(first == second);
    CHECK(first["entries"].size() == 4);
    CHECK(first["entries"][0]["actor"] == actor_b);
    CHECK(first["entries"][0]["realized_pnl_raw"] ==
        "200000000000000000000000000000000000000");
    CHECK(first["entries"][1]["realized_pnl_raw"] ==
        "100000000000000000000000000000000000050");

    const std::string csv = rankings_to_csv(first);
    CHECK(csv.starts_with("rank_within_token,actor,token"));
    CHECK(csv.find("999999999") == std::string::npos);

    const Json tuning = build_tuning_export(actions, allowlist, fixture_now, 7);
    CHECK(tuning["confirmed_only"] == true);
    CHECK(tuning["entries"].size() == 2);
    CHECK(tuning["entries"][0]["action_count"] == 3);
}

void operator_render_is_bor_and_heimdall_only() {
    const OperatorConfig config =
        OperatorConfig::from_json(operator_config_json());
    const RenderedOperatorConfig rendered = render_operator_config(config);
    CHECK(rendered.manifest["required_chain_id"] == 137);
    CHECK(rendered.manifest["heimdall_v2"]["role"] == "consensus_only");
    CHECK(rendered.bor_arguments.at(0) == "server");
    CHECK(rendered.bor_arguments.at(1) == "--chain=mainnet");
    CHECK(rendered.bor_powershell_preview.find("--http.addr=127.0.0.1") !=
        std::string::npos);
    CHECK(rendered.heimdall_arguments == std::vector<std::string>({
        "start", "--home=D:\\PolygonData\\Heimdall"}));

    Json remote = operator_config_json();
    remote["ethereum_l1_endpoint"] = "https://mainnet.example/rpc";
    expect_throw([&] { (void)OperatorConfig::from_json(remote); });

    Json pending = operator_config_json();
    pending["bor_http_api"].push_back("txpool");
    expect_throw([&] { (void)OperatorConfig::from_json(pending); });
}

}  // namespace

int main() {
    run("endpoint policy", endpoint_policy);
    run("RPC protocol is bounded", rpc_protocol_is_bounded);
    run("RPC surface is confirmed read-only", rpc_surface_is_confirmed_read_only);
    run("RPC parameters are method specific", rpc_parameters_are_method_specific);
    run("health fails closed", health_fails_closed);
    run("allowlist is external and strict", allowlist_is_external_and_strict);
    run("fixture evidence parses", fixture_evidence_parses);
    run("confirmed action validation", confirmed_action_validation);
    run("registry is append-only and restart safe", registry_is_append_only_and_restart_safe);
    run("rankings and tuning are deterministic", rankings_and_tuning_are_deterministic);
    run("operator render is Bor and Heimdall only", operator_render_is_bor_and_heimdall_only);
    return failures == 0 ? 0 : 1;
}
