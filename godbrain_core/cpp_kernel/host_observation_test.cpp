#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "host_observation.h"

#include <iostream>
#include <vector>

using godbrain_host::json;

static void check(bool ok, const char* why) {
    if (!ok) throw std::runtime_error(why);
}

template<class Call>
static void rejects(Call call) {
    try { call(); }
    catch (const std::exception&) { return; }
    throw std::runtime_error("Expected host observation failure");
}

static json inventory() {
    return {
        {"computer_name", "FIXTURE"}, {"edition_id", "IoTEnterpriseS"},
        {"product_name", "Windows fixture"}, {"display_version", "fixture"},
        {"current_build", "26100"}, {"ubr", 8037}, {"os_pin", "IoTEnterpriseS/26100.8037"},
        {"total_physical_ram_gb", 64}, {"logical_processors", 24},
        {"volumes", json::array({{
            {"letter", "C:"}, {"type", "fixed"}, {"label", "fixture"}, {"total_gb", 100}
        }})},
    };
}

struct Store {
    std::vector<std::string> calls;
    std::string previous;
    std::string current;
    std::string reason;
    json payload;
    int reconciliations = 0;
    bool fail_reconcile = false;
    bool fail_save = false;
    bool fail_judge = false;
    bool fail_checkpoint = false;
    bool missing_id = false;

    json observe(const json& host = inventory()) {
        return godbrain_host::observe(host, json{{"cpu_percent", 1}}, previous,
            [&](const json& input) {
                calls.push_back("save");
                if (fail_save) throw std::runtime_error("fixture save failed");
                payload = input;
                return missing_id ? json::object() : json{{"stable_id", "fixture-host-id"}};
            },
            [&](const json& input) {
                calls.push_back("judge");
                if (fail_judge) throw std::runtime_error("fixture judgment failed");
                check(input.at("id") == "fixture-host-id" && input.at("status") == "verified",
                    "Inventory did not use the existing judgment path");
                return json{{"status", "success"}};
            },
            [&](const std::string& pin, const std::string& why) {
                calls.push_back("reconcile");
                ++reconciliations;
                current = pin;
                reason = why;
                if (fail_reconcile) throw std::runtime_error("fixture sweep failed");
                return json{{"stale", 501}};
            },
            [&](const std::string& pin) {
                calls.push_back("checkpoint");
                if (fail_checkpoint) throw std::runtime_error("fixture checkpoint failed");
                previous = pin;
            });
    }
};

int main() {
    try {
        check(godbrain_host::make_windows_pin("IoTEnterpriseS", "26100", 0) ==
            "IoTEnterpriseS/26100.0", "A successfully read zero UBR must remain valid");
        check(godbrain_host::make_windows_pin("Core", "26100", UINT32_MAX) ==
            "Core/26100.4294967295", "A DWORD UBR was narrowed");
        for (const auto* edition : {"", "unknown", "UNKNOWN", "-", "Core/extra", "Core edition"}) {
            rejects([&] { godbrain_host::make_windows_pin(edition, "26100", 1); });
        }
        for (const auto* build : {"", "0", "00001", "-1", "+1", "26100.1", "26100x", "4294967296"}) {
            rejects([&] { godbrain_host::make_windows_pin("Core", build, 1); });
        }
        rejects([] { godbrain_host::make_windows_pin("Core", "26100", std::nullopt); });
        rejects([] { godbrain_host::make_windows_pin(std::string(81, 'A'), "26100", 1); });
        for (const auto& revision : {json(-1), json(1.5), json("8037"), json(true), json(4294967296ULL)}) {
            Store store;
            auto invalid = inventory();
            invalid["ubr"] = revision;
            rejects([&] { store.observe(invalid); });
            check(store.calls.empty(), "Invalid revision caused a store side effect");
        }
        for (const auto* pin : {"", "unknown/0.0", "IoTEnterpriseS/26100.80370"}) {
            Store store;
            auto invalid = inventory();
            invalid["os_pin"] = pin;
            rejects([&] { store.observe(invalid); });
            check(store.calls.empty(), "An unconfirmed pin caused a store side effect");
        }
        for (const auto* field : {"ubr", "edition_id", "current_build", "os_pin"}) {
            Store store;
            auto invalid = inventory();
            invalid.erase(field);
            rejects([&] { store.observe(invalid); });
            check(store.calls.empty(), "Missing pin field caused a store side effect");
        }
        const std::vector<std::string> success = {"reconcile", "save", "judge", "checkpoint"};
        for (const auto* previous : {"", "IoTEnterpriseS/26100.8037", "Core/26100.7", "malformed checkpoint"}) {
            Store store;
            store.previous = previous;
            const auto result = store.observe();
            check(store.calls == success, "Checkpoint skipped or reordered reconciliation");
            check(store.current == "IoTEnterpriseS/26100.8037" &&
                store.previous == store.current, "Checkpoint did not follow the current sensor");
            check(result.at("trust") == "verified" && result.at("stale").at("stale") == 501,
                "Maintenance or judgment receipt was lost");
            check(result.at("inventory") == inventory() && result.at("live").at("cpu_percent") == 1,
                "Observation response changed");
            check(store.payload.at("sector") == "windows-sre" &&
                store.payload.at("content") ==
                    "Windows host inventory\nclaim_class=host_fact\nos_pin=IoTEnterpriseS/26100.8037\n"
                    "computer_name=FIXTURE\nedition_id=IoTEnterpriseS\nproduct_name=Windows fixture\n"
                    "display_version=fixture\ncurrent_build=26100\nubr=8037\n"
                    "total_physical_ram_gb=64\nlogical_processors=24\n"
                    "volume=C: type=fixed label=fixture total_gb=100\n",
                "Immutable inventory content changed");
            store.calls.clear();
            const auto repeated = store.observe();
            check(store.calls == success && store.reconciliations == 2 &&
                repeated.at("stale").at("stale") == 501,
                "An unchanged pin skipped newly arrived mismatches or projection repair");
            check(store.reason.find("recheck") != std::string::npos, "Unchanged pin reported a build change");
        }
        {
            Store store;
            store.previous = "Core/26100.7";
            store.fail_reconcile = true;
            rejects([&] { store.observe(); });
            check(store.calls == std::vector<std::string>{"reconcile"} &&
                store.previous == "Core/26100.7", "Failed sweep advanced inventory or checkpoint");
            store.fail_reconcile = false;
            store.calls.clear();
            store.observe();
            check(store.reconciliations == 2 && store.calls == success, "Failed sweep was not retried");
        }
        {
            Store store;
            store.fail_save = true;
            rejects([&] { store.observe(); });
            check(store.calls == std::vector<std::string>{"reconcile", "save"} &&
                store.previous.empty(), "Failed save advanced the checkpoint");
            store.fail_save = false;
            store.calls.clear();
            store.observe();
            check(store.reconciliations == 2 && store.calls == success, "Failed save suppressed retry");
        }
        {
            Store store;
            store.missing_id = true;
            rejects([&] { store.observe(); });
            check(store.calls == std::vector<std::string>{"reconcile", "save"} &&
                store.previous.empty(), "Missing origin was judged or checkpointed");
        }
        {
            Store store;
            store.fail_judge = true;
            const auto result = store.observe();
            check(result.at("trust") == "candidate" &&
                result.at("judgment_error") == "fixture judgment failed",
                "Failed judgment was hidden or promoted");
        }
        {
            Store store;
            store.fail_checkpoint = true;
            rejects([&] { store.observe(); });
            check(store.previous.empty(), "Failed checkpoint was reported as written");
            store.fail_checkpoint = false;
            store.calls.clear();
            store.observe();
            check(store.reconciliations == 2 && store.calls == success,
                "Checkpoint failure suppressed the next reconciliation");
        }
        std::cout << "PASS: strict host pins, independent reconciliation, unchanged inventory, failures and retries\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
