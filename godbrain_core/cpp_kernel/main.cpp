#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <thread>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <functional>
#include <atomic>
#include <mutex>
#include "rag_client.h"
#include "coli_sse.h"
#include "kernel_request.h"
#include "memory.h"
#include "telemetry.h"

// 3 minute ceiling on a single Colibri invocation. Defined once so the wait
// timeout and the message we return on expiry can never drift apart.
static const DWORD COLIBRI_TIMEOUT_MS = 180000;

#include "kernel.h"

using json = nlohmann::json;

GodBrainKernel kernel_hub; // Global kernel instance

// Bearer token required for any request that carries a "command_type" (i.e. a
// privileged kernel dispatch). Loaded once from the environment at startup so
// the arbitrary-command capability stays available to trusted callers while
// being gated behind an explicit secret instead of open to any local process.
static std::string g_api_token;

// Directory that holds the static Galaxy UI. Resolved once at startup from
// GODBRAIN_FRONTEND_DIR or a portable default (see resolve_frontend_dir()).
static std::string g_frontend_dir;

// Tick when this kernel process started the in-flight serve generate.
// /status reads it from another httplib thread so busy stops looking dead.
static std::atomic<DWORD> g_coli_job_started_ms{0};

struct LastOracleTurn {
    std::string question;
    std::string answer;
    DWORD elapsed_ms = 0;
    bool ok = false;
    bool stored = false;
    bool complete = true;
};
constexpr size_t kMaxOracleTurns = 8;
static std::mutex g_last_oracle_mu;
static std::vector<LastOracleTurn> g_oracle_turns;

static json last_oracle_json();
static json last_oracle_turns_json();
static void load_oracle_turns();
static void remember_oracle_turn(
    const std::string& question,
    const std::string& answer,
    DWORD elapsed_ms);
static void note_oracle_partial(
    const std::string& question,
    const std::string& partial,
    DWORD elapsed_ms);
static void retry_unstored_oracle_turns();

static std::string read_env(const char* name) {
    char* value = nullptr;
    size_t length = 0;
    if (_dupenv_s(&value, &length, name) != 0 || value == nullptr) return "";
    std::string result(value);
    std::free(value);
    return result;
}

static std::string get_exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

static bool path_exists(const std::string& p) {
    if (p.empty()) return false;
    DWORD attrs = GetFileAttributesA(p.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES;
}

static json oracle_turn_to_json(const LastOracleTurn& turn) {
    return {
        {"question", turn.question},
        {"answer", turn.answer},
        {"elapsed_ms", turn.elapsed_ms},
        {"ok", turn.ok},
        {"stored", turn.stored},
        {"complete", turn.complete},
    };
}

static json last_oracle_json() {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    if (g_oracle_turns.empty()) return json::object();
    return oracle_turn_to_json(g_oracle_turns.back());
}

static json last_oracle_turns_json() {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    json turns = json::array();
    for (const auto& turn : g_oracle_turns) {
        turns.push_back(oracle_turn_to_json(turn));
    }
    return turns;
}

static std::string last_oracle_path() {
    const std::string dir = get_exe_dir();
    if (dir.empty()) return "last_oracle.json";
    return dir + "\\last_oracle.json";
}

// Replace the file in place. Never unlink the live file first — a failed
// write must leave the previous turns readable (the Gemini-class footgun).
static void persist_oracle_turns_locked() {
    json body = {{"version", 1}, {"turns", json::array()}};
    for (const auto& turn : g_oracle_turns) {
        body["turns"].push_back(oracle_turn_to_json(turn));
    }
    const std::string path = last_oracle_path();
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) {
            std::cerr << "[MEMORY] could not write " << tmp << std::endl;
            return;
        }
        out << body.dump(2);
        out.flush();
        if (!out) {
            std::cerr << "[MEMORY] incomplete write " << tmp << std::endl;
            return;
        }
    }
    if (MoveFileExA(
            tmp.c_str(),
            path.c_str(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) {
        std::cerr << "[MEMORY] could not replace " << path
                  << " (win32=" << GetLastError() << "); previous file kept"
                  << std::endl;
    }
}

static void load_oracle_turns() {
    const std::string path = last_oracle_path();
    std::ifstream in(path, std::ios::binary);
    if (!in) return;
    try {
        const json body = json::parse(in);
        const json turns = body.value("turns", json::array());
        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
        g_oracle_turns.clear();
        for (const auto& item : turns) {
            if (!item.is_object()) continue;
            LastOracleTurn turn;
            turn.question = item.value("question", "");
            turn.answer = item.value("answer", "");
            turn.elapsed_ms = item.value("elapsed_ms", 0);
            turn.ok = item.value("ok", false);
            turn.stored = item.value("stored", false);
            turn.complete = item.value("complete", true);
            if (turn.question.empty() && turn.answer.empty()) continue;
            g_oracle_turns.push_back(std::move(turn));
        }
        if (g_oracle_turns.size() > kMaxOracleTurns) {
            g_oracle_turns.erase(
                g_oracle_turns.begin(),
                g_oracle_turns.begin() + static_cast<std::ptrdiff_t>(
                    g_oracle_turns.size() - kMaxOracleTurns));
        }
        std::cout << "[MEMORY] Loaded " << g_oracle_turns.size()
                  << " oracle turns from " << path << std::endl;
    } catch (const json::exception& error) {
        std::cerr << "[MEMORY] last_oracle.json ignored: " << error.what()
                  << std::endl;
    }
}

static void store_oracle_turn_async(
    const std::string& question, const std::string& answer) {
    std::thread([question, answer]() {
        bool stored = false;
        try {
            std::string body = "Oracle turn (candidate, not verified)\nQ: " +
                               question + "\nA: " + answer;
            if (body.size() > 2000) body.resize(2000);
            memory::save_thought({{"content", body}, {"sector", "oracle"}});
            stored = true;
        } catch (const std::exception& error) {
            std::cerr << "[MEMORY] oracle turn not stored: " << error.what()
                      << std::endl;
        }
        if (!stored) return;
        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
        for (auto it = g_oracle_turns.rbegin(); it != g_oracle_turns.rend();
             ++it) {
            if (it->question == question && it->answer == answer) {
                it->stored = true;
                break;
            }
        }
        persist_oracle_turns_locked();
    }).detach();
}

static void note_oracle_partial(
    const std::string& question,
    const std::string& partial,
    DWORD elapsed_ms) {
    if (question.empty() || partial.empty()) return;
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    if (!g_oracle_turns.empty() && !g_oracle_turns.back().complete &&
        g_oracle_turns.back().question == question) {
        g_oracle_turns.back().answer = partial;
        g_oracle_turns.back().elapsed_ms = elapsed_ms;
    } else {
        LastOracleTurn turn;
        turn.question = question;
        turn.answer = partial;
        turn.elapsed_ms = elapsed_ms;
        turn.ok = false;
        turn.stored = false;
        turn.complete = false;
        g_oracle_turns.push_back(std::move(turn));
        if (g_oracle_turns.size() > kMaxOracleTurns) {
            g_oracle_turns.erase(g_oracle_turns.begin());
        }
    }
    persist_oracle_turns_locked();
}

static void retry_unstored_oracle_turns() {
    std::vector<std::pair<std::string, std::string>> pending;
    {
        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
        for (const auto& turn : g_oracle_turns) {
            if (turn.ok && turn.complete && !turn.stored &&
                !turn.question.empty() && !turn.answer.empty()) {
                pending.emplace_back(turn.question, turn.answer);
            }
        }
    }
    for (const auto& item : pending) {
        std::cout << "[MEMORY] Retrying unstored oracle turn" << std::endl;
        store_oracle_turn_async(item.first, item.second);
    }
}

static void remember_oracle_turn(
    const std::string& question,
    const std::string& answer,
    DWORD elapsed_ms) {
    LastOracleTurn turn;
    turn.question = question;
    turn.answer = answer;
    turn.elapsed_ms = elapsed_ms;
    turn.ok = answer.compare(0, 6, "Error:") != 0;
    turn.stored = false;
    turn.complete = true;
    {
        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
        if (!g_oracle_turns.empty() && !g_oracle_turns.back().complete &&
            g_oracle_turns.back().question == question) {
            g_oracle_turns.back() = turn;
        } else {
            g_oracle_turns.push_back(turn);
            if (g_oracle_turns.size() > kMaxOracleTurns) {
                g_oracle_turns.erase(g_oracle_turns.begin());
            }
        }
        persist_oracle_turns_locked();
    }
    if (!turn.ok) return;
    store_oracle_turn_async(question, answer);
}

// Resolves the Colibri C-Engine executable path. Order of preference:
//   1. GODBRAIN_COLIBRI_PATH environment override (explicit, always wins).
//   2. A handful of repo-relative candidates, tried both from the running
//      executable's own directory and from the current working directory, so
//      this works whether cpp_kernel.exe lives at godbrain_core/cpp_kernel/
//      or a build subdirectory beneath it, without baking in any one user's
//      absolute path.
static std::string resolve_colibri_path() {
    const std::string env = read_env("GODBRAIN_COLIBRI_PATH");
    if (!env.empty()) return env;

    static const char* candidates[] = {
        "\\..\\..\\..\\colibri\\c\\colibri.exe",
        "\\..\\..\\colibri\\c\\colibri.exe",
        "\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\..\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        "\\LLM\\colibri_LLM\\c\\colibri.exe",
    };
    std::string exe_dir = get_exe_dir();
    for (const char* rel : candidates) {
        if (!exe_dir.empty()) {
            std::string cand = exe_dir + rel;
            if (path_exists(cand)) return cand;
        }
    }
    // Fall back to a cwd-relative guess (matches the "../frontend" convention
    // used elsewhere in this file when launched from godbrain_core/cpp_kernel).
    std::string fallback = "..\\..\\LLM\\colibri_LLM\\c\\colibri.exe";
    if (path_exists(fallback)) return fallback;
    std::cerr << "[SYS] WARNING: could not locate colibri.exe via GODBRAIN_COLIBRI_PATH or repo-relative defaults; "
                 "using best-effort path '" << fallback << "'." << std::endl;
    return fallback;
}

// Resolves the frontend static directory the same way (env override first,
// then a repo-relative default). Returns a path suitable for both
// std::ifstream and httplib::Server::set_mount_point.
static std::string resolve_frontend_dir() {
    const std::string env = read_env("GODBRAIN_FRONTEND_DIR");
    if (!env.empty()) return env;
    return "../frontend";
}

// Origins allowed to talk to this loopback-only API: localhost/127.0.0.1 on
// any port (dev servers, the packaged UI, etc.) plus the Tauri webview
// origins. No wildcard is ever accepted.
static bool is_trusted_origin(const std::string& origin) {
    if (origin.empty()) return false;
    if (origin == "tauri://localhost") return true;
    size_t scheme_end = origin.find("://");
    if (scheme_end == std::string::npos) return false;
    std::string rest = origin.substr(scheme_end + 3);
    size_t slash = rest.find('/');
    if (slash != std::string::npos) rest = rest.substr(0, slash);
    size_t colon = rest.find(':');
    std::string host = (colon != std::string::npos) ? rest.substr(0, colon) : rest;
    return host == "localhost" || host == "127.0.0.1" || host == "tauri.localhost";
}

// Constant-time-ish comparison so an invalid bearer token doesn't leak length
// information via early-exit timing any more than necessary.
static bool token_matches(const std::string& provided) {
    if (g_api_token.empty() || provided.empty()) return false;
    if (provided.size() != g_api_token.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < provided.size(); i++) {
        diff |= (unsigned char)(provided[i] ^ g_api_token[i]);
    }
    return diff == 0;
}

static std::string extract_bearer_token(const httplib::Request& req) {
    auto it = req.headers.find("Authorization");
    if (it == req.headers.end()) return "";
    const std::string& val = it->second;
    const std::string prefix = "Bearer ";
    if (val.size() > prefix.size() && val.compare(0, prefix.size(), prefix) == 0) {
        return val.substr(prefix.size());
    }
    return "";
}

static bool write_authorized(const httplib::Request& req, httplib::Response& res) {
    if (g_api_token.empty()) return true;
    if (token_matches(extract_bearer_token(req))) return true;
    res.status = extract_bearer_token(req).empty() ? 401 : 403;
    res.set_content(
        json({{"error", "bearer token required for this write"}}).dump(),
        "application/json");
    return false;
}

bool colibri_serve_up();
static json coli_serve_status();

static json host_record_from_rag() {
    try {
        const json recent = memory::get_recent(8);
        for (const auto& thought : recent.value("thoughts", json::array())) {
            if (thought.value("sector", "") == "windows-sre") {
                return thought;
            }
        }
    } catch (const std::exception&) {
    }
    return json::object();
}

static json kernel_status_body() {
    json rag_health = json::object();
    httplib::Client health("127.0.0.1", 8084);
    health.set_connection_timeout(0, 200000);
    health.set_read_timeout(1, 0);
    if (const auto probe = health.Get("/health")) {
        try {
            rag_health = json::parse(probe->body);
        } catch (const json::exception&) {
        }
    }
    json tailscale = telemetry::get_tailscale();
    if (tailscale.value("up", false)) {
        if (g_api_token.empty()) {
            tailscale["writes"] = "disabled_no_token";
            tailscale["bound"] = false;
        } else {
            tailscale["writes"] = "token_required";
            tailscale["bound"] = true;
        }
    }
    const json coli = coli_serve_status();
    json host = telemetry::get_host_inventory();
    const json live = telemetry::get_current_state();
    host["ram_available_gb"] = live.value("ram_available_gb", 0.0);
    host["ram_used_percent"] = live.value("system_ram_percent", 0);
    return {
        {"kernel", true},
        {"coli_serve", coli.value("up", false)},
        {"coli", coli},
        {"writes_need_token", !g_api_token.empty()},
        {"vram", telemetry::plan_colibri_vram()},
        {"rag", rag_health},
        {"host", host},
        {"host_record", host_record_from_rag()},
        {"tailscale", tailscale},
        {"last_oracle", last_oracle_json()},
        {"last_oracle_turns", last_oracle_turns_json()},
    };
}

static void handle_remember(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        json payload = req.body.empty() ? json::object() : json::parse(req.body);
        std::string text = payload.value(
            "text", payload.value("message", payload.value("idea", "")));
        if (payload.contains("title") || payload.contains("url")) {
            std::ostringstream composed;
            if (payload.contains("title")) composed << payload["title"].get<std::string>() << '\n';
            if (payload.contains("url")) composed << payload["url"].get<std::string>() << '\n';
            if (!text.empty()) composed << text;
            text = composed.str();
        }
        json stored = memory::save_thought({
            {"content", text},
            {"sector", payload.value("sector", "operator")},
        });
        res.set_content(stored.dump(), "application/json");
    } catch (const json::exception&) {
        res.status = 400;
        res.set_content(json({{"error", "remember body must be JSON"}}).dump(), "application/json");
    } catch (const std::exception& error) {
        res.status = 503;
        res.set_content(json({{"error", error.what()}}).dump(), "application/json");
    }
}

static void handle_observe(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        res.set_content(memory::observe_host().dump(), "application/json");
    } catch (const std::exception& error) {
        res.status = 503;
        res.set_content(json({{"error", error.what()}}).dump(), "application/json");
    }
}

static void handle_last(const httplib::Request&, httplib::Response& res) {
    res.set_content(
        json({{"last_oracle", last_oracle_json()},
              {"turns", last_oracle_turns_json()}})
            .dump(),
        "application/json");
}

static void handle_judge(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        json payload = req.body.empty() ? json::object() : json::parse(req.body);
        json judged = memory::set_status({
            {"id", payload.value("id", payload.value("stable_id", ""))},
            {"status", payload.value("status", "")},
            {"reasoning", payload.value("reasoning", payload.value("reason", ""))},
        });
        res.set_content(judged.dump(), "application/json");
    } catch (const json::exception&) {
        res.status = 400;
        res.set_content(json({{"error", "judge body must be JSON"}}).dump(), "application/json");
    } catch (const std::exception& error) {
        res.status = 503;
        res.set_content(json({{"error", error.what()}}).dump(), "application/json");
    }
}

static void attach_shortcut_routes(httplib::Server& server) {
    server.Get("/api/status", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        res.set_content(kernel_status_body().dump(), "application/json");
    });
    server.Get("/api/last", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_last(req, res);
    });
    server.Post("/api/remember", handle_remember);
    server.Post("/api/observe", handle_observe);
    server.Post("/api/judge", handle_judge);
}

constexpr const char* kColibriServeHost = "127.0.0.1";
constexpr int kColibriServePort = 8000;

bool colibri_serve_up() {
    httplib::Client client(kColibriServeHost, kColibriServePort);
    client.set_connection_timeout(0, 200000);
    client.set_read_timeout(1, 0);
    client.set_follow_location(false);
    const auto response = client.Get("/health");
    return response && response->status == 200;
}

static json coli_serve_status() {
    json result = {
        {"up", false},
        {"busy", false},
        {"active", 0},
        {"queued", 0},
        {"completed", 0},
    };
    httplib::Client client(kColibriServeHost, kColibriServePort);
    client.set_connection_timeout(0, 200000);
    client.set_read_timeout(1, 0);
    client.set_follow_location(false);
    const auto response = client.Get("/health");
    if (!response || response->status != 200) return result;
    result["up"] = true;
    try {
        const json body = json::parse(response->body);
        const json scheduler = body.value("scheduler", json::object());
        const int active = scheduler.value("active", 0);
        result["busy"] = active > 0;
        result["active"] = active;
        result["queued"] = scheduler.value("queued", 0);
        result["completed"] = scheduler.value("completed", 0);
        result["admitted"] = scheduler.value("admitted", 0);
        const json hwinfo = body.value("hwinfo", json::object());
        if (hwinfo.contains("ram_avail_gb")) {
            result["ram_avail_gb"] = hwinfo.value("ram_avail_gb", 0.0);
        }
        const json tiers = body.value("tiers", json::object());
        if (!tiers.empty()) {
            result["experts_vram"] = tiers.value("vram", 0);
            result["experts_ram"] = tiers.value("ram", 0);
            result["experts_disk"] = tiers.value("disk", 0);
        }
        const DWORD started = g_coli_job_started_ms.load(std::memory_order_relaxed);
        if (active > 0 && started != 0) {
            result["elapsed_s"] = static_cast<int>((GetTickCount() - started) / 1000);
        }
        if (active <= 0) {
            g_coli_job_started_ms.store(0, std::memory_order_relaxed);
        }
    } catch (const json::exception&) {
    }
    return result;
}

using ColiTokenFn = std::function<void(const std::string&)>;
using ColiPingFn = std::function<void()>;

static std::string strip_coli_reply(std::string combined) {
    if (combined.compare(0, 6, "Error:") == 0) return combined;
    std::string final_answer = combined;
    const size_t ans_idx = combined.rfind("Answer:");
    const size_t prof_idx = combined.rfind("PROFILO");
    const size_t prof_en_idx = combined.rfind("PROFILE");
    if (ans_idx != std::string::npos) {
        final_answer = combined.substr(ans_idx + 7);
        size_t end_idx = final_answer.find("PROFILE");
        if (end_idx == std::string::npos) end_idx = final_answer.find("PROFILO");
        if (end_idx != std::string::npos) {
            final_answer = final_answer.substr(0, end_idx);
        }
    } else {
        const size_t marker = prof_idx != std::string::npos ? prof_idx : prof_en_idx;
        if (marker != std::string::npos) {
            const size_t start = combined.rfind('\n', marker);
            if (start != std::string::npos) {
                const size_t prev = combined.rfind('\n', start - 1);
                if (prev != std::string::npos) {
                    final_answer = combined.substr(prev + 1, start - prev - 1);
                } else {
                    final_answer = combined.substr(0, start);
                }
            }
        } else if (final_answer.length() > 500) {
            final_answer = final_answer.substr(final_answer.length() - 500);
        }
    }
    const auto first = final_answer.find_first_not_of(" \n\r\t");
    if (first == std::string::npos) return "No response.";
    final_answer.erase(0, first);
    const auto last = final_answer.find_last_not_of(" \n\r\t");
    if (last != std::string::npos) final_answer.erase(last + 1);
    return final_answer.empty() ? "No response." : final_answer;
}

std::string run_colibri_serve(
    const std::string& system,
    const std::string& user,
    ColiTokenFn on_token = {},
    ColiPingFn on_ping = {}) {
    httplib::Client client(kColibriServeHost, kColibriServePort);
    client.set_connection_timeout(0, 500000);
    // Colibri pings empty deltas every ~10s during prefill. A 60s read
    // timeout then means the engine died, not that we are still paging.
    client.set_read_timeout(60, 0);
    client.set_write_timeout(5, 0);
    client.set_max_timeout(430000);
    client.set_follow_location(false);

    const std::string model = []() {
        const std::string override_model = read_env("GODBRAIN_COLIBRI_MODEL");
        return override_model.empty() ? "glm-5.2-colibri" : override_model;
    }();
    const json body = {
        {"model", model},
        {"stream", true},
        {"max_tokens", 80},
        {"messages",
         json::array(
             {json{{"role", "system"}, {"content", system}},
              json{{"role", "user"}, {"content", user}}})},
    };

    httplib::Headers headers = {{"Accept", "text/event-stream"}};
    const std::string key = read_env("GODBRAIN_COLIBRI_KEY");
    const std::string coli_key = key.empty() ? read_env("COLI_API_KEY") : key;
    if (!coli_key.empty()) {
        headers.emplace("Authorization", "Bearer " + coli_key);
    }

    std::string assembled;
    std::string sse_buf;
    g_coli_job_started_ms.store(GetTickCount(), std::memory_order_relaxed);
    const auto response = client.Post(
        "/v1/chat/completions", headers, body.dump(), "application/json",
        [&](const char* data, size_t len) {
            godbrain_coli::feed_sse(
                sse_buf, data, len, assembled, on_token, on_ping);
            return true;
        });
    g_coli_job_started_ms.store(0, std::memory_order_relaxed);
    if (!response) {
        return "Error: Colibri serve did not finish in 420s. "
               "GLM-5.2 is paging experts off disk on 16 GB. "
               "Wait until /status shows coli=serve (not busy) and ask again.";
    }
    if (response->status != 200) {
        return "Error: Colibri serve returned HTTP " +
               std::to_string(response->status);
    }
    if (!assembled.empty()) return assembled;
    try {
        const json parsed = json::parse(response->body);
        return parsed.at("choices").at(0).at("message").at("content").get<std::string>();
    } catch (const json::exception&) {
        return "Error: Colibri serve returned a malformed completion.";
    }
}

std::string run_colibri_spawn(const std::string& prompt) {
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;

    CreatePipe(&hOutRd, &hOutWr, &saAttr, 0);
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    
    CreatePipe(&hInRd, &hInWr, &saAttr, 0);
    SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si); 
    si.hStdError = hOutWr;
    si.hStdOutput = hOutWr;
    si.hStdInput = hInRd;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    // Quote the resolved path: it may contain spaces (e.g. under
    // "Program Files" or a user directory with a space in it), and an
    // unquoted path lets CreateProcess misinterpret the first space as the
    // end of the executable name and the rest as arguments.
    std::string cmd = "\"" + resolve_colibri_path() + "\" 64 8 8";

    const std::string snap_env = read_env("GODBRAIN_SNAPSHOT_PATH");
    const json vram = telemetry::plan_colibri_vram();
    const std::string expert_gb = std::to_string(vram.value("expert_gb", 2));
    std::cout << "[VRAM] " << vram.value("name", "GPU") << " "
              << vram.value("dedicated_gb", 0) << " GB dedicated, expert_gb="
              << expert_gb << ", reserve=" << vram.value("reserve_gb", 0)
              << " GB, overcommit="
              << (vram.value("overcommit", false) ? "on" : "off") << std::endl;

    SetEnvironmentVariableA("SNAP", snap_env.empty() ? "C:\\nvme\\glm52" : snap_env.c_str());
    SetEnvironmentVariableA("NGEN", "64");
    SetEnvironmentVariableA(
        "COLI_RAM_OVERCOMMIT", vram.value("overcommit", false) ? "1" : "0");
    SetEnvironmentVariableA("COLI_CUDA", "1");
    SetEnvironmentVariableA("CUDA_EXPERT_GB", expert_gb.c_str());
    SetEnvironmentVariableA("COLI_PROMPT", prompt.c_str());

    // CreateProcessA may write into lpCommandLine (it can rewrite the
    // separating space into a NUL while parsing argv[0]), so it must never be
    // handed a pointer into a std::string's internal buffer (via a
    // cast-away-const c_str()) — that's UB. Use a private, mutable buffer.
    std::vector<char> cmd_buf(cmd.begin(), cmd.end());
    cmd_buf.push_back('\0');

    BOOL success = CreateProcessA(NULL, cmd_buf.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInRd);

    if (!success) {
        CloseHandle(hInWr);
        CloseHandle(hOutRd);
        return "Error: Failed to spawn Colibri C-Engine natively.";
    }

    // No need to write to stdin if we are passing prompt via env var
    CloseHandle(hInWr); // Sends EOF!

    // Read stdout on a background thread instead of blocking on ReadFile
    // before WaitForSingleObject: a hung child that keeps writing (or just
    // keeps the pipe open) would otherwise stall this synchronous read
    // forever, and WaitForSingleObject's timeout below would never even be
    // reached.
    std::string output;
    std::thread reader([&]() {
        DWORD read;
        CHAR buf[4096];
        while (ReadFile(hOutRd, buf, sizeof(buf), &read, NULL) && read > 0) {
            output.append(buf, read);
        }
    });

    DWORD wait_result = WaitForSingleObject(pi.hProcess, COLIBRI_TIMEOUT_MS);
    bool timed_out = (wait_result == WAIT_TIMEOUT);
    if (timed_out) {
        // Terminate only the exact child process we spawned (by handle) —
        // never by image name, which would kill every colibri.exe on the
        // machine, including unrelated instances a user is running directly.
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 5000); // reap the terminated process
    }

    // The reader thread's ReadFile loop only returns once every write handle
    // to the pipe is closed, which happens once the child (the pipe's sole
    // writer) exits or is terminated above — so this join can no longer
    // block indefinitely.
    reader.join();

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    if (timed_out) {
        return "Error: Colibri C-Engine timed out after 180s and was terminated.";
    }

    return output;
}

std::string run_colibri(
    const std::string& system,
    const std::string& user,
    ColiTokenFn on_token = {},
    ColiPingFn on_ping = {}) {
    const json coli = coli_serve_status();
    if (coli.value("up", false)) {
        if (coli.value("busy", false)) {
            std::cout << "[COLIBRI] Serve is busy; refusing to stack a second slot"
                      << std::endl;
            return "Error: Colibri is still generating the previous answer "
                   "(one GPU slot). Wait until /status shows coli=serve, then ask again.";
        }
        std::cout << "[COLIBRI] Persistent serve at 127.0.0.1:8000" << std::endl;
        return run_colibri_serve(system, user, on_token, on_ping);
    }
    std::cout << "[COLIBRI] Serve is down; refusing cold-spawn on 16 GB"
              << std::endl;
    return "Error: coli serve is down on 127.0.0.1:8000. "
           "Run schtasks /Run /TN GodBrainLogon and wait until /status shows coli serve. "
           "Cold-spawn of this snapshot on 16 GB is disabled.";
}

#pragma comment(lib, "user32.lib")

int main() {
    if (read_env("GODBRAIN_SHOW_CONSOLE") != "1") {
        if (HWND console = GetConsoleWindow()) {
            ShowWindow(console, SW_HIDE);
        }
    }

    std::cout << "[SYS] Booting GodBrain C++ Core Router..." << std::endl;

    if (read_env("MONGODB_URI").empty()) {
        SetEnvironmentVariableA("MONGODB_URI", "mongodb://127.0.0.1:27017");
        std::cout << "[SYS] MONGODB_URI defaulted to mongodb://127.0.0.1:27017"
                  << std::endl;
    }

    const std::string token_env = read_env("GODBRAIN_API_TOKEN");
    if (!token_env.empty()) {
        g_api_token = token_env;
        std::cout << "[SYS] GODBRAIN_API_TOKEN loaded. Privileged commands require 'Authorization: Bearer <token>'." << std::endl;
    } else {
        std::cout << "[SYS] WARNING: GODBRAIN_API_TOKEN is not set. Requests carrying 'command_type' will be rejected (403) "
                     "until a token is configured in the environment." << std::endl;
    }

    g_frontend_dir = resolve_frontend_dir();
    load_oracle_turns();
    retry_unstored_oracle_turns();
    godbrain_rag::Client rag_client;
    try {
        const json hydrated = memory::hydrate_session_from_rag();
        std::cout << "[MEMORY] Session hydrate from RAG loaded="
                  << hydrated.value("loaded", 0)
                  << " status=" << hydrated.value("status", "skipped")
                  << std::endl;
    } catch (const std::exception& error) {
        std::cout << "[MEMORY] Session hydrate skipped: " << error.what()
                  << std::endl;
    }
    {
        const json turns = last_oracle_turns_json();
        int noted = 0;
        for (const auto& turn : turns) {
            if (!turn.value("ok", false)) continue;
            const std::string q = turn.value("question", "");
            const std::string a = turn.value("answer", "");
            if (a.empty()) continue;
            const std::string body = "Q: " + q + " A: " + a;
            memory::note_session(
                "oracle-disk:" + q.substr(0, 24),
                "oracle-disk:" + q.substr(0, 24),
                body,
                "candidate");
            ++noted;
        }
        if (noted > 0) {
            std::cout << "[MEMORY] Session noted " << noted
                      << " oracle turns from disk" << std::endl;
        }
    }

    httplib::Server svr;

    svr.Options(R"(.*)", [](const httplib::Request& req, httplib::Response& res) {
        auto it = req.headers.find("Origin");
        if (it != req.headers.end() && is_trusted_origin(it->second)) {
            res.set_header("Access-Control-Allow-Origin", it->second);
            res.set_header("Vary", "Origin");
        }
        res.set_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
        res.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
    });

    auto set_cors = [](const httplib::Request& req, httplib::Response& res) {
        auto it = req.headers.find("Origin");
        if (it != req.headers.end() && is_trusted_origin(it->second)) {
            res.set_header("Access-Control-Allow-Origin", it->second);
            res.set_header("Vary", "Origin");
        }
    };

    svr.Get("/api/test", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        res.set_content("C++ Core Operational!", "text/plain");
    });

    svr.Get("/", [&](const httplib::Request&, httplib::Response& res) {
        res.set_redirect("/galaxy");
    });

    svr.Get("/galaxy", [&](const httplib::Request&, httplib::Response& res) {
        std::ifstream file(g_frontend_dir + "/galaxy.html");
        if (file) {
            std::stringstream buffer;
            buffer << file.rdbuf();
            res.set_content(buffer.str(), "text/html");
        } else {
            res.status = 404;
            res.set_content("Galaxy UI not found.", "text/plain");
        }
    });

    svr.set_mount_point("/frontend", g_frontend_dir);

    svr.Get("/api/graph", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        int limit = godbrain_rag::kDefaultGraphLimit;
        if (req.has_param("limit")) {
            try {
                limit = std::stoi(req.get_param_value("limit"));
            } catch (...) {
                res.status = 400;
                res.set_content(
                    json({{"error", godbrain_rag::kErrGraphLimit}}).dump(),
                    "application/json");
                return;
            }
        }
        json rag_graph;
        std::string rag_error;
        if (!rag_client.graph(limit, rag_graph, rag_error)) {
            res.status = rag_error == godbrain_rag::kErrGraphLimit ? 400 : 503;
            if (res.status == 503) {
                httplib::Client health("127.0.0.1", 8084);
                health.set_connection_timeout(0, 200000);
                health.set_read_timeout(1, 0);
                if (const auto probe = health.Get("/health")) {
                    try {
                        const json body = json::parse(probe->body);
                        if (body.contains("readiness_reasons") &&
                            body.at("readiness_reasons").is_array() &&
                            !body.at("readiness_reasons").empty()) {
                            rag_error += " (";
                            rag_error += body.at("readiness_reasons").dump();
                            rag_error += "; run rag-rebuild.exe)";
                        }
                    } catch (const json::exception&) {
                    }
                }
            }
            res.set_content(json({{"error", rag_error}}).dump(), "application/json");
            return;
        }
        res.set_content(godbrain_rag::galaxy_graph(rag_graph).dump(), "application/json");
    });

    svr.Get("/api/node", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        const std::string id = req.has_param("id") ? req.get_param_value("id") : "";
        json document;
        std::string rag_error;
        if (!rag_client.document(id, document, rag_error)) {
            int status = 503;
            if (rag_error == godbrain_rag::kErrDocumentNotFound) status = 404;
            else if (rag_error == godbrain_rag::kErrDocumentIDRequired) status = 400;
            res.status = status;
            res.set_content(json({{"error", rag_error}}).dump(), "application/json");
            return;
        }
        res.set_content(godbrain_rag::galaxy_node(document).dump(), "application/json");
    });

    svr.Post("/api/judge", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_judge(req, res);
    });

    svr.Get("/api/status", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        res.set_content(kernel_status_body().dump(), "application/json");
    });

    svr.Get("/api/last", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_last(req, res);
    });

    svr.Post("/api/remember", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_remember(req, res);
    });

    svr.Post("/api/observe", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_observe(req, res);
    });

    svr.Post("/api/chat", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        try {
            json payload = json::parse(req.body);
            std::string user_msg = payload.value("message", "");
            
            // Check if it's a kernel command directly. This is the deliberately
            // powerful arbitrary-command / self-modification surface, so it is
            // gated behind an explicit, non-guessable bearer token instead of
            // being removed.
            auto starts_with_ignore_case = [](const std::string& text, const char* prefix) {
                const size_t n = std::char_traits<char>::length(prefix);
                if (text.size() < n) return false;
                for (size_t i = 0; i < n; ++i) {
                    if (std::tolower(static_cast<unsigned char>(text[i])) !=
                        std::tolower(static_cast<unsigned char>(prefix[i]))) {
                        return false;
                    }
                }
                return true;
            };
            auto trim_view = [](std::string value) {
                const auto not_space = [](unsigned char character) {
                    return std::isspace(character) == 0;
                };
                value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
                value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
                return value;
            };

            if (starts_with_ignore_case(user_msg, "/status") &&
                (user_msg.size() == 7 ||
                 std::isspace(static_cast<unsigned char>(user_msg[7])) != 0)) {
                const json st = kernel_status_body();
                const json host = st.value("host", json::object());
                const json rec = st.value("host_record", json::object());
                const json tail = st.value("tailscale", json::object());
                const json rag = st.value("rag", json::object());
                std::ostringstream reply;
                const json coli = st.value("coli", json::object());
                reply << (host.value("computer_name", "?")) << " / "
                      << host.value("total_physical_ram_gb", 0) << " GB / "
                      << host.value("logical_processors", 0) << " threads\n"
                      << "host_record=" << rec.value("status", "none") << "\n";
                if (!coli.value("up", st.value("coli_serve", false))) {
                    reply << "coli=down";
                } else if (coli.value("busy", false)) {
                    reply << "coli=busy";
                    if (coli.contains("elapsed_s")) {
                        reply << " " << coli.value("elapsed_s", 0) << "s";
                    }
                    reply << " — generating, do not ask again";
                } else {
                    reply << "coli=serve";
                }
                reply << " active=" << coli.value("active", 0)
                      << " done=" << coli.value("completed", 0)
                      << " queued=" << coli.value("queued", 0)
                      << " rag=" << (rag.value("ready", false) ? "ready" : "down")
                      << " writes="
                      << (st.value("writes_need_token", false) ? "need bearer"
                                                              : "open on loopback")
                      << "\n";
                if (coli.contains("experts_disk")) {
                    reply << "experts vram=" << coli.value("experts_vram", 0)
                          << " ram=" << coli.value("experts_ram", 0)
                          << " disk=" << coli.value("experts_disk", 0) << "\n";
                }
                const double ram_free = host.value(
                    "ram_available_gb", coli.value("ram_avail_gb", -1.0));
                if (ram_free >= 0.0) {
                    char ram_buf[32];
                    std::snprintf(ram_buf, sizeof(ram_buf), "%.1f", ram_free);
                    reply << "RAM free " << ram_buf << " GB";
                    if (ram_free < 4.0) {
                        reply << " — paging, wait";
                    }
                    reply << "\n";
                }
                const json last = st.value("last_oracle", json::object());
                if (!last.empty() && last.contains("answer")) {
                    auto clip = [](std::string text, size_t max) {
                        if (text.size() > max) {
                            text.resize(max);
                            text += "...";
                        }
                        return text;
                    };
                    reply << "last " << (last.value("elapsed_ms", 0) / 1000) << "s "
                          << (last.value("ok", false) ? "ok" : "fail")
                          << (last.value("stored", false) ? " stored" : "")
                          << "\n  Q: " << clip(last.value("question", ""), 120)
                          << "\n  A: " << clip(last.value("answer", ""), 160)
                          << "\n";
                }
                if (tail.value("up", false)) {
                    reply << "tailscale " << tail.value("ip", "") << " "
                          << tail.value("writes", "") << "\n";
                } else {
                    reply << "tailscale down\n";
                }
                for (const auto& volume : host.value("volumes", json::array())) {
                    reply << "  " << volume.value("letter", "?") << ": "
                          << volume.value("label", "") << " "
                          << volume.value("total_gb", 0) << " GB\n";
                }
                res.set_content(json({{"response", reply.str()}}).dump(), "application/json");
                return;
            }

            if (starts_with_ignore_case(user_msg, "/last") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                const json turns = last_oracle_turns_json();
                std::ostringstream reply;
                if (turns.empty()) {
                    reply << "No Oracle turns on disk yet.";
                } else {
                    reply << turns.size() << " Oracle turn(s) on disk "
                             "(candidate, not verified):\n";
                    int index = 0;
                    for (const auto& turn : turns) {
                        ++index;
                        reply << index << ". "
                              << (turn.value("ok", false) ? "ok" : "fail")
                              << (turn.value("complete", true) ? "" : " partial")
                              << " " << (turn.value("elapsed_ms", 0) / 1000)
                              << "s\n  Q: "
                              << turn.value("question", "") << "\n  A: "
                              << turn.value("answer", "") << "\n";
                    }
                }
                res.set_content(json({{"response", reply.str()}}).dump(),
                                "application/json");
                return;
            }

            if (starts_with_ignore_case(user_msg, "/brief") &&
                (user_msg.size() == 6 ||
                 std::isspace(static_cast<unsigned char>(user_msg[6])) != 0)) {
                const json st = kernel_status_body();
                const json host = st.value("host", json::object());
                const json coli = st.value("coli", json::object());
                const json rag = st.value("rag", json::object());
                const json last = st.value("last_oracle", json::object());
                std::ostringstream reply;
                reply << host.value("computer_name", "?") << " | coli="
                      << (!coli.value("up", false)
                              ? "down"
                              : (coli.value("busy", false) ? "busy" : "serve"))
                      << " rag="
                      << (rag.value("ready", false) ? "ready" : "down");
                const double ram = host.value("ram_available_gb", -1.0);
                if (ram >= 0.0) {
                    char ram_buf[32];
                    std::snprintf(ram_buf, sizeof(ram_buf), "%.1f", ram);
                    reply << " RAM " << ram_buf << " GB free";
                }
                reply << "\n";
                if (!last.empty() && last.contains("answer")) {
                    auto clip = [](std::string text, size_t max) {
                        if (text.size() > max) {
                            text.resize(max);
                            text += "...";
                        }
                        return text;
                    };
                    reply << "last "
                          << (last.value("complete", true) ? "" : "partial ")
                          << clip(last.value("question", ""), 80) << "\n  "
                          << clip(last.value("answer", ""), 160);
                } else {
                    reply << "No Oracle turn on disk yet.";
                }
                res.set_content(json({{"response", reply.str()}}).dump(),
                                "application/json");
                return;
            }

            if (starts_with_ignore_case(user_msg, "/vram") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                const json plan = telemetry::plan_colibri_vram();
                std::ostringstream reply;
                reply << "Colibri VRAM plan (16 GB compensation)\n"
                      << plan.value("name", "GPU") << " / "
                      << plan.value("dedicated_gb", 0) << " GB dedicated\n"
                      << "CUDA_EXPERT_GB=" << plan.value("expert_gb", 0)
                      << " (reserve " << plan.value("reserve_gb", 0) << " GB for KV/desktop)\n"
                      << "COLI_RAM_OVERCOMMIT="
                      << (plan.value("overcommit", false) ? "1" : "0")
                      << " — off means no silent spill to DDR5\n"
                      << "Override with GODBRAIN_CUDA_EXPERT_GB or GODBRAIN_COLI_OVERCOMMIT=1";
                res.set_content(json({{"response", reply.str()}}).dump(), "application/json");
                return;
            }

            if (starts_with_ignore_case(user_msg, "/observe") &&
                (user_msg.size() == 8 ||
                 std::isspace(static_cast<unsigned char>(user_msg[8])) != 0)) {
                try {
                    json stored = memory::observe_host();
                    const json live = stored.value("live", json::object());
                    const json inventory = stored.value("inventory", json::object());
                    std::ostringstream reply;
                    reply << "Stored host inventory as a candidate Golden Record.\n"
                          << "stable_id=" << stored.value("stable_id", "") << "\n"
                          << inventory.at("computer_name").get<std::string>()
                          << " / " << inventory.at("total_physical_ram_gb").get<int>()
                          << " GB / " << inventory.at("logical_processors").get<int>()
                          << " logical CPUs\n";
                    for (const auto& volume : inventory.value("volumes", json::array())) {
                        reply << "  " << volume.value("letter", "?") << ": "
                              << volume.value("label", "") << " "
                              << volume.value("total_gb", 0) << " GB fixed\n";
                    }
                    const json gpu = telemetry::get_gpu_memory();
                    reply << "GPU: " << gpu.value("name", "?") << " "
                          << gpu.value("dedicated_gb", 0) << " GB (not stored)\n";
                    reply << "Live sample (not stored): CPU "
                          << live.value("cpu_percent", 0.0) << "%, RAM "
                          << live.value("system_ram_percent", 0)
                          << "% used, "
                          << live.value("ram_available_gb", 0.0)
                          << " GB free";
                    for (const auto& volume : live.value("volume_free_gb", json::array())) {
                        reply << ", " << volume.value("letter", "?") << ": "
                              << volume.value("free_gb", 0.0) << " GB free";
                    }
                    reply << "\nVerify if Explorer matches the fixed disks, e.g.\n"
                          << "/verify " << stored.value("stable_id", "ID")
                          << " Explorer shows the same fixed volumes and sizes";
                    res.set_content(
                        json({{"response", reply.str()}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response",
                               std::string("Could not observe host: ") +
                                   error.what()}}).dump(),
                        "application/json");
                }
                return;
            }

            if (starts_with_ignore_case(user_msg, "/remember") &&
                (user_msg.size() == 9 ||
                 std::isspace(static_cast<unsigned char>(user_msg[9])) != 0)) {
                std::string thought = trim_view(user_msg.substr(9));
                if (thought.empty()) {
                    res.set_content(
                        "{\"response\":\"Say /remember followed by what I should keep.\"}",
                        "application/json");
                    return;
                }
                try {
                    json stored = memory::save_thought({{"content", thought}});
                    res.set_content(
                        json({
                                 {"response",
                                  "Remembered. I will use this in the next answers in this kernel process, and it is also a candidate Golden Record. run=" +
                                      stored.value("run_id", "")}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response", std::string("Could not remember that: ") + error.what()}}).dump(),
                        "application/json");
                }
                return;
            }
            auto handle_judgment = [&](const char* verb, const char* status, const std::string& rest) {
                const std::string trimmed = trim_view(rest);
                const size_t split = trimmed.find_first_of(" \t");
                const std::string id =
                    split == std::string::npos ? trimmed : trimmed.substr(0, split);
                const std::string reasoning =
                    split == std::string::npos ? "" : trim_view(trimmed.substr(split + 1));
                if (id.empty() || reasoning.size() < 4) {
                    res.set_content(
                        json({{"response",
                               std::string("Usage: /") + verb +
                                   " <id> <why it works or why it is junk>"}}).dump(),
                        "application/json");
                    return;
                }
                try {
                    json judged = memory::set_status({
                        {"id", id},
                        {"status", status},
                        {"reasoning", reasoning},
                    });
                    res.set_content(
                        json({{"response",
                               std::string(status) + " " + judged.value("stable_id", id) +
                                   " (" + judged.value("from", "") + " -> " +
                                   judged.value("to", status) + ")"}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response",
                               std::string("Could not judge that: ") + error.what()}}).dump(),
                        "application/json");
                }
            };

            if (starts_with_ignore_case(user_msg, "/verify") &&
                (user_msg.size() == 7 ||
                 std::isspace(static_cast<unsigned char>(user_msg[7])) != 0)) {
                handle_judgment("verify", "verified", user_msg.substr(7));
                return;
            }
            if (starts_with_ignore_case(user_msg, "/reject") &&
                (user_msg.size() == 7 ||
                 std::isspace(static_cast<unsigned char>(user_msg[7])) != 0)) {
                handle_judgment("reject", "rejected", user_msg.substr(7));
                return;
            }

            if (starts_with_ignore_case(user_msg, "/recall") &&
                (user_msg.size() == 7 ||
                 std::isspace(static_cast<unsigned char>(user_msg[7])) != 0)) {
                try {
                    std::ostringstream listing;
                    listing << "This session:\n";
                    const json session = memory::session_snapshot(8).value("thoughts", json::array());
                    if (session.empty()) {
                        listing << "(nothing remembered in this kernel process)\n";
                    } else {
                        for (const auto& thought : session) {
                            listing << "- [" << thought.value("status", "candidate") << "] "
                                    << thought.value("id", "") << " | "
                                    << thought.value("label", "") << "\n";
                        }
                    }
                    listing << "\nProjected Golden Records:\n";
                    try {
                        const json recent = memory::get_recent(8).value("thoughts", json::array());
                        if (recent.empty()) {
                            listing << "(none in the active projection)";
                        } else {
                            for (const auto& thought : recent) {
                                listing << "- [" << thought.value("status", "candidate")
                                        << " / " << thought.value("sector", "") << "] "
                                        << thought.value("label", thought.value("id", "")) << "\n";
                            }
                        }
                    } catch (const std::exception& error) {
                        listing << "(rag-service unavailable: " << error.what() << ")";
                    }
                    res.set_content(
                        json({{"response", listing.str()}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response", std::string("Recall failed: ") + error.what()}}).dump(),
                        "application/json");
                }
                return;
            }

            if (requests_privileged_dispatch(payload)) {
                if (g_api_token.empty()) {
                    std::cerr << "[KERNEL SECURITY] Rejected privileged command: GODBRAIN_API_TOKEN is not configured." << std::endl;
                    res.status = 403;
                    res.set_content("{\"status\":\"error\",\"message\":\"Privileged commands are disabled: server has no API token configured\"}", "application/json");
                    return;
                }
                std::string provided = extract_bearer_token(req);
                if (provided.empty()) {
                    res.status = 401;
                    res.set_content("{\"status\":\"error\",\"message\":\"Missing bearer token for privileged command\"}", "application/json");
                    return;
                }
                if (!token_matches(provided)) {
                    std::cerr << "[KERNEL SECURITY] Rejected privileged command: invalid bearer token." << std::endl;
                    res.status = 403;
                    res.set_content("{\"status\":\"error\",\"message\":\"Invalid bearer token\"}", "application/json");
                    return;
                }
                std::string cmd_type = payload["command_type"];
                json k_res = kernel_hub.dispatch(cmd_type, payload);
                res.set_content(k_res.dump(), "application/json");
                return;
            }

            std::cout << "[RAG] Canonical search requested (" << user_msg.size()
                      << " bytes)" << std::endl;
            std::string session_text;
            std::string session_error;
            if (!memory::render_session_context(session_text, session_error)) {
                std::cerr << "[MEMORY] Session context rejected: " << session_error
                          << std::endl;
                res.status = 503;
                res.set_content(
                    "{\"response\":\"Session memory is unavailable.\"}",
                    "application/json");
                return;
            }

            json search_response;
            std::string rag_error;
            std::string rag_text;
            const bool have_rag =
                rag_client.search(user_msg, search_response, rag_error) &&
                godbrain_rag::render_coli_notes(search_response, rag_text, rag_error);
            if (!have_rag) {
                std::cerr << "[RAG] Canonical search failed closed: " << rag_error
                          << std::endl;
                if (session_text.empty()) {
                    res.status = 503;
                    res.set_content(
                        "{\"response\":\"Canonical Golden Record retrieval is unavailable.\"}",
                        "application/json");
                    return;
                }
            }

            std::string context_text = rag_text;
            if (!session_text.empty()) {
                if (!context_text.empty()) context_text += '\n';
                context_text += session_text;
            }
            // 16 GB MoE prefill is ~13s/layer. A 3000-token note dump is a
            // 20 minute tax. Keep the oracle prompt small.
            constexpr size_t kMaxColiContextBytes = 500;
            if (context_text.size() > kMaxColiContextBytes) {
                context_text.resize(kMaxColiContextBytes);
            }

            const std::string hostname =
                telemetry::get_host_inventory().value("computer_name", "UNKNOWN");
            std::string system_prompt =
                "Oracle. Answer what is best-supported. Facts vs taste. "
                "Verified notes are evidence; candidates are claims. "
                "Hostname " +
                hostname +
                " is this PC, not a vehicle. Short answers.";
            std::string user_prompt = context_text + "\n\nUser Question: " + user_msg;

            std::cout << "[RAG] Context built (" << context_text.size()
                      << " bytes). Asking Colibri..." << std::endl;
            const bool want_stream =
                payload.value("stream", false) ||
                req.get_header_value("Accept").find("text/event-stream") !=
                    std::string::npos;
            if (want_stream) {
                const std::string sys = system_prompt;
                const std::string usr = user_prompt;
                const std::string asked = user_msg;
                res.set_header("Cache-Control", "no-cache");
                res.set_header("X-Accel-Buffering", "no");
                res.set_chunked_content_provider(
                    "text/event-stream",
                    [sys, usr, asked](size_t, httplib::DataSink& sink) {
                        auto emit = [&](const json& ev) {
                            const std::string line = "data: " + ev.dump() + "\n\n";
                            return sink.write(line.data(), line.size());
                        };
                        emit({{"type", "status"},
                              {"text",
                               "Prefill then decode. One GPU slot. "
                               "/status ticks while this runs."}});
                        const DWORD coli_started = GetTickCount();
                        std::string streamed;
                        DWORD last_partial = 0;
                        const std::string combined = run_colibri(
                            sys,
                            usr,
                            [&](const std::string& token) {
                                streamed += token;
                                emit({{"type", "token"}, {"text", token}});
                                const DWORD now = GetTickCount();
                                if (now - last_partial >= 5000) {
                                    last_partial = now;
                                    note_oracle_partial(
                                        asked,
                                        streamed,
                                        now - coli_started);
                                }
                            },
                            [&]() {
                                emit({{"type", "ping"},
                                      {"elapsed_s",
                                       static_cast<int>(
                                           (GetTickCount() - coli_started) /
                                           1000)}});
                            });
                        const std::string final_answer = strip_coli_reply(combined);
                        const DWORD elapsed = GetTickCount() - coli_started;
                        remember_oracle_turn(asked, final_answer, elapsed);
                        std::cout << "[COLIBRI] Reply in " << elapsed << " ms ("
                                  << combined.size() << " bytes)" << std::endl;
                        if (combined.compare(0, 6, "Error:") == 0) {
                            emit({{"type", "error"}, {"text", combined}});
                        } else {
                            emit({{"type", "done"}, {"response", final_answer}});
                        }
                        sink.done();
                        return true;
                    });
                return;
            }
            const DWORD coli_started = GetTickCount();
            const std::string combined = run_colibri(system_prompt, user_prompt);
            const std::string final_answer = strip_coli_reply(combined);
            remember_oracle_turn(
                user_msg, final_answer, GetTickCount() - coli_started);
            std::cout << "[COLIBRI] Reply in " << (GetTickCount() - coli_started)
                      << " ms (" << combined.size() << " bytes)" << std::endl;
            json resp;
            resp["response"] = final_answer;
            res.set_content(resp.dump(), "application/json");
        } catch (...) {
            res.status = 400;
            res.set_content("{\"response\":\"Parse error\"}", "application/json");
        }
    });

    const json tailscale = telemetry::get_tailscale();
    if (tailscale.value("up", false) && !g_api_token.empty()) {
        const std::string ip = tailscale.value("ip", "");
        std::thread([ip]() {
            httplib::Server door;
            attach_shortcut_routes(door);
            std::cout << "[SYS] Tailscale shortcuts door http://" << ip
                      << ":8083 (remember/observe/judge/status/last only)" << std::endl;
            if (!door.listen(ip, 8083)) {
                std::cerr << "[SYS] Tailscale bind failed on " << ip << ":8083"
                          << std::endl;
            }
        }).detach();
    } else if (tailscale.value("up", false)) {
        std::cout << "[SYS] Tailscale " << tailscale.value("ip", "")
                  << " is up; shortcuts door stays closed until GODBRAIN_API_TOKEN is set"
                  << std::endl;
    }

    std::cout << "[SYS] Listening on http://127.0.0.1:8083 (loopback only)" << std::endl;
    if (!svr.listen("127.0.0.1", 8083)) {
        std::cerr << "[SYS] FATAL: could not bind 127.0.0.1:8083 "
                     "(already running or port blocked)"
                  << std::endl;
        return 1;
    }
    return 0;
}
