#pragma once

#include "httplib.h"
#include "json.hpp"
#include <chrono>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace phone_desk {
using json = nlohmann::json;

bool authorized(const httplib::Request& request, const std::string& token,
                const std::string& owner_login, bool trusted_proxy = false);
bool trusted_serve_peer(const httplib::Request& request);
json model_status(int port, const json& models, const json& health);
json tailscale_status(const json& status);
json speech_status(const json& health);
json rustdesk_status(const std::string& service_state, bool server_observed,
                    const std::string& probe_error = {});
json read_rustdesk_status();
std::string owner_login(const json& status);

struct ProxyProcessIdentity {
    unsigned long pid = 0;
    unsigned long parent_pid = 0;
    unsigned long session = 0;
    long long created = 0;
    std::wstring image;
};
bool valid_proxy_lineage(const ProxyProcessIdentity& service,
                         const ProxyProcessIdentity& peer);
bool same_proxy_process(const ProxyProcessIdentity& before,
                        const ProxyProcessIdentity& after);

class OwnerIdentity {
public:
    std::string resolve(bool trusted_proxy, const std::function<json()>& read,
        std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now());

private:
    std::mutex mutex_;
    std::string login_;
    std::chrono::steady_clock::time_point next_attempt_{};
};

class Server {
public:
    Server(std::string token, const std::string& html_path);
    ~Server();
    bool start();
    void stop();

private:
    json snapshot();
    httplib::Server server_;
    std::thread thread_;
    std::string token_;
    OwnerIdentity owner_;
    std::string html_;
    std::mutex mutex_;
    json cached_;
    std::chrono::steady_clock::time_point sampled_{};
};
}
