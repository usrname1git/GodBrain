#include "godbrain/memory_store/embedding.hpp"
#include "godbrain/memory_store/json.hpp"
#include "godbrain/memory_store/protocol.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")
#endif

namespace {

using godbrain::memory::Json;
using godbrain::memory::embedding_cosine;
using godbrain::memory::embedding_embed_fake;
using godbrain::memory::json_bool;
using godbrain::memory::json_get;
using godbrain::memory::json_is_object;
using godbrain::memory::json_number;
using godbrain::memory::json_reject_unknown_keys;
using godbrain::memory::json_string;
using godbrain::memory::json_escape;
using godbrain::memory::parse_json;

constexpr const char* kCorpusVersion = "godbrain-hybrid-eval-v1";
constexpr double kMinSemantic = 0.20;
constexpr int kFakeDim = 64;

struct EvalDoc {
    std::string id, stable_id, version, content, kind, sector, status, source_id, generation, citation_state;
    double confidence = 0;
    bool committed = false;
    bool expected_visible = false;
    bool prompt_injection = false;
};

struct EvalQuery {
    std::string id, text, kind, sector, status;
    std::vector<std::string> relevant;
    bool expect_no_results = false;
};

struct EvalCorpus {
    std::string version, active_generation;
    int top_k = 0;
    std::vector<EvalDoc> documents;
    std::vector<EvalQuery> queries;
};

std::string read_file(const std::string& path, std::string* err) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        *err = "cannot read " + path;
        return "";
    }
    std::ostringstream o;
    o << in.rdbuf();
    return o.str();
}

std::vector<std::string> tokens_of(const std::string& text) {
    std::string lower;
    lower.reserve(text.size());
    for (unsigned char c : text) {
        if (std::isalnum(c)) lower.push_back(static_cast<char>(std::tolower(c)));
        else lower.push_back(' ');
    }
    std::vector<std::string> tok;
    std::string cur;
    std::set<std::string> seen;
    for (char c : lower) {
        if (c == ' ') {
            if (!cur.empty() && seen.insert(cur).second) tok.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    if (!cur.empty() && seen.insert(cur).second) tok.push_back(cur);
    return tok;
}

double token_overlap(const std::vector<std::string>& left, const std::vector<std::string>& right) {
    std::set<std::string> rs(right.begin(), right.end());
    int n = 0;
    for (const auto& t : left) {
        if (rs.count(t)) ++n;
    }
    return static_cast<double>(n);
}

double rrf(int rank) {
    if (rank <= 0) return 0;
    return 1.0 / (60.0 + static_cast<double>(rank));
}

double eval_trust(const std::string& status) {
    if (status == "verified") return 1;
    if (status == "candidate") return 0.25;
    if (status == "rejected") return -1;
    return 0;
}

bool load_corpus(const Json& root, EvalCorpus* c, std::string* err) {
    json_string(root, "version", &c->version);
    json_string(root, "active_generation", &c->active_generation);
    double tk = 0;
    json_number(root, "top_k", &tk);
    c->top_k = static_cast<int>(tk);
    if (c->version != kCorpusVersion || c->active_generation.empty() || c->top_k < 1 || c->top_k > 25) {
        *err = "evaluation corpus metadata is invalid";
        return false;
    }
    const Json* docs = json_get(root, "documents");
    const Json* qs = json_get(root, "queries");
    if (docs == nullptr || docs->kind != Json::Kind::Array || qs == nullptr || qs->kind != Json::Kind::Array) {
        *err = "evaluation corpus metadata is invalid";
        return false;
    }
    bool uncommitted = false, stale = false, missing = false, wrong = false;
    for (const Json& d : docs->arr) {
        if (d.kind != Json::Kind::Object) continue;
        EvalDoc doc;
        json_string(d, "id", &doc.id);
        json_string(d, "stable_id", &doc.stable_id);
        json_string(d, "version", &doc.version);
        json_string(d, "content", &doc.content);
        json_string(d, "kind", &doc.kind);
        json_string(d, "sector", &doc.sector);
        json_string(d, "status", &doc.status);
        json_string(d, "source_id", &doc.source_id);
        json_string(d, "generation", &doc.generation);
        json_string(d, "citation_state", &doc.citation_state);
        json_number(d, "confidence", &doc.confidence);
        json_bool(d, "committed", &doc.committed);
        json_bool(d, "expected_visible", &doc.expected_visible);
        json_bool(d, "prompt_injection", &doc.prompt_injection);
        if (doc.id.empty() || doc.stable_id.empty() || doc.content.empty() || doc.generation.empty() ||
            doc.confidence < 0 || doc.confidence > 1) {
            *err = "evaluation document is invalid";
            return false;
        }
        if (doc.citation_state == "missing") missing = true;
        else if (doc.citation_state == "wrong") wrong = true;
        else if (doc.citation_state != "valid") {
            *err = "evaluation document citation_state is invalid";
            return false;
        }
        uncommitted = uncommitted || !doc.committed;
        stale = stale || doc.generation != c->active_generation;
        c->documents.push_back(std::move(doc));
    }
    for (const Json& q : qs->arr) {
        if (q.kind != Json::Kind::Object) continue;
        EvalQuery eq;
        json_string(q, "id", &eq.id);
        json_string(q, "text", &eq.text);
        json_string(q, "kind", &eq.kind);
        json_string(q, "sector", &eq.sector);
        json_string(q, "status", &eq.status);
        json_bool(q, "expect_no_results", &eq.expect_no_results);
        const Json* rel = json_get(q, "relevant_ids");
        if (rel && rel->kind == Json::Kind::Array) {
            for (const Json& id : rel->arr) {
                if (id.kind == Json::Kind::String) eq.relevant.push_back(id.str);
            }
        }
        c->queries.push_back(std::move(eq));
    }
    if (c->documents.empty() || c->queries.empty() || !uncommitted || !stale || !missing || !wrong) {
        *err = "evaluation corpus is missing required boundary probes";
        return false;
    }
    return true;
}

struct Candidate {
    EvalDoc document;
    double lexical = 0;
    double vector = 0;
    int lexical_rank = 0;
    int semantic_rank = 0;
    double fusion = 0;
};

std::vector<EvalDoc> evaluate_query(
    const EvalCorpus& corpus, const EvalQuery& query,
    const std::map<std::string, std::vector<float>>& vectors, int* work) {
    *work = static_cast<int>(corpus.documents.size()) * 2;
    auto qtok = tokens_of(query.text);
    std::vector<float> qv;
    std::string eerr;
    if (!embedding_embed_fake(kFakeDim, query.text, &qv, &eerr)) return {};
    std::vector<Candidate> cands;
    for (const EvalDoc& d : corpus.documents) {
        if (!query.kind.empty() && d.kind != query.kind) continue;
        if (!query.sector.empty() && d.sector != query.sector) continue;
        if (!query.status.empty() && d.status != query.status) continue;
        if (!d.committed || d.generation != corpus.active_generation) continue;
        auto it = vectors.find(d.id);
        if (it == vectors.end()) continue;
        double sim = 0;
        if (!embedding_cosine(qv, it->second, &sim)) continue;
        Candidate c;
        c.document = d;
        c.lexical = token_overlap(qtok, tokens_of(d.content));
        c.vector = sim;
        cands.push_back(std::move(c));
    }
    auto by_lex = cands;
    std::sort(by_lex.begin(), by_lex.end(), [](const Candidate& a, const Candidate& b) {
        if (a.lexical != b.lexical) return a.lexical > b.lexical;
        return a.document.id < b.document.id;
    });
    int rank = 0;
    std::map<std::string, int> lex_rank;
    for (const Candidate& c : by_lex) {
        if (c.lexical <= 0) continue;
        ++rank;
        lex_rank[c.document.id] = rank;
    }
    auto by_sem = cands;
    std::sort(by_sem.begin(), by_sem.end(), [](const Candidate& a, const Candidate& b) {
        if (a.vector != b.vector) return a.vector > b.vector;
        return a.document.id < b.document.id;
    });
    rank = 0;
    std::map<std::string, int> sem_rank;
    for (const Candidate& c : by_sem) {
        if (c.vector < kMinSemantic) continue;
        ++rank;
        sem_rank[c.document.id] = rank;
    }
    std::vector<Candidate> fused;
    for (Candidate c : cands) {
        c.lexical_rank = lex_rank[c.document.id];
        c.semantic_rank = sem_rank[c.document.id];
        if (c.lexical_rank == 0 && c.semantic_rank == 0) continue;
        c.fusion = rrf(c.lexical_rank) + rrf(c.semantic_rank) + eval_trust(c.document.status) * 0.001 +
                   c.document.confidence * 0.001;
        fused.push_back(std::move(c));
    }
    std::sort(fused.begin(), fused.end(), [](const Candidate& a, const Candidate& b) {
        if (a.fusion != b.fusion) return a.fusion > b.fusion;
        if (a.document.stable_id != b.document.stable_id) return a.document.stable_id < b.document.stable_id;
        return a.document.id < b.document.id;
    });
    std::vector<EvalDoc> selected;
    std::set<std::string> seen_stable;
    std::map<std::string, int> source_uses;
    for (const Candidate& c : fused) {
        if (static_cast<int>(selected.size()) >= corpus.top_k) break;
        if (seen_stable.count(c.document.stable_id)) continue;
        if (source_uses[c.document.source_id] >= 2) continue;
        seen_stable.insert(c.document.stable_id);
        source_uses[c.document.source_id]++;
        selected.push_back(c.document);
    }
    std::vector<EvalDoc> results;
    for (const EvalDoc& d : selected) {
        if (d.citation_state == "valid") results.push_back(d);
    }
    return results;
}

bool loopback_http(const wchar_t* host, uint16_t port, const wchar_t* verb, const wchar_t* path,
                   const std::string& body, int* status, std::string* resp, std::string* err) {
#if !defined(_WIN32)
    *err = "live eval requires WinHTTP";
    return false;
#else
    HINTERNET session = WinHttpOpen(L"godbrain-rag-eval", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
    if (session == nullptr) {
        *err = "WinHttpOpen failed";
        return false;
    }
    WinHttpSetTimeouts(session, 500, 500, 8000, 8000);
    DWORD disable = WINHTTP_DISABLE_REDIRECTS;
    WinHttpSetOption(session, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof disable);
    HINTERNET connect = WinHttpConnect(session, host, port, 0);
    if (connect == nullptr) {
        WinHttpCloseHandle(session);
        *err = "connect failed";
        return false;
    }
    HINTERNET request = WinHttpOpenRequest(connect, verb, path, nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                           0);
    if (request == nullptr) {
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        *err = "open request failed";
        return false;
    }
    BOOL sent = FALSE;
    if (body.empty()) {
        sent = WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    } else {
        WinHttpAddRequestHeaders(request, L"Content-Type: application/json\r\n", (ULONG)-1, WINHTTP_ADDREQ_FLAG_ADD);
        sent = WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                  (LPVOID)body.data(), static_cast<DWORD>(body.size()), static_cast<DWORD>(body.size()), 0);
    }
    if (!sent || !WinHttpReceiveResponse(request, nullptr)) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        *err = "request failed";
        return false;
    }
    DWORD code = 0;
    DWORD clen = sizeof code;
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code,
                        &clen, WINHTTP_NO_HEADER_INDEX);
    *status = static_cast<int>(code);
    std::string out;
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail) || avail == 0) break;
        if (out.size() + avail > 64 * 1024) avail = static_cast<DWORD>(64 * 1024 - out.size());
        if (avail == 0) break;
        std::string chunk(avail, '\0');
        DWORD got = 0;
        if (!WinHttpReadData(request, chunk.data(), avail, &got) || got == 0) break;
        out.append(chunk.data(), got);
        if (out.size() >= 64 * 1024) break;
    }
    *resp = std::move(out);
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    return true;
#endif
}

std::string ascii_lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string trim_copy(const std::string& s) {
    size_t a = 0;
    size_t b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a])) != 0) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1])) != 0) --b;
    return s.substr(a, b - a);
}

int utf8_runes(const std::string& s) {
    int n = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if ((c & 0x80) == 0) i += 1;
        else if ((c & 0xE0) == 0xC0) i += 2;
        else if ((c & 0xF0) == 0xE0) i += 3;
        else i += 4;
        if (i > s.size()) break;
        ++n;
    }
    return n;
}

std::vector<std::string> match_needles(const std::string& text, const std::vector<std::string>& needles) {
    std::string lower = ascii_lower(text);
    std::vector<std::string> matched;
    std::set<std::string> seen;
    for (const std::string& n : needles) {
        std::string key = ascii_lower(n);
        if (seen.count(key)) continue;
        if (lower.find(key) != std::string::npos) {
            matched.push_back(n);
            seen.insert(key);
        }
    }
    return matched;
}

bool live_origin_ok(const std::string& origin) {
    return origin == "http://127.0.0.1:8084" || origin == "http://localhost:8084";
}

struct DeskQuery {
    std::string id, query, sector;
    std::vector<std::string> needles;
};

struct DeskFile {
    std::string version;
    int top_k = 0;
    std::vector<DeskQuery> queries;
};

bool decode_desk_eval(const std::string& raw, DeskFile* out, std::string* err) {
    *out = DeskFile{};
    Json root;
    if (!parse_json(raw, &root, err) || !json_is_object(root)) {
        if (err && err->empty()) *err = "desk evaluation file must contain exactly one JSON document";
        return false;
    }
    const char* root_keys[] = {"version", "top_k", "queries", nullptr};
    if (!json_reject_unknown_keys(root, root_keys, err)) {
        if (err) *err = "desk evaluation file has unknown field";
        return false;
    }
    json_string(root, "version", &out->version);
    double topkd = 0;
    if (!json_number(root, "top_k", &topkd)) {
        if (err) *err = "desk evaluation top_k is invalid";
        return false;
    }
    out->top_k = static_cast<int>(topkd);
    if (out->version != "godbrain-desk-eval-v1") {
        if (err) *err = "desk evaluation version is invalid";
        return false;
    }
    if (out->top_k < 1 || out->top_k > 25) {
        if (err) *err = "desk evaluation top_k is invalid";
        return false;
    }
    const Json* qs = json_get(root, "queries");
    if (qs == nullptr || qs->kind != Json::Kind::Array || qs->arr.empty() || qs->arr.size() > 50) {
        if (err) *err = "desk evaluation query count is invalid";
        return false;
    }
    const char* qkeys[] = {"id", "query", "needles", "sector", nullptr};
    std::set<std::string> seen;
    for (const Json& q : qs->arr) {
        if (!json_is_object(q) || !json_reject_unknown_keys(q, qkeys, err)) {
            if (err) *err = "desk evaluation query is invalid";
            return false;
        }
        DeskQuery dq;
        json_string(q, "id", &dq.id);
        json_string(q, "query", &dq.query);
        json_string(q, "sector", &dq.sector);
        dq.id = trim_copy(dq.id);
        dq.query = trim_copy(dq.query);
        dq.sector = trim_copy(dq.sector);
        if (dq.id.empty() || dq.id.size() > 64) {
            if (err) *err = "desk evaluation query id is invalid";
            return false;
        }
        if (!seen.insert(dq.id).second) {
            if (err) *err = "desk evaluation query id is duplicated";
            return false;
        }
        if (dq.query.empty() || utf8_runes(dq.query) > 256) {
            if (err) *err = "desk evaluation query text is invalid";
            return false;
        }
        const Json* ns = json_get(q, "needles");
        if (ns == nullptr || ns->kind != Json::Kind::Array || ns->arr.empty() || ns->arr.size() > 8) {
            if (err) *err = "desk evaluation needles are invalid";
            return false;
        }
        for (const Json& n : ns->arr) {
            if (n.kind != Json::Kind::String) {
                if (err) *err = "desk evaluation needle is invalid";
                return false;
            }
            std::string needle = trim_copy(n.str);
            if (needle.empty() || utf8_runes(needle) > 64) {
                if (err) *err = "desk evaluation needle is invalid";
                return false;
            }
            dq.needles.push_back(std::move(needle));
        }
        out->queries.push_back(std::move(dq));
    }
    return true;
}

int run_eval_self_test() {
    int failed = 0;
    auto check = [&](bool ok, const char* name) {
        if (!ok) {
            std::fprintf(stderr, "FAIL %s\n", name);
            ++failed;
        }
    };
    const char* good =
        "{\"version\":\"godbrain-desk-eval-v1\",\"top_k\":8,\"queries\":["
        "{\"id\":\"heal-never-kills\",\"query\":\"Heal never kills\",\"needles\":[\"Heal\",\"Watch\"],"
        "\"sector\":\"windows-sre\"}]}";
    DeskFile file;
    std::string err;
    check(decode_desk_eval(good, &file, &err) && file.queries.size() == 1 && file.queries[0].id == "heal-never-kills",
          "desk-ok");
    file = {};
    err.clear();
    const char* extra =
        "{\"extra\":true,\"version\":\"godbrain-desk-eval-v1\",\"top_k\":8,\"queries\":["
        "{\"id\":\"heal-never-kills\",\"query\":\"Heal never kills\",\"needles\":[\"Heal\"]}]}";
    check(!decode_desk_eval(extra, &file, &err), "desk-unknown");
    file = {};
    err.clear();
    const char* dup =
        "{\"version\":\"godbrain-desk-eval-v1\",\"top_k\":8,\"queries\":["
        "{\"id\":\"heal-never-kills\",\"query\":\"Heal never kills\",\"needles\":[\"Heal\"]},"
        "{\"id\":\"heal-never-kills\",\"query\":\"Watch never kills\",\"needles\":[\"Watch\"]}]}";
    check(!decode_desk_eval(dup, &file, &err), "desk-dup-id");
    file = {};
    err.clear();
    const char* noneedle =
        "{\"version\":\"godbrain-desk-eval-v1\",\"top_k\":8,\"queries\":["
        "{\"id\":\"heal-never-kills\",\"query\":\"Heal never kills\",\"needles\":[]}]}";
    check(!decode_desk_eval(noneedle, &file, &err), "desk-needles");
    check(live_origin_ok("http://127.0.0.1:8084") && live_origin_ok("http://localhost:8084") &&
              !live_origin_ok("http://127.0.0.1:8083") && !live_origin_ok("https://127.0.0.1:8084"),
          "live-origin");
    auto needles = match_needles("Heal Watch never kills", {"Heal", "missing"});
    check(needles.size() == 1 && needles[0] == "Heal", "needles");
    if (failed == 0) std::fprintf(stderr, "cpp rag-eval self-test ok\n");
    return failed == 0 ? 0 : 1;
}

int run_live(const std::string& desk_path, const std::string& origin, bool strict) {
    std::string o = origin;
    while (!o.empty() && (o.back() == '/' || o.back() == '\\')) o.pop_back();
    if (!live_origin_ok(o)) {
        std::cerr << "RAG evaluation failed: live eval is loopback-only, got \"" << origin << "\"\n";
        return 1;
    }
    std::string err;
    std::string raw = read_file(desk_path, &err);
    if (raw.empty()) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    DeskFile file;
    if (!decode_desk_eval(raw, &file, &err)) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    int status = 0;
    std::string health_body;
    if (!loopback_http(L"127.0.0.1", 8084, L"GET", L"/health", "", &status, &health_body, &err)) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    Json health;
    bool ready = false;
    if (status == 200 && parse_json(health_body, &health, &err)) json_bool(health, "ready", &ready);
    if (!ready) {
        std::cerr << "RAG evaluation failed: RAG " << o << " is unready\n";
        return 1;
    }
    int hits = 0, misses = 0, empty = 0;
    std::ostringstream report;
    report << "{\n  \"version\": \"godbrain-desk-eval-v1\",\n  \"endpoint\": \"" << o
           << "/v1/search\",\n  \"ready\": true,\n  \"query_count\": " << file.queries.size()
           << ",\n  \"queries\": [\n";
    for (size_t i = 0; i < file.queries.size(); ++i) {
        const DeskQuery& q = file.queries[i];
        std::ostringstream body;
        body << "{\"query\":\"" << json_escape(q.query) << "\",\"top_k\":" << file.top_k
             << ",\"status\":\"verified\"";
        if (!q.sector.empty()) body << ",\"sector\":\"" << json_escape(q.sector) << "\"";
        body << "}";
        int sc = 0;
        std::string resp;
        std::string qerr;
        bool hit = false;
        int count = 0;
        std::string snippet;
        std::string error;
        std::vector<std::string> matched;
        if (!loopback_http(L"127.0.0.1", 8084, L"POST", L"/v1/search", body.str(), &sc, &resp, &qerr)) {
            error = qerr;
            ++misses;
        } else if (sc != 200) {
            error = "status " + std::to_string(sc);
            ++misses;
        } else {
            Json search;
            if (!parse_json(resp, &search, &qerr) || search.kind != Json::Kind::Object) {
                error = "invalid search response";
                ++misses;
            } else {
                const Json* results = json_get(search, "results");
                if (results && results->kind == Json::Kind::Array) {
                    count = static_cast<int>(results->arr.size());
                    std::string combined;
                    for (const Json& r : results->arr) {
                        std::string snip, sid;
                        json_string(r, "snippet", &snip);
                        json_string(r, "stable_id", &sid);
                        combined += snip;
                        combined.push_back('\n');
                        combined += sid;
                        combined.push_back('\n');
                        if (snippet.empty()) snippet = snip.size() > 160 ? snip.substr(0, 160) : snip;
                    }
                    if (count == 0) {
                        ++empty;
                        ++misses;
                    } else {
                        matched = match_needles(combined, q.needles);
                        hit = !matched.empty();
                        if (hit) ++hits;
                        else ++misses;
                    }
                } else {
                    ++empty;
                    ++misses;
                }
            }
        }
        if (i) report << ",\n";
        report << "    {\"id\":\"" << json_escape(q.id) << "\",\"query\":\"" << json_escape(q.query)
               << "\",\"hit\":" << (hit ? "true" : "false") << ",\"count\":" << count;
        if (!matched.empty()) {
            report << ",\"matched_needles\":[";
            for (size_t m = 0; m < matched.size(); ++m) {
                if (m) report << ",";
                report << "\"" << json_escape(matched[m]) << "\"";
            }
            report << "]";
        }
        if (!snippet.empty()) report << ",\"snippet\":\"" << json_escape(snippet) << "\"";
        if (!error.empty()) report << ",\"error\":\"" << json_escape(error) << "\"";
        report << "}";
    }
    report << "\n  ],\n  \"hits\": " << hits << ",\n  \"misses\": " << misses << ",\n  \"empty\": " << empty << "\n}\n";
    std::cout << report.str();
    if (hits == 0) {
        std::cerr << "RAG evaluation failed: live desk eval: RAG ready but zero needle hits\n";
        return 1;
    }
    if (strict && misses > 0) {
        std::cerr << "RAG evaluation failed: live desk eval: " << misses << " miss(es) under -strict\n";
        return 1;
    }
    return 0;
}

int percentile(std::vector<int> v, int p) {
    std::sort(v.begin(), v.end());
    int idx = (static_cast<int>(v.size()) * p + 99) / 100;
    if (idx < 1) idx = 1;
    return v[static_cast<size_t>(idx - 1)];
}

}  // namespace

int main(int argc, char** argv) {
    std::string corpus_path = "godbrain_core/memory_store/rag/testdata/hybrid_eval_corpus.json";
    std::string desk_path = "godbrain_core/memory_store/rag/testdata/desk_eval_queries.json";
    std::string endpoint = "http://127.0.0.1:8084";
    bool live = false;
    bool strict = false;
    bool self_test = false;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-corpus" && i + 1 < argc) corpus_path = argv[++i];
        else if (a == "-desk" && i + 1 < argc) desk_path = argv[++i];
        else if (a == "-endpoint" && i + 1 < argc) endpoint = argv[++i];
        else if (a == "-live") live = true;
        else if (a == "-strict") strict = true;
        else if (a == "-self-test" || a == "--self-test") self_test = true;
    }
    if (self_test) return run_eval_self_test();
    if (live) return run_live(desk_path, endpoint, strict);
    std::string err;
    std::string raw = read_file(corpus_path, &err);
    if (raw.empty()) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    Json root;
    if (!parse_json(raw, &root, &err) || root.kind != Json::Kind::Object) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    EvalCorpus corpus;
    if (!load_corpus(root, &corpus, &err)) {
        std::cerr << "RAG evaluation failed: " << err << "\n";
        return 1;
    }
    std::map<std::string, std::vector<float>> vectors;
    std::set<std::string> hidden;
    for (const EvalDoc& d : corpus.documents) {
        if (!d.expected_visible) hidden.insert(d.id);
        std::vector<float> v;
        if (!embedding_embed_fake(kFakeDim, d.content, &v, &err)) {
            std::cerr << "RAG evaluation failed: " << err << "\n";
            return 1;
        }
        vectors[d.id] = std::move(v);
    }
    double recall = 0, mrr = 0, ndcg = 0;
    int returned = 0, valid_cite = 0, cited = 0, gen_ok = 0, leak = 0;
    int no_total = 0, no_ok = 0;
    bool prompt_seen = false;
    std::vector<int> work_units;
    std::ostringstream queries_json;
    queries_json << "[";
    for (size_t qi = 0; qi < corpus.queries.size(); ++qi) {
        const EvalQuery& q = corpus.queries[qi];
        int work = 0;
        auto results = evaluate_query(corpus, q, vectors, &work);
        work_units.push_back(work);
        std::set<std::string> relevant(q.relevant.begin(), q.relevant.end());
        int hits = 0;
        double dcg = 0;
        double rr = 0;
        if (qi) queries_json << ",";
        queries_json << "{\"id\":\"" << q.id << "\",\"returned_ids\":[";
        for (size_t i = 0; i < results.size(); ++i) {
            if (i) queries_json << ",";
            queries_json << "\"" << results[i].id << "\"";
            if (relevant.count(results[i].id)) {
                ++hits;
                if (rr == 0) rr = 1.0 / static_cast<double>(i + 1);
                dcg += 1.0 / std::log2(static_cast<double>(i) + 2.0);
            }
            ++returned;
            if (results[i].citation_state == "valid") {
                ++valid_cite;
                ++cited;
            }
            if (results[i].generation == corpus.active_generation) ++gen_ok;
            if (hidden.count(results[i].id)) ++leak;
            if (results[i].prompt_injection) prompt_seen = true;
        }
        queries_json << "]";
        double rec = 0, nd = 0;
        if (relevant.empty()) {
            if (results.empty()) {
                rec = 1;
                rr = 1;
                nd = 1;
            }
        } else {
            rec = static_cast<double>(hits) / static_cast<double>(relevant.size());
            int ideal_n = static_cast<int>(relevant.size());
            if (ideal_n > corpus.top_k) ideal_n = corpus.top_k;
            double ideal = 0;
            for (int i = 0; i < ideal_n; ++i) ideal += 1.0 / std::log2(static_cast<double>(i) + 2.0);
            if (ideal > 0) nd = dcg / ideal;
        }
        recall += rec;
        mrr += rr;
        ndcg += nd;
        if (q.expect_no_results) {
            ++no_total;
            if (results.empty()) ++no_ok;
        }
        queries_json << ",\"recall_at_k\":" << rec << ",\"reciprocal_rank\":" << rr << ",\"ndcg_at_k\":" << nd
                     << ",\"work_units\":" << work << "}";
    }
    queries_json << "]";
    double nq = static_cast<double>(corpus.queries.size());
    recall /= nq;
    mrr /= nq;
    ndcg /= nq;
    double cite_corr = returned ? static_cast<double>(valid_cite) / static_cast<double>(returned) : 1;
    double cite_cov = returned ? static_cast<double>(cited) / static_cast<double>(returned) : 1;
    double gen_corr = returned ? static_cast<double>(gen_ok) / static_cast<double>(returned) : 1;
    double no_corr = no_total ? static_cast<double>(no_ok) / static_cast<double>(no_total) : 1;
    int budget = static_cast<int>(corpus.documents.size()) * 2;
    int p50 = percentile(work_units, 50);
    int p95 = percentile(work_units, 95);
    int mx = *std::max_element(work_units.begin(), work_units.end());
    bool budget_pass = mx <= budget;
    bool ok = recall >= 0.90 && mrr >= 0.90 && ndcg >= 0.90 && cite_corr == 1 && cite_cov == 1 && leak == 0 &&
              gen_corr == 1 && no_corr == 1 && prompt_seen && budget_pass;
    std::ostringstream o;
    o << "{\n  \"corpus_version\": \"" << kCorpusVersion << "\",\n"
      << "  \"provider_kind\": \"deterministic-test-fake\",\n"
      << "  \"model_identifier\": \"godbrain-eval-fake\",\n"
      << "  \"query_count\": " << corpus.queries.size() << ",\n"
      << "  \"recall_at_k\": " << recall << ",\n"
      << "  \"mrr\": " << mrr << ",\n"
      << "  \"ndcg_at_k\": " << ndcg << ",\n"
      << "  \"citation_correctness\": " << cite_corr << ",\n"
      << "  \"citation_coverage\": " << cite_cov << ",\n"
      << "  \"hidden_record_leakage\": " << leak << ",\n"
      << "  \"generation_correctness\": " << gen_corr << ",\n"
      << "  \"no_result_correctness\": " << no_corr << ",\n"
      << "  \"prompt_injection_as_data\": " << (prompt_seen ? "true" : "false") << ",\n"
      << "  \"deterministic_latency\": {\"unit\":\"bounded_document_comparisons\",\"p50\":" << p50 << ",\"p95\":" << p95
      << ",\"maximum\":" << mx << ",\"budget\":" << budget << ",\"budget_pass\":" << (budget_pass ? "true" : "false")
      << "},\n"
      << "  \"queries\": " << queries_json.str() << "\n}\n";
    std::cout << o.str();
    if (!ok) {
        std::cerr << "RAG evaluation failed: thresholds not met "
                  << "Recall@K=" << recall << " MRR=" << mrr << " nDCG=" << ndcg << " leak=" << leak << "\n";
        return 1;
    }
    return 0;
}
