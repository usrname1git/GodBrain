#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>
#include <winhttp.h>
#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <string>
#include "protected_read.h"
#include "truth_assertion.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "winhttp.lib")

namespace godbrain_public_web {

inline bool public_ipv4(unsigned long address) {
    const auto ip = ntohl(address);
    const auto first = ip >> 24, second = (ip >> 16) & 255, third = (ip >> 8) & 255;
    return first != 0 && first != 10 && first != 127 && first < 224 &&
        !(first == 100 && second >= 64 && second <= 127) &&
        !(first == 169 && second == 254) &&
        !(first == 172 && second >= 16 && second <= 31) &&
        !(first == 192 && (second == 168 || (second == 0 && (third == 0 || third == 2)) ||
                           (second == 88 && third == 99))) &&
        !(first == 198 && (second == 18 || second == 19 || (second == 51 && third == 100))) &&
        !(first == 203 && second == 0 && third == 113);
}

struct Target { std::string url, host, address; };

inline Target target(const std::string& url) {
    if (url.empty() || url.size() > 4096 ||
        url.find_first_of("\\\"?#") != std::string::npos ||
        std::any_of(url.begin(), url.end(), [](unsigned char ch) { return ch <= 32 || ch >= 127; })) {
        throw std::runtime_error("use one public ASCII HTTPS URL without credentials, query or fragment");
    }
    const auto wide = godbrain_protected_read::wide(url);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUserNameLength = parts.dwPasswordLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &parts) ||
        parts.nScheme != INTERNET_SCHEME_HTTPS || parts.nPort != 443 ||
        parts.dwUserNameLength || parts.dwPasswordLength || parts.dwHostNameLength == 0) {
        throw std::runtime_error("only credential-free HTTPS on port 443 is accepted");
    }
    const std::string host = godbrain_protected_read::utf8(
        std::wstring(parts.lpszHostName, parts.dwHostNameLength));
    if (host.find('.') == std::string::npos ||
        std::any_of(host.begin(), host.end(), [](unsigned char ch) {
            return !std::isalnum(ch) && ch != '-' && ch != '.';
        })) throw std::runtime_error("a public DNS hostname is required");
    return {url, host, ""};
}

inline std::string resolve_public_ipv4(const std::string& host) {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data)) throw std::runtime_error("network initialization failed");
    struct Network { ~Network() { WSACleanup(); } } network;
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* addresses = nullptr;
    if (getaddrinfo(host.c_str(), "443", &hints, &addresses)) {
        throw std::runtime_error("public hostname resolution failed");
    }
    struct Addresses { addrinfo* value; ~Addresses() { freeaddrinfo(value); } } guard{addresses};
    std::string selected;
    for (auto* entry = addresses; entry; entry = entry->ai_next) {
        const auto* address = reinterpret_cast<const sockaddr_in*>(entry->ai_addr);
        if (!public_ipv4(address->sin_addr.s_addr)) {
            throw std::runtime_error("private, loopback, link-local or reserved destination denied");
        }
        char text[INET_ADDRSTRLEN]{};
        if (!InetNtopA(AF_INET, &address->sin_addr, text, sizeof(text))) {
            throw std::runtime_error("cannot encode public destination");
        }
        if (selected.empty()) selected = text;
    }
    if (selected.empty()) throw std::runtime_error("no public IPv4 destination; no fallback attempted");
    return selected;
}

inline nlohmann::json observation(const std::string& url, const std::string& response) {
    const auto end = response.find("\r\n\r\n");
    if (end == std::string::npos || end > 32768 ||
        response.rfind("HTTP/1.1 200 ", 0) != 0) {
        throw std::runtime_error("public read requires complete HTTP 200; redirects and partial responses denied");
    }
    std::string headers = response.substr(0, end);
    std::transform(headers.begin(), headers.end(), headers.begin(),
        [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    const auto type_at = headers.find("\r\ncontent-type:");
    if (type_at == std::string::npos) throw std::runtime_error("public response has no content type");
    const auto type_end = headers.find("\r\n", type_at + 2);
    const std::string mime = headers.substr(type_at + 15,
        type_end == std::string::npos ? type_end : type_end - type_at - 15);
    godbrain_truth::Document document{response.substr(end + 4), mime, true};
    const auto text = godbrain_truth::document_text(document);
    size_t clip = (std::min)(text.size(), size_t{10000});
    while (clip < text.size() && (static_cast<unsigned char>(text[clip]) & 0xc0) == 0x80) --clip;
    return {{"url", url}, {"trust", "untrusted_reference"}, {"verified", false},
        {"source_bytes", document.body.size()}, {"text", text.substr(0, clip)},
        {"clipped", clip < text.size()}, {"redirects_followed", false}};
}
}
