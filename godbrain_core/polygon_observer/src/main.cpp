#include "godbrain/polygon_observer.hpp"

#include <charconv>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <set>
#include <string>
#include <string_view>

namespace {

namespace observer = godbrain::polygon::observer;
using observer::Json;
using observer::ObserverError;
using observer::SanitizedLogger;

constexpr std::size_t maximum_input_bytes = 4 * 1024 * 1024;

struct Options {
    std::string command;
    std::filesystem::path config;
    std::filesystem::path allowlist;
    std::filesystem::path registry;
    std::filesystem::path input;
    std::string endpoint;
    std::string heimdall_status_endpoint;
    std::string format{"json"};
    std::uint64_t minimum_confirmations{128};
    std::int64_t as_of{0};
    unsigned int window_days{7};
    bool json{false};
};

[[noreturn]] void usage_error() {
    throw ObserverError(
        "usage: godbrain-polygon-observer status --endpoint <local-url> "
        "--heimdall-status-endpoint <local-url/status> [--json]; "
        "validate-config|render-config --config <file> [--json]; "
        "validate-allowlist --allowlist <file> [--json]; "
        "ingest --allowlist <file> --registry <dir> --input <file> "
        "[--min-confirmations <n>] [--json]; "
        "rank|tuning --allowlist <file> --registry <dir> --as-of <epoch> "
        "[--window-days <1..30>] [--format json|csv]");
}

std::uint64_t parse_unsigned(std::string_view value, std::string_view name) {
    std::uint64_t parsed = 0;
    const auto [end, error] =
        std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (value.empty() || error != std::errc{} ||
        end != value.data() + value.size()) {
        throw ObserverError(std::string(name) + " must be an unsigned integer");
    }
    return parsed;
}

Options parse_options(int argc, char** argv) {
    if (argc < 2) {
        usage_error();
    }
    Options options;
    options.command = argv[1];
    std::set<std::string> seen;
    for (int index = 2; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (!seen.insert(std::string(argument)).second) {
            usage_error();
        }
        const auto next = [&]() -> std::string {
            if (++index >= argc) {
                usage_error();
            }
            return argv[index];
        };
        if (argument == "--json") {
            if (options.json) {
                usage_error();
            }
            options.json = true;
        } else if (argument == "--config") {
            options.config = next();
        } else if (argument == "--allowlist") {
            options.allowlist = next();
        } else if (argument == "--registry") {
            options.registry = next();
        } else if (argument == "--input") {
            options.input = next();
        } else if (argument == "--endpoint") {
            options.endpoint = next();
        } else if (argument == "--heimdall-status-endpoint") {
            options.heimdall_status_endpoint = next();
        } else if (argument == "--format") {
            options.format = next();
        } else if (argument == "--min-confirmations") {
            options.minimum_confirmations =
                parse_unsigned(next(), "minimum confirmations");
        } else if (argument == "--as-of") {
            const std::uint64_t value = parse_unsigned(next(), "as-of");
            if (value > static_cast<std::uint64_t>(
                    std::numeric_limits<std::int64_t>::max())) {
                throw ObserverError("as-of is out of range");
            }
            options.as_of = static_cast<std::int64_t>(value);
        } else if (argument == "--window-days") {
            const std::uint64_t value = parse_unsigned(next(), "window days");
            if (value > std::numeric_limits<unsigned int>::max()) {
                throw ObserverError("window days is out of range");
            }
            options.window_days = static_cast<unsigned int>(value);
        } else {
            usage_error();
        }
    }
    if (options.minimum_confirmations == 0 ||
        options.window_days == 0 || options.window_days > 30 ||
        (options.format != "json" && options.format != "csv")) {
        usage_error();
    }
    return options;
}

Json load_json(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw ObserverError("cannot open JSON input");
    }
    input.seekg(0, std::ios::end);
    const std::streamoff length = input.tellg();
    if (length < 0 || static_cast<std::uint64_t>(length) > maximum_input_bytes) {
        throw ObserverError("JSON input exceeds size limit");
    }
    input.seekg(0, std::ios::beg);
    std::string contents(static_cast<std::size_t>(length), '\0');
    if (!contents.empty()) {
        input.read(contents.data(), static_cast<std::streamsize>(contents.size()));
        if (!input) {
            throw ObserverError("cannot read JSON input");
        }
    }
    try {
        const auto callback = [](int depth, Json::parse_event_t event, Json&) {
            if ((event == Json::parse_event_t::object_start ||
                 event == Json::parse_event_t::array_start) &&
                depth >= 32) {
                throw ObserverError("JSON input exceeds nesting limit");
            }
            return true;
        };
        return Json::parse(contents, callback);
    } catch (const ObserverError&) {
        throw;
    } catch (const Json::exception&) {
        throw ObserverError("input is not valid JSON");
    }
}

int run_config(const Options& options, const SanitizedLogger& logger) {
    if (options.config.empty()) {
        usage_error();
    }
    const auto config =
        observer::OperatorConfig::from_json(load_json(options.config));
    if (options.command == "validate-config") {
        logger.event("info", "operator_config_valid");
        if (options.json) {
            std::cout << Json{{"valid", true}, {"render_only", true}}.dump(2) << '\n';
        } else {
            std::cout << "Bor + Heimdall v2 configuration is valid (render-only).\n";
        }
        return 0;
    }
    const auto rendered = observer::render_operator_config(config);
    logger.event("info", "operator_config_rendered");
    if (options.json) {
        std::cout << rendered.manifest.dump(2) << '\n';
    } else {
        std::cout << rendered.heimdall_powershell_preview << '\n'
                  << rendered.bor_powershell_preview << '\n';
    }
    return 0;
}

int run_status(const Options& options, const SanitizedLogger& logger) {
    if (options.endpoint.empty() || options.heimdall_status_endpoint.empty()) {
        usage_error();
    }
    const auto endpoint = observer::parse_local_endpoint(options.endpoint);
    const auto heimdall_endpoint =
        observer::parse_local_endpoint(options.heimdall_status_endpoint);
    observer::WinHttpRpcTransport transport;
    observer::RpcClient client(transport, endpoint);
    observer::HeimdallStatusClient heimdall(
        transport, heimdall_endpoint);
    observer::SystemClock clock;
    observer::HealthObserver health_observer(client, heimdall, clock);
    const auto health = health_observer.inspect();
    logger.event(
        health.ready ? "info" : "warning",
        health.ready ? "observer_ready" : "observer_not_ready");
    if (options.json) {
        std::cout << observer::health_to_json(health).dump(2) << '\n';
    } else {
        std::cout << "Bor observer: " << (health.ready ? "READY" : "NOT READY")
                  << "\nEndpoint: " << observer::endpoint_display(endpoint)
                  << "\n";
        for (const auto& reason : health.readiness_reasons) {
            std::cout << "- " << reason << '\n';
        }
    }
    return health.ready ? 0 : 2;
}

observer::VerifiedAllowlist load_allowlist(const Options& options) {
    if (options.allowlist.empty()) {
        usage_error();
    }
    return observer::VerifiedAllowlist::from_json(
        load_json(options.allowlist));
}

int run_ingest(const Options& options, const SanitizedLogger& logger) {
    if (options.registry.empty() || options.input.empty()) {
        usage_error();
    }
    const auto allowlist = load_allowlist(options);
    const Json source = load_json(options.input);
    if (!source.is_array() || source.size() > 10'000) {
        throw ObserverError("ingest input must be a bounded action array");
    }
    observer::ActionRegistry registry(options.registry);
    registry.initialize();
    std::size_t appended = 0;
    std::size_t duplicates = 0;
    const observer::ObservationPolicy policy{
        .minimum_confirmations = options.minimum_confirmations,
    };
    for (const auto& value : source) {
        const auto action =
            observer::parse_confirmed_action(value, allowlist, policy);
        if (registry.append(action)) {
            ++appended;
        } else {
            ++duplicates;
        }
    }
    logger.event("info", "confirmed_actions_ingested");
    const Json result{
        {"appended", appended},
        {"duplicates", duplicates},
        {"confirmed_only", true},
    };
    std::cout << (options.json ? result.dump(2) : result.dump()) << '\n';
    return 0;
}

int run_exports(const Options& options) {
    if (options.registry.empty() || options.as_of <= 0) {
        usage_error();
    }
    const auto allowlist = load_allowlist(options);
    observer::ActionRegistry registry(options.registry);
    const auto actions = registry.load();
    if (options.command == "rank") {
        const Json rankings = observer::build_rankings(
            actions, allowlist, options.as_of, options.window_days);
        if (options.format == "csv") {
            std::cout << observer::rankings_to_csv(rankings);
        } else {
            std::cout << rankings.dump(2) << '\n';
        }
        return 0;
    }
    if (options.format != "json") {
        throw ObserverError("tuning export supports JSON only");
    }
    std::cout << observer::build_tuning_export(
        actions, allowlist, options.as_of, options.window_days).dump(2) << '\n';
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        const SanitizedLogger logger;
        if (options.command == "status") {
            return run_status(options, logger);
        }
        if (options.command == "validate-config" ||
            options.command == "render-config") {
            return run_config(options, logger);
        }
        if (options.command == "validate-allowlist") {
            (void)load_allowlist(options);
            logger.event("info", "allowlist_valid");
            std::cout << Json{{"valid", true}, {"chain_id", 137}}.dump(2) << '\n';
            return 0;
        }
        if (options.command == "ingest") {
            return run_ingest(options, logger);
        }
        if (options.command == "rank" || options.command == "tuning") {
            return run_exports(options);
        }
        usage_error();
    } catch (const std::exception& error) {
        const SanitizedLogger logger;
        logger.event("error", "command_failed", error.what());
        return 1;
    }
}
