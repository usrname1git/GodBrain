#include "polymarket/paper.hpp"

#include <array>
#include <iomanip>
#include <sstream>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#endif

namespace polymarket::paper {
namespace {

std::string encode(std::string_view value) {
    std::ostringstream output;
    output << std::uppercase << std::hex;
    for (const unsigned char character : value) {
        if ((character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' ||
            character == '_' || character == '.' || character == '~') {
            output << static_cast<char>(character);
        } else {
            output << '%' << std::setw(2) << std::setfill('0')
                   << static_cast<unsigned int>(character);
        }
    }
    return output.str();
}

#ifdef _WIN32
std::wstring widen(std::string_view value) {
    if (value.empty()) {
        return {};
    }
    const int length = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    if (length <= 0) {
        throw PaperError("invalid UTF-8 in public request");
    }
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), result.data(), length) != length) {
        throw PaperError("failed to encode public request");
    }
    return result;
}

struct Handle {
    HINTERNET value{nullptr};
    ~Handle() {
        if (value != nullptr) {
            WinHttpCloseHandle(value);
        }
    }
    Handle() = default;
    explicit Handle(HINTERNET handle) : value(handle) {}
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};
#endif

}  // namespace

Json WinHttpPublicTransport::get(
    PublicService service,
    std::string_view path,
    const std::map<std::string, std::string>& query) {
#ifndef _WIN32
    (void)service;
    (void)path;
    (void)query;
    throw PaperError("WinHTTP public transport is only available on Windows");
#else
    if (path.empty() || path.front() != '/' || path.find("..") != std::string_view::npos) {
        throw PaperError("invalid public API path");
    }
    const wchar_t* host = nullptr;
    switch (service) {
    case PublicService::gamma:
        host = L"gamma-api.polymarket.com";
        break;
    case PublicService::clob:
        host = L"clob.polymarket.com";
        break;
    }

    std::string target(path);
    bool first = true;
    for (const auto& [key, value] : query) {
        target += first ? '?' : '&';
        first = false;
        target += encode(key) + "=" + encode(value);
    }
    const std::wstring wide_target = widen(target);

    Handle session(WinHttpOpen(
        L"GodBrain-Polymarket-Paper/0.1",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0));
    if (!session.value) {
        throw PaperError("WinHTTP session creation failed");
    }
    WinHttpSetTimeouts(session.value, 3'000, 3'000, 3'000, 5'000);
    Handle connection(WinHttpConnect(session.value, host, INTERNET_DEFAULT_HTTPS_PORT, 0));
    if (!connection.value) {
        throw PaperError("WinHTTP public connection failed");
    }
    Handle request(WinHttpOpenRequest(
        connection.value,
        L"GET",
        wide_target.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        WINHTTP_FLAG_SECURE));
    if (!request.value) {
        throw PaperError("WinHTTP public GET creation failed");
    }
    const wchar_t* headers = L"Accept: application/json\r\n";
    if (!WinHttpSendRequest(
            request.value, headers, static_cast<DWORD>(-1L),
            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request.value, nullptr)) {
        throw PaperError("public GET request failed");
    }
    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (!WinHttpQueryHeaders(
            request.value,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX,
            &status,
            &status_size,
            WINHTTP_NO_HEADER_INDEX) ||
        status < 200 || status >= 300) {
        throw PaperError("public GET returned non-success status");
    }

    std::string body;
    constexpr std::size_t maximum_body = 4 * 1024 * 1024;
    while (true) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request.value, &available)) {
            throw PaperError("failed to read public response");
        }
        if (available == 0) {
            break;
        }
        if (body.size() + available > maximum_body) {
            throw PaperError("public response exceeds size limit");
        }
        const std::size_t previous = body.size();
        body.resize(previous + available);
        DWORD read = 0;
        if (!WinHttpReadData(
                request.value, body.data() + previous, available, &read)) {
            throw PaperError("failed to receive public response");
        }
        body.resize(previous + read);
    }
    try {
        return Json::parse(body);
    } catch (const Json::exception& error) {
        throw PaperError(std::string("public response is not valid JSON: ") + error.what());
    }
#endif
}

}  // namespace polymarket::paper
