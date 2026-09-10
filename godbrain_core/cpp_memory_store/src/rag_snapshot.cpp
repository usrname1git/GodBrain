#include "godbrain/memory_store/snapshot.hpp"

#include <cstdio>
#include <vector>

namespace godbrain::memory {
namespace {

bool same_counts(const SearchHealthSnap& a, const SearchHealthSnap& b) {
    return a.committed_runs == b.committed_runs && a.committed_nodes == b.committed_nodes &&
           a.committed_links == b.committed_links && a.projected_nodes == b.projected_nodes &&
           a.projected_links == b.projected_links && a.projected_embeddings == b.projected_embeddings;
}

bool same_semantic(const SearchHealthSnap& a, const SearchHealthSnap& b) {
    if (a.semantic_configured != b.semantic_configured || a.semantic_available != b.semantic_available ||
        a.semantic_required != b.semantic_required || a.degradation != b.degradation) {
        return false;
    }
    if (a.has_embedding != b.has_embedding) return false;
    if (!a.has_embedding) return true;
    return embedding_identity_equal(a.embedding, b.embedding);
}

bool same_optional_millis(bool has_a, int64_t a, bool has_b, int64_t b) {
    if (has_a != has_b) return false;
    return !has_a || a == b;
}

bool valid_response_capability(
    const SearchHealthSnap& health,
    const std::string& retrieval,
    bool hybrid,
    const std::string& degradation,
    const EmbeddingIdentity* response_embedding) {
    if (retrieval == "lexical") return !hybrid && response_embedding == nullptr;
    if (retrieval == "hybrid") {
        return health.semantic_available && health.has_embedding && hybrid && degradation.empty() &&
               response_embedding != nullptr && embedding_identity_equal(health.embedding, *response_embedding);
    }
    return false;
}

SearchHealthSnap ready_health(const char* generation, int64_t nodes, int64_t links) {
    SearchHealthSnap h;
    h.ready = true;
    h.mongo = "ok";
    h.active_generation = generation;
    h.projection_version = "hybrid-v1";
    h.projection_schema = "rag-document-v2";
    h.indexer_version = "mongodb-text-v1";
    h.retrieval_mode = "lexical";
    h.degradation = "embedding_provider_disabled";
    h.committed_runs = nodes;
    h.committed_nodes = nodes;
    h.committed_links = links;
    h.projected_nodes = nodes;
    h.projected_links = links;
    return h;
}

struct Scripted {
    std::vector<SearchHealthSnap> healths;
    std::vector<std::string> snippets;
    std::string mode = "auto";
    std::string retrieval = "lexical";
    bool hybrid = false;
    std::string degradation = "embedding_provider_disabled";
};

struct Outcome {
    bool ok = false;
    bool semantic = false;
    std::string snippet;
    int health_calls = 0;
    int search_calls = 0;
};

Outcome run_scripted(const Scripted& sc) {
    Outcome o;
    size_t hi = 0;
    for (int attempt = 0; attempt < kMaxSearchAttempts; ++attempt) {
        if (hi >= sc.healths.size()) return o;
        const SearchHealthSnap& before = sc.healths[hi++];
        ++o.health_calls;
        const BeforeSearch gate = search_before_gate(before, sc.mode);
        if (gate == BeforeSearch::SemanticUnavailable) {
            o.semantic = true;
            return o;
        }
        if (gate != BeforeSearch::Proceed) return o;
        if (static_cast<size_t>(o.search_calls) >= sc.snippets.size()) return o;
        const std::string snip = sc.snippets[static_cast<size_t>(o.search_calls)];
        ++o.search_calls;
        if (hi >= sc.healths.size()) return o;
        const SearchHealthSnap& after = sc.healths[hi++];
        ++o.health_calls;
        const EmbeddingIdentity* emb = sc.hybrid ? &before.embedding : nullptr;
        if (search_after_gate(before, after, sc.retrieval, sc.hybrid, sc.degradation, emb) == AfterSearch::Accept) {
            o.ok = true;
            o.snippet = snip;
            return o;
        }
    }
    return o;
}

}  // namespace

BeforeSearch search_before_gate(const SearchHealthSnap& before, const std::string& requested_mode) {
    if (before.ready) return BeforeSearch::Proceed;
    if (requested_mode == "hybrid" && !before.semantic_available) return BeforeSearch::SemanticUnavailable;
    return BeforeSearch::Unready;
}

bool same_search_snapshot(
    const SearchHealthSnap& before,
    const SearchHealthSnap& after,
    const std::string& retrieval,
    bool hybrid,
    const std::string& degradation,
    const EmbeddingIdentity* response_embedding) {
    return before.ready && after.ready && before.mongo == "ok" && after.mongo == "ok" &&
           !before.active_generation.empty() && before.active_generation == after.active_generation &&
           before.building_generation == after.building_generation && !before.projection_version.empty() &&
           before.projection_version == after.projection_version &&
           before.projection_schema == after.projection_schema && before.indexer_version == after.indexer_version &&
           before.retrieval_mode == after.retrieval_mode && same_semantic(before, after) && same_counts(before, after) &&
           same_optional_millis(
               before.latest_committed, before.committed_at, after.latest_committed, after.committed_at) &&
           same_optional_millis(
               before.latest_projected, before.projected_at, after.latest_projected, after.projected_at) &&
           same_optional_millis(
               before.latest_embedded, before.embedded_at, after.latest_embedded, after.embedded_at) &&
           valid_response_capability(before, retrieval, hybrid, degradation, response_embedding);
}

AfterSearch search_after_gate(
    const SearchHealthSnap& before,
    const SearchHealthSnap& after,
    const std::string& retrieval,
    bool hybrid,
    const std::string& degradation,
    const EmbeddingIdentity* response_embedding) {
    if (same_search_snapshot(before, after, retrieval, hybrid, degradation, response_embedding)) {
        return AfterSearch::Accept;
    }
    return AfterSearch::Retry;
}

int run_snapshot_self_test() {
    int failed = 0;
    auto check = [&](bool ok, const char* name) {
        if (!ok) {
            std::fprintf(stderr, "FAIL %s\n", name);
            ++failed;
        }
    };

    const SearchHealthSnap stable = ready_health("generation-a", 1, 1);
    {
        Scripted sc;
        sc.healths = {stable, stable};
        sc.snippets = {""};
        const Outcome o = run_scripted(sc);
        check(o.ok && o.health_calls == 2 && o.search_calls == 1, "stable-snapshot");
    }

    {
        SearchHealthSnap partial = ready_health("generation-a", 2, 2);
        partial.projected_links = 1;
        partial.ready = false;
        Scripted sc;
        sc.healths = {stable, partial, partial};
        sc.snippets = {"partial projection must not escape"};
        const Outcome o = run_scripted(sc);
        check(!o.ok && o.search_calls == 1 && o.health_calls == 3 && o.snippet.empty(), "partial-interleave");
    }

    {
        const SearchHealthSnap older = ready_health("generation-a", 1, 1);
        const SearchHealthSnap newer = ready_health("generation-a", 2, 2);
        Scripted sc;
        sc.healths = {older, newer, newer, newer};
        sc.snippets = {"discard me", "return me"};
        const Outcome o = run_scripted(sc);
        check(o.ok && o.snippet == "return me" && o.health_calls == 4 && o.search_calls == 2, "retry-fresh");
    }

    {
        const SearchHealthSnap a = ready_health("generation-a", 1, 1);
        const SearchHealthSnap b = ready_health("generation-b", 1, 1);
        const SearchHealthSnap c = ready_health("generation-c", 1, 1);
        Scripted sc;
        sc.healths = {a, b, b, c};
        sc.snippets = {"", ""};
        const Outcome o = run_scripted(sc);
        check(!o.ok && o.health_calls == 4 && o.search_calls == kMaxSearchAttempts, "rebuild-bound");
    }

    {
        SearchHealthSnap unready;
        unready.ready = false;
        Scripted sc;
        sc.healths = {unready};
        sc.snippets = {"must not search"};
        const Outcome o = run_scripted(sc);
        check(!o.ok && o.search_calls == 0 && !o.semantic, "unready-first");
    }

    {
        SearchHealthSnap h;
        h.ready = false;
        h.semantic_available = false;
        Scripted sc;
        sc.mode = "hybrid";
        sc.healths = {h};
        sc.snippets = {"must not search"};
        const Outcome o = run_scripted(sc);
        check(!o.ok && o.semantic && o.search_calls == 0, "hybrid-semantic-unavail");
    }

    {
        EmbeddingIdentity id = embedding_fake_identity(32);
        SearchHealthSnap health = ready_health("generation-a", 1, 1);
        health.retrieval_mode = "hybrid";
        health.semantic_configured = true;
        health.semantic_available = true;
        health.degradation.clear();
        health.has_embedding = true;
        health.embedding = id;
        health.projected_embeddings = 1;
        check(same_search_snapshot(health, health, "hybrid", true, "", &id), "hybrid-identity-ok");
        EmbeddingIdentity mismatched = id;
        mismatched.model_revision = "other";
        check(!same_search_snapshot(health, health, "hybrid", true, "", &mismatched), "hybrid-identity-mismatch");
    }

    if (failed == 0) std::fprintf(stderr, "cpp_memory_store snapshot self-test ok\n");
    return failed == 0 ? 0 : 1;
}

}  // namespace godbrain::memory
