#include "godbrain/polygon_observer.hpp"

#include <algorithm>
#include <chrono>
#include <limits>
#include <string>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#endif

namespace godbrain::polygon {
namespace {

#ifdef _WIN32
std::wstring widen(std::string_view value) {
    if (value.empty()) {
        return {};
    }
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        throw TransportError("WinHTTP string input is too large");
    }
    const int source_size = static_cast<int>(value.size());
    const int length = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), source_size, nullptr, 0);
    if (length <= 0) {
        throw TransportError("WinHTTP input is not valid UTF-8");
    }
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(
            CP_UTF8,
            MB_ERR_INVALID_CHARS,
            value.data(),
            source_size,
            result.data(),
            length) != length) {
        throw TransportError("WinHTTP UTF-8 conversion failed");
    }
    return result;
}

int timeout_value(std::chrono::milliseconds value) {
    if (value.count() <= 0 ||
        value.count() > static_cast<long long>(std::numeric_limits<int>::max())) {
        throw TransportError("WinHTTP timeout is out of range");
    }
    return static_cast<int>(value.count());
}

class InternetHandle {
public:
    explicit InternetHandle(HINTERNET value = nullptr) : value_(value) {}
    ~InternetHandle() {
        if (value_ != nullptr) {
            WinHttpCloseHandle(value_);
        }
    }

    InternetHandle(const InternetHandle&) = delete;
    InternetHandle& operator=(const InternetHandle&) = delete;

    [[nodiscard]] HINTERNET get() const noexcept { return value_; }

private:
    HINTERNET value_;
};

HttpResponse perform_request(
    const Endpoint& endpoint,
    std::string_view method,
    std::string_view body,
    const TransportLimits& limits) {
    const Endpoint validated = parse_local_endpoint(endpoint_display(endpoint));
    if (body.size() > limits.maximum_request_bytes ||
        body.size() > static_cast<std::size_t>(std::numeric_limits<DWORD>::max())) {
        throw TransportError("WinHTTP request exceeds size limit");
    }

    const std::wstring host = widen(validated.host);
    const std::wstring path = widen(validated.path);
    const std::wstring wide_method = widen(method);
    InternetHandle session(WinHttpOpen(
        L"GodBrain-Polygon-Observer/0.1",
        WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0));
    if (session.get() == nullptr) {
        throw TransportError("WinHTTP session creation failed");
    }
    if (!WinHttpSetTimeouts(
            session.get(),
            timeout_value(limits.resolve_timeout),
            timeout_value(limits.connect_timeout),
            timeout_value(limits.send_timeout),
            timeout_value(limits.receive_timeout))) {
        throw TransportError("WinHTTP timeout configuration failed");
    }

    InternetHandle connection(
        WinHttpConnect(session.get(), host.c_str(), validated.port, 0));
    if (connection.get() == nullptr) {
        throw TransportError("WinHTTP loopback connection creation failed");
    }

    const DWORD request_flags = validated.secure ? WINHTTP_FLAG_SECURE : 0;
    InternetHandle request(WinHttpOpenRequest(
        connection.get(),
        wide_method.c_str(),
        path.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        request_flags));
    if (request.get() == nullptr) {
        throw TransportError("WinHTTP request creation failed");
    }
    DWORD disabled_features = WINHTTP_DISABLE_REDIRECTS;
    if (!WinHttpSetOption(
            request.get(),
            WINHTTP_OPTION_DISABLE_FEATURE,
            &disabled_features,
            sizeof(disabled_features))) {
        throw TransportError("WinHTTP redirect policy configuration failed");
    }

    const wchar_t* headers = method == "POST"
        ? L"Accept: application/json\r\nContent-Type: application/json\r\n"
        : L"Accept: application/json\r\n";
    const DWORD body_size = static_cast<DWORD>(body.size());
    const auto started = std::chrono::steady_clock::now();
    if (!WinHttpSendRequest(
            request.get(),
            headers,
            static_cast<DWORD>(-1L),
            body.empty() ? WINHTTP_NO_REQUEST_DATA
                         : const_cast<char*>(body.data()),
            body_size,
            body_size,
            0) ||
        !WinHttpReceiveResponse(request.get(), nullptr)) {
        throw TransportError("WinHTTP local request failed");
    }

    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (!WinHttpQueryHeaders(
            request.get(),
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX,
            &status,
            &status_size,
            WINHTTP_NO_HEADER_INDEX)) {
        throw TransportError("WinHTTP response status is unavailable");
    }

    std::string response_body;
    while (true) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request.get(), &available)) {
            throw TransportError("WinHTTP response read failed");
        }
        if (available == 0) {
            break;
        }
        const std::size_t available_size = static_cast<std::size_t>(available);
        if (available_size > limits.maximum_response_bytes - std::min(
                response_body.size(), limits.maximum_response_bytes)) {
            throw TransportError("WinHTTP response exceeds size limit");
        }
        const std::size_t previous = response_body.size();
        response_body.resize(previous + available_size);
        DWORD read = 0;
        if (!WinHttpReadData(
                request.get(),
                response_body.data() + previous,
                available,
                &read)) {
            throw TransportError("WinHTTP response receive failed");
        }
        response_body.resize(previous + static_cast<std::size_t>(read));
    }

    return {
        .status = status,
        .body = std::move(response_body),
        .latency = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started),
    };
}
#endif

}  // namespace

HttpResponse WinHttpRpcTransport::post(
    const Endpoint& endpoint,
    std::string_view body,
    const TransportLimits& limits) {
#ifndef _WIN32
    (void)endpoint;
    (void)body;
    (void)limits;
    throw TransportError("WinHTTP RPC transport is only available on Windows");
#else
    return perform_request(endpoint, "POST", body, limits);
#endif
}

HttpResponse WinHttpRpcTransport::get(
    const Endpoint& endpoint,
    const TransportLimits& limits) {
#ifndef _WIN32
    (void)endpoint;
    (void)limits;
    throw TransportError("WinHTTP RPC transport is only available on Windows");
#else
    return perform_request(endpoint, "GET", {}, limits);
#endif
}

}  // namespace godbrain::polygon
