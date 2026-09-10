#include "godbrain/memory_store/embedding.hpp"
#include "godbrain/memory_store/json.hpp"

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
#endif

namespace {

using godbrain::memory::Json;
using godbrain::memory::embedding_cosine;
using godbrain::memory::embedding_embed_fake;
using godbrain::memory::json_bool;
using godbrain::memory::json_get;
using godbrain::memory::json_number;
using godbrain::memory::json_string;
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

int percentile(std::vector<int> v, int p) {
    std::sort(v.begin(), v.end());
    int idx = (static_cast<int>(v.size()) * p + 99) / 100;
    if (idx < 1) idx = 1;
    return v[static_cast<size_t>(idx - 1)];
}

}  // namespace

int main(int argc, char** argv) {
    std::string corpus_path = "godbrain_core/memory_store/rag/testdata/hybrid_eval_corpus.json";
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-corpus" && i + 1 < argc) corpus_path = argv[++i];
        else if (a == "-live") {
            std::cerr << "C++ rag-eval live desk is not in this cut; use Go rag-eval.exe -live\n";
            return 1;
        }
    }
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
