#include "godbrain/memory_store/json.hpp"
#include "godbrain/memory_store/protocol.hpp"
#include "godbrain/memory_store/snapshot.hpp"
#include "godbrain/memory_store/store.hpp"

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

}  // namespace

int main() {
    const int protocol = godbrain::memory::run_self_test();
    const int snapshot = godbrain::memory::run_snapshot_self_test();
    const int identity = run_identity_fixture();
    const int bson = godbrain::memory::run_bson_text_self_test();
    return (protocol == 0 && snapshot == 0 && identity == 0 && bson == 0) ? 0 : 1;
}
