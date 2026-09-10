#include "http_loopback.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <string>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#endif

namespace godbrain::memory {
namespace {

constexpr int kMaxHeaderBytes = 16 * 1024;
constexpr int kMaxBodyBytes = 32 * 1024;

std::string to_lower_copy(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string header_value(const std::string& headers, const char* name) {
    std::string key = to_lower_copy(name);
    std::string lower = to_lower_copy(headers);
    auto pos = lower.find("\r\n" + key + ":");
    if (pos == std::string::npos) {
        if (lower.compare(0, key.size() + 1, key + ":") == 0) pos = 0;
        else return "";
    } else {
        pos += 2;
    }
    auto colon = headers.find(':', pos);
    if (colon == std::string::npos) return "";
    auto end = headers.find("\r\n", colon);
    if (end == std::string::npos) end = headers.size();
    std::string v = headers.substr(colon + 1, end - colon - 1);
    while (!v.empty() && std::isspace(static_cast<unsigned char>(v.front())) != 0) v.erase(v.begin());
    while (!v.empty() && std::isspace(static_cast<unsigned char>(v.back())) != 0) v.pop_back();
    return v;
}

bool parse_request_line(const std::string& line, HttpRequest* req) {
    auto s1 = line.find(' ');
    auto s2 = line.rfind(' ');
    if (s1 == std::string::npos || s2 == s1) return false;
    req->method = line.substr(0, s1);
    std::string target = line.substr(s1 + 1, s2 - s1 - 1);
    auto q = target.find('?');
    if (q == std::string::npos) {
        req->path = target;
    } else {
        req->path = target.substr(0, q);
        req->query = target.substr(q + 1);
    }
    return !req->method.empty() && !req->path.empty();
}

int recv_timeout(SOCKET s, char* buf, int n, int timeout_ms) {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(s, &fds);
    timeval tv{};
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int r = select(0, &fds, nullptr, nullptr, &tv);
    if (r <= 0) return -1;
    return recv(s, buf, n, 0);
}

void send_all(SOCKET s, const std::string& data) {
    size_t off = 0;
    while (off < data.size()) {
        int n = send(s, data.data() + off, static_cast<int>(data.size() - off), 0);
        if (n <= 0) return;
        off += static_cast<size_t>(n);
    }
}

void handle_client(SOCKET client, const HttpHandler& handler) {
    DWORD to = 6000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&to), sizeof to);
    to = 8000;
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&to), sizeof to);

    std::string raw;
    char buf[2048];
    while (raw.find("\r\n\r\n") == std::string::npos && static_cast<int>(raw.size()) < kMaxHeaderBytes) {
        int n = recv_timeout(client, buf, sizeof buf, 2000);
        if (n <= 0) return;
        raw.append(buf, static_cast<size_t>(n));
    }
    auto hdr_end = raw.find("\r\n\r\n");
    if (hdr_end == std::string::npos) {
        send_all(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    std::string headers = raw.substr(0, hdr_end);
    std::string body = raw.substr(hdr_end + 4);
    auto line_end = headers.find("\r\n");
    if (line_end == std::string::npos) return;
    HttpRequest req;
    if (!parse_request_line(headers.substr(0, line_end), &req)) {
        send_all(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    req.content_type = header_value(headers, "Content-Type");
    int content_length = 0;
    std::string cl = header_value(headers, "Content-Length");
    if (!cl.empty()) {
        try {
            content_length = std::stoi(cl);
        } catch (...) {
            content_length = -1;
        }
    }
    if (content_length < 0 || content_length > kMaxBodyBytes) {
        send_all(client, "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    while (static_cast<int>(body.size()) < content_length) {
        int n = recv_timeout(client, buf, sizeof buf, 6000);
        if (n <= 0) return;
        body.append(buf, static_cast<size_t>(n));
        if (static_cast<int>(body.size()) > kMaxBodyBytes) {
            send_all(client, "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        }
    }
    if (content_length > 0) body.resize(static_cast<size_t>(content_length));
    else body.clear();
    req.body = std::move(body);

    HttpResponse resp = handler(req);
    std::string out = "HTTP/1.1 " + std::to_string(resp.status) + " \r\n";
    out += "Content-Type: application/json\r\n";
    out += "X-Content-Type-Options: nosniff\r\n";
    out += "Cache-Control: no-store\r\n";
    out += "Connection: close\r\n";
    out += "Content-Length: " + std::to_string(resp.body.size()) + "\r\n\r\n";
    out += resp.body;
    send_all(client, out);
}

}  // namespace

int http_serve_loopback(uint16_t port, const HttpHandler& handler, std::atomic<bool>* stop) {
#if !defined(_WIN32)
    (void)port;
    (void)handler;
    (void)stop;
    return 1;
#else
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
    SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls == INVALID_SOCKET) {
        WSACleanup();
        return 1;
    }
    BOOL reuse = TRUE;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof reuse);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (bind(ls, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
        closesocket(ls);
        WSACleanup();
        return 1;
    }
    if (listen(ls, 16) != 0) {
        closesocket(ls);
        WSACleanup();
        return 1;
    }
    u_long nonblock = 1;
    ioctlsocket(ls, FIONBIO, &nonblock);
    while (stop == nullptr || !stop->load()) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(ls, &fds);
        timeval tv{1, 0};
        int r = select(0, &fds, nullptr, nullptr, &tv);
        if (r <= 0) continue;
        SOCKET client = accept(ls, nullptr, nullptr);
        if (client == INVALID_SOCKET) continue;
        u_long nb = 0;
        ioctlsocket(client, FIONBIO, &nb);
        handle_client(client, handler);
        closesocket(client);
    }
    closesocket(ls);
    WSACleanup();
    return 0;
#endif
}

}  // namespace godbrain::memory
