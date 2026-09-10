#include "godbrain/memory_store/embedding.hpp"
#include "godbrain/memory_store/json.hpp"

#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <iomanip>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winnls.h>
#include <winhttp.h>
#include <bcrypt.h>
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "Normaliz.lib")
#endif

namespace godbrain::memory {
namespace {

std::string json_escape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':
                o += "\\\"";
                break;
            case '\\':
                o += "\\\\";
                break;
            case '\n':
                o += "\\n";
                break;
            case '\r':
                o += "\\r";
                break;
            case '\t':
                o += "\\t";
                break;
            default:
                if (c < 0x20) {
                    std::ostringstream h;
                    h << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                    o += h.str();
                } else {
                    o.push_back(static_cast<char>(c));
                }
        }
    }
    return o;
}

bool valid_bounded_identity(const std::string& value, int maximum) {
    if (value.empty() || static_cast<int>(value.size()) > maximum) return false;
    if (value != std::string(value.begin(), value.end())) return false;
    size_t start = 0;
    size_t end = value.size();
    while (start < end && (value[start] == ' ' || value[start] == '\t')) return false;
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) return false;
    for (unsigned char c : value) {
        if (c < 0x20) return false;
    }
    return true;
}

bool lowercase_hex64(const std::string& s) {
    if (s.size() != 64) return false;
    for (unsigned char c : s) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

#if defined(_WIN32)
std::wstring utf8_to_wide(const std::string& u8, std::string* err) {
    if (u8.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, u8.data(), static_cast<int>(u8.size()), nullptr, 0);
    if (n <= 0) {
        if (err) *err = "embedding input is not valid UTF-8";
        return L"";
    }
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, u8.data(), static_cast<int>(u8.size()), w.data(), n);
    return w;
}

std::string wide_to_utf8(const std::wstring& w, std::string* err) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) {
        if (err) *err = "embedding normalize failed";
        return "";
    }
    std::string o(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), o.data(), n, nullptr, nullptr);
    return o;
}

bool is_unicode_space(wchar_t c) {
    if (c == L' ' || c == L'\t' || c == L'\n' || c == L'\r' || c == L'\f' || c == L'\v') return true;
    if (c == 0x00A0 || c == 0x1680 || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F ||
        c == 0x3000) {
        return true;
    }
    return c >= 0x2000 && c <= 0x200A;
}

std::wstring nfkc_wide(const std::wstring& in, std::string* err) {
    if (in.empty()) return in;
    int n = NormalizeString(NormalizationKC, in.c_str(), static_cast<int>(in.size()), nullptr, 0);
    if (n <= 0) {
        if (err) *err = "embedding NFKC failed";
        return L"";
    }
    std::wstring out(static_cast<size_t>(n), L'\0');
    int wrote = NormalizeString(
        NormalizationKC, in.c_str(), static_cast<int>(in.size()), out.data(), n);
    if (wrote <= 0) {
        if (err) *err = "embedding NFKC failed";
        return L"";
    }
    out.resize(static_cast<size_t>(wrote));
    return out;
}

std::wstring fields_join(const std::wstring& in) {
    std::wstring out;
    bool in_token = false;
    for (wchar_t c : in) {
        if (is_unicode_space(c)) {
            in_token = false;
            continue;
        }
        if (!out.empty() && !in_token) out.push_back(L' ');
        out.push_back(c);
        in_token = true;
    }
    return out;
}

bool sha256_hex(const std::string& bytes, std::string* hex, std::string* err) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    NTSTATUS st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (st != 0) {
        if (err) *err = "SHA256 provider unavailable";
        return false;
    }
    UCHAR hash[32];
    st = BCryptHash(
        alg,
        nullptr,
        0,
        reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),
        static_cast<ULONG>(bytes.size()),
        hash,
        sizeof hash);
    BCryptCloseAlgorithmProvider(alg, 0);
    if (st != 0) {
        if (err) *err = "SHA256 hash failed";
        return false;
    }
    std::ostringstream o;
    o << std::hex << std::setfill('0');
    for (unsigned char b : hash) o << std::setw(2) << static_cast<int>(b);
    *hex = o.str();
    return true;
}

std::string wide_lower(const std::wstring& w) {
    if (w.empty()) return "";
    std::wstring copy = w;
    CharLowerBuffW(copy.data(), static_cast<DWORD>(copy.size()));
    std::string dummy;
    return wide_to_utf8(copy, &dummy);
}
#endif

bool parse_bool_go(const std::string& t, bool* out) {
    if (t == "1" || t == "t" || t == "T" || t == "TRUE" || t == "true" || t == "True") {
        *out = true;
        return true;
    }
    if (t == "0" || t == "f" || t == "F" || t == "FALSE" || t == "false" || t == "False") {
        *out = false;
        return true;
    }
    return false;
}

std::string fixture_token(std::string token) {
    while (!token.empty()) {
        char c = token.front();
        if (c == '.' || c == ',' || c == ':' || c == ';' || c == '!' || c == '?' || c == '(' ||
            c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '"' || c == '\'') {
            token.erase(token.begin());
            continue;
        }
        break;
    }
    while (!token.empty()) {
        char c = token.back();
        if (c == '.' || c == ',' || c == ':' || c == ';' || c == '!' || c == '?' || c == '(' ||
            c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '"' || c == '\'') {
            token.pop_back();
            continue;
        }
        break;
    }
    if (token == "auth" || token == "authenticate" || token == "authentication" ||
        token == "authorization" || token == "bearer" || token == "credential" ||
        token == "credentials" || token == "token") {
        return "concept-security-auth";
    }
    if (token == "restart" || token == "reboot" || token == "recover" || token == "recovery" ||
        token == "resume") {
        return "concept-recovery";
    }
    if (token == "database" || token == "mongodb" || token == "store" || token == "storage") {
        return "concept-storage";
    }
    if (token == "localhost" || token == "loopback" || token == "127.0.0.1" || token == "::1") {
        return "concept-loopback";
    }
    return token;
}

std::string media_type(const std::string& content_type) {
    auto semi = content_type.find(';');
    std::string t = semi == std::string::npos ? content_type : content_type.substr(0, semi);
    while (!t.empty() && std::isspace(static_cast<unsigned char>(t.front())) != 0) t.erase(t.begin());
    while (!t.empty() && std::isspace(static_cast<unsigned char>(t.back())) != 0) t.pop_back();
    for (char& c : t) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return t;
}

}  // namespace

bool embedding_identity_valid(const EmbeddingIdentity& id, std::string* err) {
    if (id.provider_kind != "openai-compatible-local" &&
        id.provider_kind != "deterministic-test-fake") {
        if (err) *err = "embedding provider configuration is invalid";
        return false;
    }
    for (const std::string* v : {
             &id.model_identifier,
             &id.model_revision,
             &id.schema_version,
             &id.indexer_version,
             &id.vector_backend}) {
        if (!valid_bounded_identity(*v, 128)) {
            if (err) *err = "embedding provider configuration is invalid";
            return false;
        }
    }
    if (!lowercase_hex64(id.model_hash)) {
        if (err) *err = "embedding provider configuration is invalid";
        return false;
    }
    if (id.dimension < 1 || id.dimension > kMaxEmbeddingDimension ||
        id.schema_version != kEmbeddingSchemaVersion ||
        id.indexer_version != kEmbeddingIndexerVersion ||
        id.vector_backend != kVectorBackendVersion) {
        if (err) *err = "embedding provider configuration is invalid";
        return false;
    }
    return true;
}

bool embedding_identity_equal(const EmbeddingIdentity& a, const EmbeddingIdentity& b) {
    return a.provider_kind == b.provider_kind && a.model_identifier == b.model_identifier &&
           a.model_revision == b.model_revision && a.model_hash == b.model_hash &&
           a.dimension == b.dimension && a.schema_version == b.schema_version &&
           a.indexer_version == b.indexer_version && a.vector_backend == b.vector_backend;
}

EmbeddingIdentity embedding_fake_identity(int dimension) {
    EmbeddingIdentity id;
    id.provider_kind = "deterministic-test-fake";
    id.model_identifier = "godbrain-fixture-embedding";
    id.model_revision = "v1";
    id.model_hash = std::string(64, 'a');
    id.dimension = dimension;
    id.schema_version = kEmbeddingSchemaVersion;
    id.indexer_version = kEmbeddingIndexerVersion;
    id.vector_backend = kVectorBackendVersion;
    return id;
}

bool embedding_endpoint_canonical(
    const std::string& raw, std::string* canonical, std::string* host, uint16_t* port, std::string* err) {
    const std::string p4 = "http://127.0.0.1:";
    const std::string p6 = "http://[::1]:";
    std::string rest;
    std::string h;
    if (raw.size() >= p4.size() && raw.compare(0, p4.size(), p4) == 0) {
        h = "127.0.0.1";
        rest = raw.substr(p4.size());
    } else if (raw.size() >= p6.size() && raw.compare(0, p6.size(), p6) == 0) {
        h = "::1";
        rest = raw.substr(p6.size());
    } else {
        if (err) *err = "endpoint must be an exact loopback HTTP /v1/embeddings URL";
        return false;
    }
    const auto slash = rest.find('/');
    if (slash == std::string::npos) {
        if (err) *err = "endpoint must be an exact loopback HTTP /v1/embeddings URL";
        return false;
    }
    if (rest.substr(slash) != "/v1/embeddings") {
        if (err) *err = "endpoint must be an exact loopback HTTP /v1/embeddings URL";
        return false;
    }
    const std::string port_text = rest.substr(0, slash);
    if (port_text.empty()) {
        if (err) *err = "endpoint requires an explicit valid port";
        return false;
    }
    int p = 0;
    for (char c : port_text) {
        if (c < '0' || c > '9') {
            if (err) *err = "endpoint requires an explicit valid port";
            return false;
        }
        p = p * 10 + (c - '0');
        if (p > 65535) {
            if (err) *err = "endpoint requires an explicit valid port";
            return false;
        }
    }
    if (p < 1 || std::to_string(p) != port_text) {
        if (err) *err = "endpoint requires an explicit valid port";
        return false;
    }
    if (host) *host = h;
    if (port) *port = static_cast<uint16_t>(p);
    if (canonical) {
        if (h == "::1") *canonical = "http://[::1]:" + port_text + "/v1/embeddings";
        else *canonical = "http://127.0.0.1:" + port_text + "/v1/embeddings";
    }
    return true;
}

bool embedding_runtime_from_env(EmbeddingRuntime* out, std::string* err) {
    if (out == nullptr) return false;
    *out = EmbeddingRuntime{};
    const char* endpoint = std::getenv("GODBRAIN_EMBEDDING_ENDPOINT");
    const char* model = std::getenv("GODBRAIN_EMBEDDING_MODEL");
    const char* revision = std::getenv("GODBRAIN_EMBEDDING_MODEL_REVISION");
    const char* hash = std::getenv("GODBRAIN_EMBEDDING_MODEL_SHA256");
    const char* dim_text = std::getenv("GODBRAIN_EMBEDDING_DIMENSION");
    const char* req_text = std::getenv("GODBRAIN_RAG_EMBEDDING_REQUIRED");
    auto nz = [](const char* s) { return s != nullptr && s[0] != '\0'; };
    if (nz(req_text)) {
        if (!parse_bool_go(req_text, &out->required)) {
            if (err) *err = "embedding: GODBRAIN_RAG_EMBEDDING_REQUIRED must be true or false";
            return false;
        }
    }
    const char* vals[] = {endpoint, model, revision, hash, dim_text};
    int configured = 0;
    for (const char* v : vals) {
        if (nz(v)) ++configured;
    }
    if (configured == 0) {
        if (out->required) {
            if (err) *err = "embedding: required provider is not configured";
            return false;
        }
        return true;
    }
    if (configured != 5) {
        if (err) *err = "embedding: all embedding identity variables must be set together";
        return false;
    }
    char* end = nullptr;
    const long dim_parsed = std::strtol(dim_text, &end, 10);
    if (end == dim_text || (end != nullptr && *end != '\0') || dim_parsed < 1 ||
        dim_parsed > kMaxEmbeddingDimension) {
        if (err) *err = "embedding: invalid embedding dimension";
        return false;
    }
    const int dim = static_cast<int>(dim_parsed);
    std::string canonical, host;
    uint16_t port = 0;
    if (!embedding_endpoint_canonical(endpoint, &canonical, &host, &port, err)) {
        if (err && err->find("embedding:") != 0) *err = "embedding: " + *err;
        return false;
    }
    out->configured = true;
    out->endpoint = canonical;
    out->model = model;
    out->identity.provider_kind = "openai-compatible-local";
    out->identity.model_identifier = model;
    out->identity.model_revision = revision;
    out->identity.model_hash = hash;
    out->identity.dimension = dim;
    out->identity.schema_version = kEmbeddingSchemaVersion;
    out->identity.indexer_version = kEmbeddingIndexerVersion;
    out->identity.vector_backend = kVectorBackendVersion;
    if (!embedding_identity_valid(out->identity, err)) {
        if (err) *err = std::string("embedding: ") + (err->empty() ? "invalid model identity" : *err);
        return false;
    }
    return true;
}

bool normalize_embedding_input(
    const std::string& input, std::string* normalized, std::string* input_hash, std::string* err) {
#if !defined(_WIN32)
    (void)input;
    if (err) *err = "embedding normalize requires Windows";
    return false;
#else
    std::string nfkc_err;
    std::wstring wide = utf8_to_wide(input, &nfkc_err);
    if (!nfkc_err.empty() && wide.empty() && !input.empty()) {
        if (err) *err = nfkc_err;
        return false;
    }
    wide = nfkc_wide(wide, err);
    if (err && !err->empty() && wide.empty() && !input.empty()) return false;
    wide = fields_join(wide);
    std::string utf8 = wide_to_utf8(wide, err);
    if (static_cast<int>(utf8.size()) > kMaxEmbeddingInputBytes) {
        int end = kMaxEmbeddingInputBytes;
        while (end > 0 && (static_cast<unsigned char>(utf8[static_cast<size_t>(end)]) & 0xC0) == 0x80) {
            --end;
        }
        utf8.resize(static_cast<size_t>(end));
    }
    if (normalized) *normalized = utf8;
    if (input_hash) {
        if (!sha256_hex(utf8, input_hash, err)) return false;
    }
    return true;
#endif
}

bool valid_embedding_vector(const std::vector<float>& vector, int dimension) {
    if (static_cast<int>(vector.size()) != dimension || dimension < 1 ||
        dimension > kMaxEmbeddingDimension) {
        return false;
    }
    double norm_sq = 0;
    for (float v : vector) {
        double d = static_cast<double>(v);
        if (!std::isfinite(d)) return false;
        norm_sq += d * d;
    }
    return norm_sq > 0 && std::isfinite(norm_sq);
}

bool embedding_cosine(const std::vector<float>& left, const std::vector<float>& right, double* out) {
    if (left.empty() || left.size() != right.size() || out == nullptr) return false;
    double dot = 0, na = 0, nb = 0;
    for (size_t i = 0; i < left.size(); ++i) {
        double a = static_cast<double>(left[i]);
        double b = static_cast<double>(right[i]);
        if (!std::isfinite(a) || !std::isfinite(b)) return false;
        dot += a * b;
        na += a * a;
        nb += b * b;
    }
    if (na == 0 || nb == 0) return false;
    double value = dot / (std::sqrt(na) * std::sqrt(nb));
    if (!std::isfinite(value)) return false;
    if (value > 1) value = 1;
    if (value < -1) value = -1;
    *out = value;
    return true;
}

bool embedding_embed_fake(int dimension, const std::string& content, std::vector<float>* vector, std::string* err) {
    EmbeddingIdentity id = embedding_fake_identity(dimension);
    if (!embedding_identity_valid(id, err)) return false;
    std::string normalized, hash;
    if (!normalize_embedding_input(content, &normalized, &hash, err)) return false;
#if defined(_WIN32)
    std::string lower_err;
    std::wstring w = utf8_to_wide(normalized, &lower_err);
    std::string lowered = wide_lower(w);
#else
    std::string lowered = normalized;
#endif
    std::vector<std::string> tokens;
    std::string cur;
    for (unsigned char c : lowered) {
        if (std::isspace(c) != 0) {
            if (!cur.empty()) {
                tokens.push_back(fixture_token(cur));
                cur.clear();
            }
        } else {
            cur.push_back(static_cast<char>(c));
        }
    }
    if (!cur.empty()) tokens.push_back(fixture_token(cur));
    std::vector<float> out(static_cast<size_t>(dimension), 0.0f);
    for (const std::string& token : tokens) {
        std::string th;
        if (!sha256_hex(token, &th, err)) return false;
        unsigned char raw[32];
        for (int i = 0; i < 32; ++i) {
            auto nyb = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                return 10 + (c - 'a');
            };
            raw[i] = static_cast<unsigned char>((nyb(th[static_cast<size_t>(i) * 2]) << 4) |
                                                nyb(th[static_cast<size_t>(i) * 2 + 1]));
        }
        for (int offset = 0; offset < 8; ++offset) {
            int index = static_cast<int>(raw[offset]) % dimension;
            float sign = (raw[offset + 8] & 1) == 1 ? -1.0f : 1.0f;
            out[static_cast<size_t>(index)] += sign * (1.0f + static_cast<float>(raw[offset + 16]) / 255.0f);
        }
    }
    double norm_sq = 0;
    for (float v : out) norm_sq += static_cast<double>(v) * static_cast<double>(v);
    if (norm_sq == 0) {
        out[0] = 1.0f;
    } else {
        float scale = static_cast<float>(1.0 / std::sqrt(norm_sq));
        for (float& v : out) v *= scale;
    }
    if (!valid_embedding_vector(out, dimension)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    *vector = std::move(out);
    return true;
}

#if defined(_WIN32)
static bool http_embed(
    const EmbeddingRuntime& runtime, const std::string& normalized, std::vector<float>* vector, std::string* err) {
    std::string host;
    uint16_t port = 0;
    std::string canonical;
    if (!embedding_endpoint_canonical(runtime.endpoint, &canonical, &host, &port, err)) return false;
    std::string body = std::string("{\"input\":\"") + json_escape(normalized) + "\",\"model\":\"" +
                       json_escape(runtime.model) + "\",\"encoding_format\":\"float\"}";
    if (static_cast<int>(body.size()) > kMaxEmbeddingRequestBytes) {
        if (err) *err = "embedding provider configuration is invalid";
        return false;
    }
    std::wstring whost = utf8_to_wide(host, err);
    HINTERNET session = WinHttpOpen(
        L"godbrain-cpp-memory-store",
        WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (session == nullptr) {
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    WinHttpSetTimeouts(session, 500, 500, 2000, 2000);
    DWORD disable = WINHTTP_DISABLE_REDIRECTS;
    WinHttpSetOption(session, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof disable);
    HINTERNET connect = WinHttpConnect(session, whost.c_str(), port, 0);
    if (connect == nullptr) {
        WinHttpCloseHandle(session);
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    HINTERNET request = WinHttpOpenRequest(
        connect,
        L"POST",
        L"/v1/embeddings",
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        0);
    if (request == nullptr) {
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    WinHttpAddRequestHeaders(
        request,
        L"Content-Type: application/json\r\nAccept: application/json",
        static_cast<DWORD>(-1),
        WINHTTP_ADDREQ_FLAG_ADD);
    BOOL sent = WinHttpSendRequest(
        request,
        WINHTTP_NO_ADDITIONAL_HEADERS,
        0,
        const_cast<char*>(body.data()),
        static_cast<DWORD>(body.size()),
        static_cast<DWORD>(body.size()),
        0);
    if (!sent || !WinHttpReceiveResponse(request, nullptr)) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    DWORD status = 0;
    DWORD status_size = sizeof status;
    WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &status,
        &status_size,
        WINHTTP_NO_HEADER_INDEX);
    if (status != 200) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        if (err) *err = "embedding provider is unavailable: status " + std::to_string(status);
        return false;
    }
    DWORD ctype_len = 0;
    WinHttpQueryHeaders(
        request, WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &ctype_len, WINHTTP_NO_HEADER_INDEX);
    std::string ctype;
    if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && ctype_len > 0) {
        std::wstring wc(ctype_len / sizeof(wchar_t), L'\0');
        if (WinHttpQueryHeaders(
                request,
                WINHTTP_QUERY_CONTENT_TYPE,
                WINHTTP_HEADER_NAME_BY_INDEX,
                wc.data(),
                &ctype_len,
                WINHTTP_NO_HEADER_INDEX)) {
            std::string dummy;
            wc.resize(wc.find(L'\0') == std::wstring::npos ? wc.size() : wc.find(L'\0'));
            ctype = wide_to_utf8(wc, &dummy);
        }
    }
    if (media_type(ctype) != "application/json") {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    std::string resp;
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail)) break;
        if (avail == 0) break;
        if (resp.size() + avail > static_cast<size_t>(kMaxEmbeddingResponseBytes) + 1) {
            avail = static_cast<DWORD>(
                (static_cast<size_t>(kMaxEmbeddingResponseBytes) + 1) - resp.size());
            if (avail == 0) break;
        }
        std::string chunk(avail, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(request, chunk.data(), avail, &read) || read == 0) break;
        resp.append(chunk.data(), read);
        if (resp.size() > static_cast<size_t>(kMaxEmbeddingResponseBytes)) break;
    }
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    if (resp.empty() || resp.size() > static_cast<size_t>(kMaxEmbeddingResponseBytes)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    Json root;
    std::string perr;
    if (!parse_json(resp, &root, &perr) || !json_is_object(root)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    const char* kRoot[] = {"object", "data", "model", "usage", nullptr};
    if (!json_reject_unknown_keys(root, kRoot, &perr)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    std::string object, model;
    if (!json_string(root, "object", &object) || object != "list" ||
        !json_string(root, "model", &model) || model != runtime.model) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    const Json* data = json_get(root, "data");
    if (data == nullptr || data->kind != Json::Kind::Array || data->arr.size() != 1 ||
        !json_is_object(data->arr[0])) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    const char* kData[] = {"object", "embedding", "index", nullptr};
    if (!json_reject_unknown_keys(data->arr[0], kData, &perr)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    std::string dobj;
    double index = 0;
    if (!json_string(data->arr[0], "object", &dobj) || dobj != "embedding" ||
        !json_number(data->arr[0], "index", &index) || index != 0) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    const Json* usage = json_get(root, "usage");
    if (usage != nullptr) {
        if (!json_is_object(*usage)) {
            if (err) *err = "embedding provider returned an invalid response";
            return false;
        }
        const char* kUsage[] = {"prompt_tokens", "total_tokens", nullptr};
        if (!json_reject_unknown_keys(*usage, kUsage, &perr)) {
            if (err) *err = "embedding provider returned an invalid response";
            return false;
        }
    }
    const Json* emb = json_get(data->arr[0], "embedding");
    if (emb == nullptr || emb->kind != Json::Kind::Array ||
        static_cast<int>(emb->arr.size()) != runtime.identity.dimension) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    std::vector<float> out;
    out.reserve(emb->arr.size());
    for (const Json& n : emb->arr) {
        if (n.kind != Json::Kind::Number || !std::isfinite(n.number)) {
            if (err) *err = "embedding provider returned an invalid response";
            return false;
        }
        float f = static_cast<float>(n.number);
        if (!std::isfinite(static_cast<double>(f))) {
            if (err) *err = "embedding provider returned an invalid response";
            return false;
        }
        out.push_back(f);
    }
    if (!valid_embedding_vector(out, runtime.identity.dimension)) {
        if (err) *err = "embedding provider returned an invalid response";
        return false;
    }
    *vector = std::move(out);
    return true;
}
#endif

bool embedding_embed(
    const EmbeddingRuntime& runtime, const std::string& content, std::vector<float>* vector, std::string* err) {
    if (!runtime.configured) {
        if (err) *err = "embedding provider is unavailable";
        return false;
    }
    std::string normalized, hash;
    if (!normalize_embedding_input(content, &normalized, &hash, err)) return false;
    if (normalized.empty()) {
        if (err) *err = "embedding provider returned an invalid response: empty normalized input";
        return false;
    }
#if defined(_WIN32)
    return http_embed(runtime, normalized, vector, err);
#else
    (void)vector;
    if (err) *err = "embedding HTTP requires Windows";
    return false;
#endif
}

int run_embedding_self_test() {
    int failed = 0;
    auto check = [&](bool ok, const char* name) {
        if (!ok) {
            std::fprintf(stderr, "FAIL embedding %s\n", name);
            ++failed;
        }
    };
    std::string err, canonical, host;
    uint16_t port = 0;
    check(!embedding_endpoint_canonical("http://localhost:8080/v1/embeddings", &canonical, &host, &port, &err),
          "reject-localhost");
    err.clear();
    check(!embedding_endpoint_canonical("https://127.0.0.1:8080/v1/embeddings", &canonical, &host, &port, &err),
          "reject-https");
    err.clear();
    check(!embedding_endpoint_canonical("http://127.0.0.1:8080/v1/embeddings?x=1", &canonical, &host, &port, &err),
          "reject-query");
    err.clear();
    check(embedding_endpoint_canonical("http://127.0.0.1:11434/v1/embeddings", &canonical, &host, &port, &err) &&
              port == 11434 && host == "127.0.0.1",
          "accept-loopback");

    std::string norm, hash;
    err.clear();
    check(normalize_embedding_input("  normalized   input  ", &norm, &hash, &err) && norm == "normalized input" &&
              hash.size() == 64,
          "normalize-fields");
    std::string norm2, hash2;
    check(normalize_embedding_input("normalized input", &norm2, &hash2, &err) && hash == hash2, "normalize-stable-hash");

    std::vector<float> left, right, unrelated, again;
    check(embedding_embed_fake(32, "bearer authentication", &left, &err), "fake-left");
    check(embedding_embed_fake(32, "credential authorization", &right, &err), "fake-right");
    check(embedding_embed_fake(32, "database storage", &unrelated, &err), "fake-unrelated");
    check(embedding_embed_fake(32, "bearer authentication", &again, &err) && left == again, "fake-stable");
    double alias = 0, unrelated_score = 0;
    check(embedding_cosine(left, right, &alias) && embedding_cosine(left, unrelated, &unrelated_score) &&
              left.size() == 32 && alias > unrelated_score,
          "fake-alias");
    check(!valid_embedding_vector(std::vector<float>(3, 0.0f), 3), "reject-zero-vector");
    EmbeddingIdentity bad = embedding_fake_identity(32);
    bad.provider_kind = "openai";
    check(!embedding_identity_valid(bad, &err), "reject-provider-kind");
    return failed;
}

}  // namespace godbrain::memory
