#pragma once

#include "json.hpp"
#include <functional>
#include <string>

using json = nlohmann::json;

namespace godbrain_rag { class Client; }

namespace memory {
    json working_shelf(const json& payload);
    json save_working_turn(const std::string& prompt, const std::string& answer);
    json refresh_context_index(const json& capabilities);
    json shared_working_context(const std::string& query,
                                const std::string& thread = "",
                                const std::string& scope = "technical");
    json shared_context(const std::string& query, const std::string& thread = "",
                        const std::string& scope = "technical");
    json shared_context(const std::string& query, const std::string& thread,
                        const std::string& scope, const godbrain_rag::Client& client);
    json research_document(const std::string& value, bool search);
    json save_thought(const json& payload);
    json observe_host();
    json promote_claim(const json& payload);
    json maintain_evidence();
    json evidence_status();
    json research_tick(const std::function<std::string(const json&)>& infer,
                       const std::string& model_id = "");
    json research_status();
    json stale_mismatched_pins(const std::string& pin, const std::string& reasoning);
    json get_recent(int limit);
    json get_recent_personal(int limit);
    json search_verified(const std::string& query, int limit);
    json search_verified(const std::string& query, int limit, const std::string& sector);
    json set_status(const json& payload);
    json record_skill_run(const json& payload);
    json promote_skill(const json& payload);
    json query_skills(const json& payload);
    json session_snapshot(int limit);
    json session_snapshot(int limit, const godbrain_rag::Client& client);
    json hydrate_session_from_rag();
    json hydrate_session_from_rag(const godbrain_rag::Client& client);
    bool render_session_context(std::string& context, std::string& error);
    bool render_session_context(
        std::string& context, std::string& error, const godbrain_rag::Client& client);
    void note_session(
        const std::string& source_hash,
        const std::string& stable_id,
        const std::string& content,
        const std::string& status = "candidate");
}