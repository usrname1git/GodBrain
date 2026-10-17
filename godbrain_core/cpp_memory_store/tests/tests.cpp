#include "godbrain/memory_store/json.hpp"
#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/snapshot.hpp"
#include "godbrain/memory_store/store.hpp"
#include "../../cpp_kernel/truth_assertion.h"

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::string to_hex(const std::string& bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.resize(bytes.size() * 2);
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        const unsigned char c = static_cast<unsigned char>(bytes[i]);
        out[i * 2] = kHex[c >> 4];
        out[i * 2 + 1] = kHex[c & 0x0f];
    }
    return out;
}

std::string unhex(const std::string& hex) {
    std::string out;
    if (hex.size() % 2 != 0) return out;
    out.reserve(hex.size() / 2);
    auto nybble = [](char h, int* v) {
        if (h >= '0' && h <= '9') *v = h - '0';
        else if (h >= 'a' && h <= 'f') *v = h - 'a' + 10;
        else if (h >= 'A' && h <= 'F') *v = h - 'A' + 10;
        else return false;
        return true;
    };
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        int hi = 0, lo = 0;
        if (!nybble(hex[i], &hi) || !nybble(hex[i + 1], &lo)) return "";
        out.push_back(static_cast<char>((hi << 4) | lo));
    }
    return out;
}

std::vector<std::string> split_tab(const std::string& line) {
    std::vector<std::string> parts;
    std::string cur;
    for (char c : line) {
        if (c == '\t') {
            parts.push_back(cur);
            cur.clear();
        } else if (c != '\r') {
            cur.push_back(c);
        }
    }
    parts.push_back(cur);
    return parts;
}

int run_identity_fixture() {
#ifndef GODBRAIN_IDENTITY_FIXTURE
    std::cerr << "FAIL identity fixture path\n";
    return 1;
#else
    std::ifstream in(GODBRAIN_IDENTITY_FIXTURE);
    if (!in) {
        std::cerr << "FAIL identity fixture open\n";
        return 1;
    }
    int failed = 0;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        const std::vector<std::string> p = split_tab(line);
        if (p.size() < 2) continue;
        if (p[0] == "decode") {
            if (p.size() < 5) {
                std::cerr << "FAIL decode fields " << p[1] << "\n";
                ++failed;
                continue;
            }
            godbrain::memory::Json value;
            std::string err;
            const bool parsed = godbrain::memory::parse_json(p[2], &value, &err);
            if (!parsed || value.kind != godbrain::memory::Json::Kind::String) {
                std::cerr << "FAIL decode " << p[1] << " " << err << "\n";
                ++failed;
                continue;
            }
            const std::string hex = to_hex(value.str);
            const std::string hash = godbrain::memory::keccak256_hex(value.str);
            if (hex != p[3] || hash != p[4]) {
                std::cerr << "FAIL decode " << p[1] << " hex " << hex << " hash " << hash
                          << "\n";
                ++failed;
            }
        } else if (p[0] == "pin") {
            godbrain::memory::Json content;
            std::string err;
            if (p.size() != 5 || (p[4] != "stale" && p[4] != "current") ||
                !godbrain::memory::parse_json(p[2], &content, &err) ||
                content.kind != godbrain::memory::Json::Kind::String) {
                std::cerr << "FAIL pin fixture " << p[1] << "\n";
                ++failed;
                continue;
            }
            if (godbrain::memory::has_mismatched_os_pin(content.str, p[3]) != (p[4] == "stale")) {
                std::cerr << "FAIL pin applicability " << p[1] << "\n";
                ++failed;
            }
        } else if (p[0] == "span") {
            if (p.size() < 5) {
                std::cerr << "FAIL span fields\n";
                ++failed;
                continue;
            }
            const std::string source = unhex(p[2]);
            std::string err;
            const bool ok = godbrain::memory::validate_evidence_spans({p[3]}, source, &err);
            const bool want = p[4] == "ok";
            if (ok != want) {
                std::cerr << "FAIL span " << p[1] << "\n";
                ++failed;
            }
        }
    }
    return failed == 0 ? 0 : 1;
#endif
}

int run_truth_fixture() {
#ifndef GODBRAIN_IDENTITY_FIXTURE
    return 1;
#else
    try {
        std::string path = GODBRAIN_IDENTITY_FIXTURE;
        path = path.substr(0, path.find_last_of("\\/") + 1) + "truth_observation_parity.json";
        std::ifstream in(path);
        if (!in) throw std::runtime_error("Truth fixture could not be opened");
        const std::string input((std::istreambuf_iterator<char>(in)), {});
        const auto fixture = nlohmann::json::parse(input);
        const auto raw = nlohmann::json::parse(fixture.at("raw_transcript").get<std::string>());
        const auto generated = godbrain_truth::assertion_document(
            raw.at("observation"), raw.at("evidence"), "windows-sre", "host_fact");
        if (generated != fixture) throw std::runtime_error("Production assertion differs from shared fixture");
        godbrain::memory::Route route;
        std::string error;
        if (!godbrain::memory::classify_and_parse(input, &route, &error)) {
            throw std::runtime_error("Truth envelope rejected: " + error);
        }
        const auto& claim = route.ingest.claims.at(0);
        if (route.kind != godbrain::memory::CommandKind::Ingest ||
            !godbrain::memory::validate_evidence_spans(
                claim.evidence_spans, route.ingest.raw_transcript, &error) ||
            godbrain::memory::has_mismatched_os_pin(claim.content, "Core/26100.0") ||
            !godbrain::memory::has_mismatched_os_pin(claim.content, "Core/26100.1")) {
            throw std::runtime_error("Truth evidence span or OS-pin contract changed: " + error);
        }
        for (const auto* invalid : {"raw", "trust", "unknown", "trailing"}) {
            auto bad = fixture;
            std::string suffix;
            if (std::string(invalid) == "raw") bad["raw_transcript"] = "changed source";
            if (std::string(invalid) == "trust") bad["payload"]["trust_tier"] = "verified";
            if (std::string(invalid) == "unknown") bad["new_wire_field"] = true;
            if (std::string(invalid) == "trailing") suffix = "{}";
            error.clear();
            if (godbrain::memory::classify_and_parse(bad.dump() + suffix, &route, &error)) {
                throw std::runtime_error("Invalid assertion envelope was accepted");
            }
        }
        std::cout << "PASS: production truth envelope, existing strict protocol and source/pin parity\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL truth fixture: " << error.what() << '\n';
        return 1;
    }
#endif
}

}  // namespace

int main() {
    const int protocol = godbrain::memory::run_self_test();
    const int snapshot = godbrain::memory::run_snapshot_self_test();
    const int identity = run_identity_fixture();
    const int truth = run_truth_fixture();
    const int bson = godbrain::memory::run_bson_text_self_test();
    const int projected = godbrain::memory::run_projected_text_self_test();
    const int rag = godbrain::memory::run_rag_text_self_test();
    return (protocol == 0 && snapshot == 0 && identity == 0 && truth == 0 &&
            bson == 0 && projected == 0 && rag == 0)
               ? 0
               : 1;
}
