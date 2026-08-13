#include "polymarket/paper.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <iostream>
#include <thread>

namespace {

std::atomic_bool stop_requested{false};

void handle_signal(int) {
    stop_requested.store(true);
}

void emit(const std::string& level, const std::string& event, const polymarket::paper::Json& data) {
    std::cout << polymarket::paper::Json{
        {"level", level},
        {"event", event},
        {"data", data},
    }.dump() << '\n';
}

}  // namespace

int main(int argc, char** argv) {
    using namespace polymarket::paper;
    try {
        const std::string command = argc > 1 ? argv[1] : "scan-once";
        Config config = Config::from_environment();
        FileRepository repository(config.state_directory);
        WinHttpPublicTransport transport;
        PublicApi api(transport, config.discovery);
        ConservativeFillModel fill_model;
        SystemClock clock;
        PaperEngine engine(config, api, repository, fill_model, clock);
        engine.initialize();

        if (command == "status") {
            emit("info", "health", health_json(engine.health()));
            return 0;
        }
        if (command == "scan-once") {
            engine.scan_once();
            emit("info", "scan_complete", health_json(engine.health()));
            return 0;
        }
        if (command != "run") {
            throw PaperError("usage: godbrain-polymarket-paper [scan-once|run|status]");
        }

        std::signal(SIGINT, handle_signal);
        std::signal(SIGTERM, handle_signal);
        emit("info", "service_started", health_json(engine.health()));
        while (!stop_requested.load()) {
            const auto started = std::chrono::steady_clock::now();
            try {
                engine.scan_once();
                emit("info", "scan_complete", health_json(engine.health()));
            } catch (const std::exception& error) {
                emit("error", "scan_failed", {
                    {"message", error.what()},
                    {"health", health_json(engine.health())},
                });
            }
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started);
            const auto wait = std::chrono::milliseconds(config.scan_interval_ms) - elapsed;
            if (wait > std::chrono::milliseconds::zero()) {
                std::this_thread::sleep_for(wait);
            }
        }
        emit("info", "service_stopped", health_json(engine.health()));
        return 0;
    } catch (const std::exception& error) {
        emit("fatal", "startup_failed", {{"message", error.what()}});
        return 1;
    }
}
