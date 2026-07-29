#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <chrono>

#include "../cpp_kernel/json.hpp"
using json = nlohmann::json;

const double RATE_LIMIT_DELAY = 6.0;

std::string exec_cmd(const std::string& cmd) {
    char buffer[256];
    std::string result = "";
    FILE* pipe = _popen(cmd.c_str(), "r");
    if (!pipe) return "";
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        result += buffer;
    }
    _pclose(pipe);
    return result;
}

std::string url_encode(const std::string &value) {
    std::string escaped;
    for (char c : value) {
        if (isalnum((unsigned char)c) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped += c;
        } else {
            char buf[10];
            snprintf(buf, sizeof(buf), "%%%02X", (unsigned char)c);
            escaped += buf;
        }
    }
    return escaped;
}

std::vector<std::string> get_targets() {
    return {
        "AK-47 | Redline (Field-Tested)", "AK-47 | Slate (Field-Tested)"
    };
}

void fetch_price(const std::string& market_hash_name) {
    std::string url = "https://steamcommunity.com/market/priceoverview/?appid=730&currency=1&market_hash_name=" + url_encode(market_hash_name);
    std::string cmd = "curl -s -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64)\" \"" + url + "\"";
    
    std::string out = exec_cmd(cmd);
    
    try {
        json data = json::parse(out);
        if (data.value("success", false)) {
            std::string lowest_price = data.value("lowest_price", "N/A");
            std::string volume = data.value("volume", "N/A");
            std::cout << "[CACHE UPDATED] " << market_hash_name << ": " << lowest_price << " (Vol: " << volume << ")\n";
        } else {
            std::cout << "[WARNING] Steam success=false for " << market_hash_name << "\n";
        }
    } catch (...) {
        std::cout << "[ERROR] JSON parse error for " << market_hash_name << "\n";
    }
}

int main(int argc, char* argv[]) {
    std::cout << "[CS2_MARKET_CRAWLER] Initializing Expanded CS2 Market Crawler (C++ Native)...\n";
    auto targets = get_targets();
    std::cout << "Loaded " << targets.size() << " priority targets. Delay set to " << RATE_LIMIT_DELAY << "s.\n";

    bool daemon_mode = (argc > 1 && std::string(argv[1]) == "--daemon");

    do {
        for (const auto& skin : targets) {
            // In a full implementation we'd check a MongoDB cache here
            fetch_price(skin);
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(RATE_LIMIT_DELAY * 1000)));
        }
        
        if (daemon_mode) {
            std::cout << "Main loadout cycle complete. Sleeping 1 hour.\n";
            std::this_thread::sleep_for(std::chrono::hours(1));
        }
    } while (daemon_mode);

    return 0;
}