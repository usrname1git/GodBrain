#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>

namespace godbrain::memory {

struct HttpRequest {
    std::string method;
    std::string path;
    std::string query;
    std::string content_type;
    std::string body;
};

struct HttpResponse {
    int status = 200;
    std::string body;
};

using HttpHandler = std::function<HttpResponse(const HttpRequest&)>;

// Bind 127.0.0.1 only. Returns 0 on clean stop, 1 on bind/listen failure.
int http_serve_loopback(uint16_t port, const HttpHandler& handler, std::atomic<bool>* stop);

}  // namespace godbrain::memory
