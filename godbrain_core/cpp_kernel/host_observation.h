#pragma once

#include "json.hpp"

#include <charconv>
#include <cstdint>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>

namespace godbrain_host {
using json = nlohmann::json;

inline std::string make_windows_pin(
    const std::string& edition,
    const std::string& build,
    const std::optional<std::uint32_t>& ubr) {
    std::string lower_edition = edition;
    bool has_alnum = false;
    for (char& ch : lower_edition) {
        const bool alnum = (ch >= 'a' && ch <= 'z') ||
            (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9');
        if (!alnum && ch != '_' && ch != '-') {
            throw std::runtime_error("Windows EditionID is malformed");
        }
        has_alnum = has_alnum || alnum;
        if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch + ('a' - 'A'));
    }
    if (!has_alnum || lower_edition == "unknown") {
        throw std::runtime_error("Windows EditionID is unavailable");
    }
    std::uint32_t build_number = 0;
    if (build.empty() || build.front() == '0') {
        throw std::runtime_error("Windows CurrentBuild is unavailable");
    }
    const auto parsed = std::from_chars(
        build.data(), build.data() + build.size(), build_number);
    if (parsed.ec != std::errc{} || parsed.ptr != build.data() + build.size() ||
        build_number == 0) {
        throw std::runtime_error("Windows CurrentBuild is malformed");
    }
    if (!ubr) throw std::runtime_error("Windows UBR could not be read");
    const std::string pin = edition + "/" + build + "." + std::to_string(*ubr);
    if (pin.size() > 80) throw std::runtime_error("Windows build pin exceeds limit");
    return pin;
}

inline std::string inventory_pin(const json& inventory) {
    const auto& revision = inventory.at("ubr");
    if (!revision.is_number_integer() ||
        (!revision.is_number_unsigned() && revision.get<std::int64_t>() < 0) ||
        revision.get<std::uint64_t>() > (std::numeric_limits<std::uint32_t>::max)()) {
        throw std::runtime_error("Windows inventory UBR is malformed");
    }
    const std::string pin = make_windows_pin(
        inventory.at("edition_id").get<std::string>(),
        inventory.at("current_build").get<std::string>(),
        revision.get<std::uint32_t>());
    if (inventory.at("os_pin") != pin) {
        throw std::runtime_error("Windows inventory pin does not match its fields");
    }
    return pin;
}

template<class Save, class Judge, class Reconcile, class Checkpoint>
json observe(
    const json& inventory,
    const json& live,
    const std::string& previous,
    Save save,
    Judge judge,
    Reconcile reconcile,
    Checkpoint checkpoint) {
    const std::string pin = inventory_pin(inventory);
    std::ostringstream body;
    body << "Windows host inventory\n"
         << "claim_class=host_fact\n"
         << "os_pin=" << pin << '\n'
         << "computer_name=" << inventory.at("computer_name").get<std::string>() << '\n'
         << "edition_id=" << inventory.at("edition_id").get<std::string>() << '\n'
         << "product_name=" << inventory.value("product_name", "") << '\n'
         << "display_version=" << inventory.value("display_version", "") << '\n'
         << "current_build=" << inventory.at("current_build").get<std::string>() << '\n'
         << "ubr=" << inventory.at("ubr").get<std::uint32_t>() << '\n'
         << "total_physical_ram_gb=" << inventory.at("total_physical_ram_gb").get<int>() << '\n'
         << "logical_processors=" << inventory.at("logical_processors").get<int>() << '\n';
    for (const auto& volume : inventory.value("volumes", json::array())) {
        body << "volume=" << volume.value("letter", "?")
             << " type=" << volume.value("type", "fixed")
             << " label=" << volume.value("label", "")
             << " total_gb=" << volume.value("total_gb", 0) << '\n';
    }
    const std::string reason = previous.empty() ? "initial live host applicability os_pin=" + pin :
        previous == pin ? "recheck live host applicability os_pin=" + pin :
        "os_pin changed " + previous + " -> " + pin;
    // A checkpoint is history, not proof that no mismatched cards have arrived.
    const json stale = reconcile(pin, reason);
    json stored = save(json{{"content", body.str()}, {"sector", "windows-sre"}});
    const std::string stable_id = stored.value("stable_id", "");
    if (stable_id.empty()) throw std::runtime_error("Host observation has no stable ID");
    try {
        stored["judgment"] = judge(json{
            {"id", stable_id}, {"status", "verified"},
            {"reasoning", "live host read os_pin=" + pin},
        });
        stored["trust"] = "verified";
    } catch (const std::exception& error) {
        stored["trust"] = "candidate";
        stored["judgment_error"] = error.what();
    }
    checkpoint(pin);
    stored["inventory"] = inventory;
    stored["live"] = live;
    stored["stale"] = stale;
    return stored;
}
}
