#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
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
#include <set>
#include "rag_client.h"
#include "coli_sse.h"
#include "local_edit.h"
#include "kernel_request.h"
#include "memory.h"
#include "telemetry.h"

// 3 minute ceiling on a single Colibri invocation. Defined once so the wait
// timeout and the message we return on expiry can never drift apart.
static const DWORD COLIBRI_TIMEOUT_MS = 180000;
// One GPU slot. 160 tokens is one paging-safe decode. The kernel auto-continues
// up to 4 chunks so a normal answer finishes without the user babysitting.
static const int kColiChunkTokens = 160;
static const int kColiMaxChunks = 4;
// Gemma/llama on this 4080 Super decodes at ~140 tok/s with VRAM to spare.
// 160+tank-CONTINUE was for GLM paging; it makes 12B restate the system prompt.
static const int kLlamaChunkTokens = 1024;
static const int kLlamaMaxChunks = 2;
// 160 tokens at ~3s plus a 78-layer prefill misses 720s on this 16 GB box.
static const int kColiChunkTimeoutMs = 1200000;

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
    std::string stable_id;
    std::string status = "candidate";
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
static std::string format_brief_text();
static void handle_brief(const httplib::Request&, httplib::Response&);
static void handle_vram(const httplib::Request&, httplib::Response&);
static void handle_doors(const httplib::Request&, httplib::Response&);
static void handle_desk(const httplib::Request&, httplib::Response&);
static void handle_pending(const httplib::Request&, httplib::Response&);
static void handle_heal(const httplib::Request&, httplib::Response&);
static void handle_last_edit(const httplib::Request&, httplib::Response&);
static json pending_body();
static std::string clip_pending_line(std::string text, size_t max);
static int file_age_minutes(const std::string& path);
static json collect_pending_items(const json& turns, const json& host_rec);
static std::string resolve_judgment_id(const std::string& raw, std::string& error);
static json heal_status_body();
static bool is_displayable_oracle_turn(const LastOracleTurn& turn);
static LastOracleTurn display_oracle_turn(LastOracleTurn turn);
static std::string sanitize_oracle_body(std::string answer);
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
static json load_mouth();
static json load_last_edit();
static json load_heal_last();
static json load_last_desk_test();
static json gpu_desk();
static bool maybe_restart_mouth();
static bool cs2_should_sleep_mouth();
static bool maybe_bind_tailscale_door();
static bool tailscale_door_bound_to(const std::string& ip);
static json cs2_desk();

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

static int file_age_minutes(const std::string& path) {
    WIN32_FILE_ATTRIBUTE_DATA attrs{};
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &attrs)) {
        return -1;
    }
    FILETIME now_ft{};
    GetSystemTimeAsFileTime(&now_ft);
    ULARGE_INTEGER written{};
    ULARGE_INTEGER now{};
    written.LowPart = attrs.ftLastWriteTime.dwLowDateTime;
    written.HighPart = attrs.ftLastWriteTime.dwHighDateTime;
    now.LowPart = now_ft.dwLowDateTime;
    now.HighPart = now_ft.dwHighDateTime;
    if (now.QuadPart < written.QuadPart) return 0;
    return static_cast<int>(
        (now.QuadPart - written.QuadPart) / 10000000ull / 60ull);
}

static json oracle_turn_to_json(const LastOracleTurn& turn) {
    return {
        {"question", turn.question},
        {"answer", turn.answer},
        {"elapsed_ms", turn.elapsed_ms},
        {"ok", turn.ok},
        {"stored", turn.stored},
        {"complete", turn.complete},
        {"stable_id", turn.stable_id},
        {"status", turn.status},
    };
}

static json last_oracle_json() {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    for (auto it = g_oracle_turns.rbegin(); it != g_oracle_turns.rend(); ++it) {
        if (is_displayable_oracle_turn(*it)) {
            return oracle_turn_to_json(display_oracle_turn(*it));
        }
    }
    return json::object();
}

static json last_oracle_turns_json() {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    json turns = json::array();
    for (const auto& turn : g_oracle_turns) {
        if (!is_displayable_oracle_turn(turn)) continue;
        turns.push_back(oracle_turn_to_json(display_oracle_turn(turn)));
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
            turn.stable_id = item.value("stable_id", "");
            turn.status = item.value("status", "candidate");
            if (turn.question.empty() && turn.answer.empty()) continue;
            g_oracle_turns.push_back(std::move(turn));
        }
        if (g_oracle_turns.size() > kMaxOracleTurns) {
            g_oracle_turns.erase(
                g_oracle_turns.begin(),
                g_oracle_turns.begin() + static_cast<std::ptrdiff_t>(
                    g_oracle_turns.size() - kMaxOracleTurns));
        }
        bool cleaned = false;
        for (auto& turn : g_oracle_turns) {
            if (!turn.ok || turn.answer.empty()) continue;
            const std::string cleaned_a = sanitize_oracle_body(turn.answer);
            if (cleaned_a != turn.answer && !cleaned_a.empty()) {
                turn.answer = cleaned_a;
                cleaned = true;
            }
        }
        if (cleaned) persist_oracle_turns_locked();
        std::cout << "[MEMORY] Loaded " << g_oracle_turns.size()
                  << " oracle turns from " << path << std::endl;
    } catch (const json::exception& error) {
        std::cerr << "[MEMORY] last_oracle.json ignored: " << error.what()
                  << std::endl;
    }
}

static std::string oracle_turn_body(
    const std::string& question, const std::string& answer) {
    std::string body = "Oracle turn (candidate, not verified)\nQ: " + question +
                       "\nA: " + answer;
    if (body.size() > 2000) body.resize(2000);
    return body;
}

static void mark_oracle_stored(
    const std::string& question,
    const std::string& answer,
    const std::string& stable_id) {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    for (auto it = g_oracle_turns.rbegin(); it != g_oracle_turns.rend(); ++it) {
        if (it->question == question && it->answer == answer) {
            it->stored = true;
            if (!stable_id.empty()) it->stable_id = stable_id;
            break;
        }
    }
    persist_oracle_turns_locked();
}

static void store_oracle_turn_async(
    const std::string& question, const std::string& answer) {
    std::thread([question, answer]() {
        try {
            const json receipt = memory::save_thought(
                {{"content", oracle_turn_body(question, answer)},
                 {"sector", "oracle"}});
            mark_oracle_stored(question, answer, receipt.value("stable_id", ""));
        } catch (const std::exception& error) {
            std::cerr << "[MEMORY] oracle turn not stored: " << error.what()
                      << std::endl;
        }
    }).detach();
}

static std::string ensure_last_oracle_id() {
    LastOracleTurn turn;
    {
        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
        for (auto it = g_oracle_turns.rbegin(); it != g_oracle_turns.rend();
             ++it) {
            if (!is_displayable_oracle_turn(*it)) continue;
            turn = *it;
            break;
        }
        if (turn.question.empty() && turn.answer.empty()) return "";
        if (!turn.stable_id.empty()) return turn.stable_id;
    }
    if (!turn.ok || turn.answer.empty()) return "";
    const json receipt = memory::save_thought(
        {{"content", oracle_turn_body(turn.question, turn.answer)},
         {"sector", "oracle"}});
    const std::string stable_id = receipt.value("stable_id", "");
    mark_oracle_stored(turn.question, turn.answer, stable_id);
    return stable_id;
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
    turn.answer = answer.compare(0, 6, "Error:") == 0
                      ? answer
                      : sanitize_oracle_body(answer);
    turn.elapsed_ms = elapsed_ms;
    turn.ok = answer.compare(0, 6, "Error:") != 0;
    turn.stored = false;
    turn.complete = turn.ok && answer.find("[cut") == std::string::npos;
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

static std::string trim_copy(std::string value) {
    const auto not_space = [](unsigned char character) {
        return std::isspace(character) == 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
    return value;
}

static bool is_continue_command(const std::string& text) {
    std::string t = trim_copy(text);
    if (t.empty()) return false;
    if (t[0] == '/') t.erase(0, 1);
    for (char& ch : t) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return t == "continue" || t == "cont";
}

static bool is_refuse_answer(const std::string& answer) {
    return answer.find("I cannot fulfill") != std::string::npos ||
           answer.find("I cannot help with that") != std::string::npos ||
           answer.find("I cannot help with this") != std::string::npos;
}

static std::string strip_cut_marker(std::string answer) {
    const std::string marker = "[cut";
    const size_t pos = answer.find(marker);
    if (pos != std::string::npos) {
        answer.resize(pos);
    }
    return trim_copy(std::move(answer));
}

static std::string ascii_lower_copy(std::string value) {
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

static std::string normalize_heading_key(std::string line) {
    line = trim_copy(std::move(line));
    while (!line.empty() && (line[0] == '#' || line[0] == '*' ||
                             line[0] == ' ')) {
        line.erase(0, 1);
    }
    return ascii_lower_copy(trim_copy(std::move(line)));
}

// GLM got stuck repeating "### Verified Facts: Combat Record & Capabilities".
// Cut at the second copy of any heading, and split a ### glued onto a sentence.
static std::string trim_repetition_loop(std::string text) {
    const std::string glued = "### ";
    size_t glue = text.find(glued, 1);
    while (glue != std::string::npos) {
        if (text[glue - 1] != '\n') {
            text.insert(glue, "\n");
            glue += 1;
        }
        glue = text.find(glued, glue + 4);
    }

    std::istringstream in(text);
    std::string line;
    std::string kept;
    std::set<std::string> seen_headings;
    while (std::getline(in, line)) {
        std::string t = trim_copy(line);
        const bool heading =
            t.size() >= 3 && t[0] == '#' && t[1] == '#';
        if (heading) {
            const std::string key = normalize_heading_key(t);
            if (!key.empty() && seen_headings.count(key)) {
                return trim_copy(kept);
            }
            if (!key.empty()) seen_headings.insert(key);
        }
        kept += line;
        kept += '\n';
    }
    // Do not leave a bare ### heading as the continue anchor.
    for (;;) {
        kept = trim_copy(kept);
        if (kept.empty()) break;
        const size_t nl = kept.find_last_of('\n');
        const std::string last_line =
            nl == std::string::npos ? kept : trim_copy(kept.substr(nl + 1));
        if (last_line.size() >= 3 && last_line[0] == '#' && last_line[1] == '#') {
            kept = nl == std::string::npos ? std::string() : kept.substr(0, nl);
            continue;
        }
        break;
    }
    return trim_copy(std::move(kept));
}

static bool is_heading_loop(const std::string& text) {
    int verified = 0;
    int headings = 0;
    const std::string lower = ascii_lower_copy(text);
    for (size_t pos = 0;
         (pos = lower.find("verified facts", pos)) != std::string::npos;
         pos += 8) {
        ++verified;
    }
    for (size_t pos = 0;
         (pos = text.find("### ", pos)) != std::string::npos;
         pos += 4) {
        ++headings;
    }
    return verified >= 3 || headings >= 5;
}

// T-90AM/T-90AM/T-90AM... — same 6–32 char block three times in a row.
static bool find_ngram_loop(
    const std::string& text,
    size_t* at,
    size_t* unit,
    size_t* copies) {
    constexpr size_t kMin = 6;
    constexpr size_t kMax = 32;
    if (text.size() < kMin * 3) return false;
    for (size_t n = kMin; n <= kMax; ++n) {
        if (text.size() < n * 3) continue;
        for (size_t i = 0; i + n * 3 <= text.size(); ++i) {
            if (text.compare(i, n, text, i + n, n) != 0) continue;
            if (text.compare(i, n, text, i + 2 * n, n) != 0) continue;
            size_t k = 3;
            while (i + (k + 1) * n <= text.size() &&
                   text.compare(i, n, text, i + k * n, n) == 0) {
                ++k;
            }
            if (at) *at = i;
            if (unit) *unit = n;
            if (copies) *copies = k;
            return true;
        }
    }
    return false;
}

static bool is_ngram_loop(const std::string& text) {
    const std::string t =
        text.size() > 480 ? text.substr(text.size() - 480) : text;
    return find_ngram_loop(t, nullptr, nullptr, nullptr);
}

static bool is_resume_jail(const std::string& text) {
    return text.find("END>>") != std::string::npos ||
           text.find("Resume immediately after these exact characters") !=
               std::string::npos ||
           text.find("Do not mention the prompt, corrections") !=
               std::string::npos;
}

static bool is_generation_loop(const std::string& text) {
    return is_heading_loop(text) || is_ngram_loop(text) || is_resume_jail(text);
}

static std::string trim_ngram_loop(std::string text) {
    size_t at = 0;
    size_t unit = 0;
    size_t copies = 0;
    if (!find_ngram_loop(text, &at, &unit, &copies)) return text;
    return trim_copy(text.substr(0, at + unit));
}

static std::string sanitize_oracle_body(std::string answer) {
    answer = strip_cut_marker(std::move(answer));
    for (;;) {
        const size_t begin = answer.find("*(");
        if (begin == std::string::npos) break;
        const size_t end = answer.find(")*", begin);
        if (end == std::string::npos) break;
        answer.erase(begin, end + 2 - begin);
    }
    const char* kills[] = {
        "Wait, I made a mistake",
        "I made a mistake in the prompt",
        "**Correction",
        "Correction:",
        "I apologize for the confusion",
        "I need to finish the previous sentence",
        "This conversation is finished",
    };
    for (const char* kill : kills) {
        const size_t pos = answer.find(kill);
        if (pos != std::string::npos) answer.resize(pos);
    }
    return trim_ngram_loop(trim_repetition_loop(trim_copy(std::move(answer))));
}

static bool is_displayable_oracle_turn(const LastOracleTurn& turn) {
    if (!turn.ok || turn.answer.empty()) return false;
    if (is_continue_command(turn.question)) return false;
    if (turn.answer.compare(0, 6, "Error:") == 0) return false;
    if (is_refuse_answer(turn.answer)) return false;
    if (is_resume_jail(turn.answer)) return false;
    if (turn.answer.find("TABLESPACE") != std::string::npos) return false;
    if (turn.answer.find("Oracle Partition") != std::string::npos) return false;
    if (turn.answer.find("Understanding Oracle") != std::string::npos) {
        return false;
    }
    return sanitize_oracle_body(turn.answer).size() >= 40;
}

static LastOracleTurn display_oracle_turn(LastOracleTurn turn) {
    turn.answer = sanitize_oracle_body(turn.answer);
    return turn;
}

static std::string last_anchor(const std::string& text, size_t n = 90) {
    const std::string t = trim_copy(text);
    if (t.size() <= n) return t;
    return t.substr(t.size() - n);
}

static std::string continue_history_tail(const std::string& text, size_t n = 450) {
    const std::string t = trim_copy(text);
    if (t.size() <= n) return t;
    std::string tail = t.substr(t.size() - n);
    const size_t nl = tail.find('\n');
    if (nl != std::string::npos && nl + 1 < tail.size()) {
        tail = tail.substr(nl + 1);
    }
    return tail;
}

static bool looks_like_restart(const std::string& text) {
    const std::string t = ascii_lower_copy(trim_copy(text));
    if (t.compare(0, 14, "to determine if") == 0) return true;
    if (t.compare(0, 16, "this evaluation") == 0) return true;
    if (t.compare(0, 12, "analyze why") == 0) return true;
    if (t.compare(0, 15, "whether the m1") == 0) return true;
    if (t.find("### firepower") != std::string::npos &&
        t.find("analyze why") != std::string::npos) {
        return true;
    }
    return false;
}

static std::string last_coherent_essay(std::string text) {
    text = sanitize_oracle_body(std::move(text));
    const char* marks[] = {
        "To determine if",
        "This evaluation assesses",
        "### Firepower",
    };
    size_t last = std::string::npos;
    for (const char* mark : marks) {
        const size_t pos = text.rfind(mark);
        if (pos != std::string::npos &&
            (last == std::string::npos || pos > last)) {
            last = pos;
        }
    }
    if (last != std::string::npos && last > 80) {
        return trim_copy(text.substr(last));
    }
    return text;
}

static std::string make_continue_prompt(const std::string& prior) {
    return std::string(
               "Resume immediately after these exact characters. "
               "Write only new words. Do not restart the essay. "
               "Do not repeat the question. Do not repeat any earlier "
               "sentence, heading, or tank designation. "
               "Do not start a new ### heading. "
               "Next output must be a bullet or a finished sentence. "
               "Do not mention the prompt, corrections, mistakes, or "
               "Oracle Database. No parenthetical stage directions.\n\n"
               "END>>") +
           last_anchor(prior);
}

static bool wants_apply_continue(
    const std::string& system, const std::string& user) {
    if (system.find("apply blocks") != std::string::npos) return true;
    if (system.find("local file editor") != std::string::npos) return true;
    return local_edit::looks_like_edit_request(user);
}

static bool looks_unfinished(const std::string& text) {
    const std::string t = trim_copy(text);
    if (t.empty()) return true;
    const char end = t.back();
    return end != '.' && end != '!' && end != '?' && end != '"' && end != ')';
}

static std::string make_edit_continue_prompt(const std::string& prior) {
    return std::string(
               "Continue the repo patch. Emit only apply blocks, no essay:\n"
               "*** APPLY\n"
               "path: relative/from/repo\n"
               "<<<<\n"
               "exact old text\n"
               "====\n"
               "exact new text\n"
               ">>>>\n"
               "*** END\n\n"
               "Last tokens:\n") +
           last_anchor(prior);
}

static std::string strip_replayed_prefix(
    const std::string& prior, std::string next) {
    next = trim_copy(std::move(next));
    if (prior.empty() || next.empty()) return next;
    const size_t probe = prior.size() < 48 ? prior.size() : 48;
    if (next.compare(0, probe, prior, 0, probe) == 0) {
        size_t i = 0;
        const size_t n =
            prior.size() < next.size() ? prior.size() : next.size();
        while (i < n && prior[i] == next[i]) ++i;
        return trim_copy(next.substr(i));
    }
    const size_t max_ol =
        prior.size() < next.size() ? prior.size() : next.size();
    for (size_t len = max_ol; len >= 24; --len) {
        if (next.compare(0, len, prior, prior.size() - len, len) == 0) {
            return trim_copy(next.substr(len));
        }
    }
    return next;
}

// Last turn that is a real Q/A. Skip CONTINUE, serve-down errors, and refuses
// so a follow-up does not inherit Oracle-DB derails or "I cannot fulfill".
static bool find_last_real_oracle_turn(LastOracleTurn& out) {
    std::lock_guard<std::mutex> lock(g_last_oracle_mu);
    for (auto it = g_oracle_turns.rbegin(); it != g_oracle_turns.rend(); ++it) {
        if (!it->ok || it->question.empty() || it->answer.empty()) continue;
        if (is_continue_command(it->question)) continue;
        if (it->answer.compare(0, 6, "Error:") == 0) continue;
        if (is_refuse_answer(it->answer)) continue;
        if (is_resume_jail(it->answer)) continue;
        if (is_generation_loop(it->answer) &&
            sanitize_oracle_body(it->answer).size() < 80) {
            continue;
        }
        out = *it;
        if (is_generation_loop(it->answer)) {
            out.answer = sanitize_oracle_body(it->answer);
        }
        return true;
    }
    return false;
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
            maybe_bind_tailscale_door();
            tailscale["writes"] = "token_required";
            tailscale["bound"] = tailscale_door_bound_to(
                tailscale.value("ip", ""));
        }
    } else {
        tailscale["bound"] = false;
        if (tailscale.value("writes", "") == "") {
            tailscale["writes"] = "loopback_only";
        }
    }
    const json coli = coli_serve_status();
    bool mouth_restarting = false;
    if (!coli.value("up", false)) {
        mouth_restarting = maybe_restart_mouth();
    }
    json host = telemetry::get_host_inventory();
    const json live = telemetry::get_current_state();
    host["ram_available_gb"] = live.value("ram_available_gb", 0.0);
    host["ram_used_percent"] = live.value("system_ram_percent", 0);
    const json host_record = host_record_from_rag();
    const json turns = last_oracle_turns_json();
    int oracle_pending = 0;
    for (const auto& turn : turns) {
        if (turn.value("status", "candidate") == "candidate") ++oracle_pending;
    }
    const int host_pending =
        host_record.value("status", "") == "candidate" ? 1 : 0;
    json heal = load_heal_last();
    if (!heal.empty()) {
        heal["age_min"] = file_age_minutes(
            get_exe_dir() + "\\..\\..\\logs\\heal-last.json");
    }
    return {
        {"kernel", true},
        {"coli_serve", coli.value("up", false)},
        {"coli", coli},
        {"mouth", load_mouth()},
        {"mouth_restarting", mouth_restarting},
        {"writes_need_token", !g_api_token.empty()},
        {"vram", gpu_desk()},
        {"rag", rag_health},
        {"host", host},
        {"host_record", host_record},
        {"tailscale", tailscale},
        {"last_oracle", last_oracle_json()},
        {"last_oracle_turns", turns},
        {"last_edit", load_last_edit()},
        {"desk_test", load_last_desk_test()},
        {"heal", heal},
        {"cs2", cs2_desk()},
        {"pending_items", collect_pending_items(turns, host_record)},
        {"pending_judge", {
            {"oracle", oracle_pending},
            {"host", host_pending},
            {"total", oracle_pending + host_pending},
        }},
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

static std::string librarian_exe_path() {
    const std::string env = read_env("GODBRAIN_LIBRARIAN_PATH");
    if (!env.empty() && path_exists(env)) return env;
    return get_exe_dir() + "\\..\\cpp_tools\\librarian.exe";
}

static std::string safe_session_id(std::string value) {
    if (value.empty()) {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "door-%lu",
                      static_cast<unsigned long>(GetTickCount()));
        return buf;
    }
    for (char& ch : value) {
        const unsigned char c = static_cast<unsigned char>(ch);
        if (std::isalnum(c) == 0 && ch != '-' && ch != '_' && ch != '.') {
            ch = '-';
        }
    }
    if (value.size() > 64) value.resize(64);
    return value;
}

static void handle_librarian(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        if (cs2_should_sleep_mouth()) {
            res.status = 503;
            res.set_content(
                json({{"error",
                       "CS2 owns the box; Librarian waits. Use Start-CS2.cmd."}})
                    .dump(),
                "application/json");
            return;
        }
        const json coli = coli_serve_status();
        if (coli.value("busy", false)) {
            res.status = 503;
            res.set_content(
                json({{"error",
                       "mouth is generating (one GPU slot). Wait for serve."}})
                    .dump(),
                "application/json");
            return;
        }
        if (!coli.value("up", false)) {
            maybe_restart_mouth();
            res.status = 503;
            res.set_content(
                json({{"error",
                       "mouth is down on :8000. Starting it if llama. "
                       "Ask Librarian again in a minute."}})
                    .dump(),
                "application/json");
            return;
        }
        json payload = req.body.empty() ? json::object() : json::parse(req.body);
        std::string text = payload.value(
            "text", payload.value("message", payload.value("idea", "")));
        if (text.empty()) {
            res.status = 400;
            res.set_content(
                json({{"error", "librarian needs text"}}).dump(),
                "application/json");
            return;
        }
        if (text.size() > 15u * 1024u * 1024u) {
            res.status = 400;
            res.set_content(
                json({{"error", "text exceeds 15 MiB"}}).dump(),
                "application/json");
            return;
        }
        const std::string session =
            safe_session_id(payload.value("session_id", ""));
        const std::string exe = librarian_exe_path();
        if (!path_exists(exe)) {
            res.status = 503;
            res.set_content(
                json({{"error", "missing librarian.exe"}}).dump(),
                "application/json");
            return;
        }
        char tmp_dir[MAX_PATH] = {};
        if (GetTempPathA(MAX_PATH, tmp_dir) == 0) {
            throw std::runtime_error("GetTempPath failed");
        }
        const std::string tmp = std::string(tmp_dir) + "gb-lib-" + session + ".txt";
        {
            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
            if (!out) throw std::runtime_error("cannot write temp transcript");
            out << text;
        }
        std::string cmd = "\"" + exe + "\" \"" + session + "\" \"" + tmp + "\"";
        std::vector<char> cmdline(cmd.begin(), cmd.end());
        cmdline.push_back('\0');
        STARTUPINFOA si{};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi{};
        HANDLE job = CreateJobObjectA(nullptr, nullptr);
        if (job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli{};
            jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
        }
        const BOOL started = CreateProcessA(
            nullptr, cmdline.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &si, &pi);
        if (!started) {
            DeleteFileA(tmp.c_str());
            if (job) CloseHandle(job);
            throw std::runtime_error("CreateProcess librarian.exe failed");
        }
        if (job) AssignProcessToJobObject(job, pi.hProcess);
        ResumeThread(pi.hThread);
        const DWORD wait = WaitForSingleObject(pi.hProcess, 180000);
        if (wait == WAIT_TIMEOUT) {
            if (job) {
                CloseHandle(job);
                job = nullptr;
            }
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 5000);
        }
        DWORD code = 1;
        GetExitCodeProcess(pi.hProcess, &code);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        if (job) CloseHandle(job);
        DeleteFileA(tmp.c_str());
        if (wait == WAIT_TIMEOUT) {
            res.status = 504;
            res.set_content(
                json({{"error", "librarian timed out (180s)"},
                      {"session_id", session}})
                    .dump(),
                "application/json");
            return;
        }
        if (code != 0) {
            res.status = 502;
            res.set_content(
                json({{"error", "librarian failed"},
                      {"exit", code},
                      {"session_id", session}})
                    .dump(),
                "application/json");
            return;
        }
        res.set_content(
            json({{"ok", true},
                  {"session_id", session},
                  {"extractor_id", "Librarian-CPP"}})
                .dump(),
            "application/json");
    } catch (const json::exception&) {
        res.status = 400;
        res.set_content(
            json({{"error", "librarian body must be JSON"}}).dump(),
            "application/json");
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

static void handle_truth(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        json payload = req.body.empty() ? json::object() : json::parse(req.body);
        res.set_content(memory::promote_claim(payload).dump(), "application/json");
    } catch (const json::exception&) {
        res.status = 400;
        res.set_content(json({{"error", "truth body must be JSON"}}).dump(), "application/json");
    } catch (const std::exception& error) {
        res.status = 503;
        res.set_content(json({{"error", error.what()}}).dump(), "application/json");
    }
}

static std::string format_last_text() {
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
            const std::string id = turn.value("stable_id", "");
            reply << index << ". "
                  << turn.value("status", "candidate") << " "
                  << (turn.value("ok", false) ? "ok" : "fail")
                  << (turn.value("complete", true) ? "" : " partial")
                  << " " << (turn.value("elapsed_ms", 0) / 1000) << "s";
            if (!id.empty()) {
                reply << " " << id.substr(0, id.size() < 12 ? id.size() : 12);
            }
            reply << "\n  Q: "
                  << clip_pending_line(turn.value("question", ""), 80)
                  << "\n  A: "
                  << clip_pending_line(turn.value("answer", ""), 160)
                  << "\n";
        }
    }
    return reply.str();
}

static void handle_last(const httplib::Request&, httplib::Response& res) {
    const std::string text = format_last_text();
    json body = {
        {"last_oracle", last_oracle_json()},
        {"turns", last_oracle_turns_json()},
        {"response", text},
    };
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-oracle.txt";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << text;
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    res.set_content(body.dump(), "application/json");
}

static void handle_judge(const httplib::Request& req, httplib::Response& res) {
    if (!write_authorized(req, res)) return;
    try {
        json payload = req.body.empty() ? json::object() : json::parse(req.body);
        std::string raw_id = payload.value("id", payload.value("stable_id", ""));
        std::string resolve_err;
        const std::string resolved = resolve_judgment_id(raw_id, resolve_err);
        if (!resolve_err.empty() && resolved.empty()) {
            res.status = 400;
            res.set_content(json({{"error", resolve_err}}).dump(), "application/json");
            return;
        }
        json judged = memory::set_status({
            {"id", resolved.empty() ? raw_id : resolved},
            {"status", payload.value("status", "")},
            {"reasoning", payload.value("reasoning", payload.value("reason", ""))},
        });
        pending_body();
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
    server.Get("/api/brief", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_brief(req, res);
    });
    server.Get("/api/vram", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_vram(req, res);
    });
    server.Get("/api/heal", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_heal(req, res);
    });
    server.Get("/api/doors", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_doors(req, res);
    });
    server.Get("/api/desk", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_desk(req, res);
    });
    server.Get("/api/pending", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_pending(req, res);
    });
    server.Get("/api/last-edit", [](const httplib::Request& req, httplib::Response& res) {
        if (!write_authorized(req, res)) return;
        handle_last_edit(req, res);
    });
    server.Post("/api/remember", handle_remember);
    server.Post("/api/librarian", handle_librarian);
    server.Post("/api/observe", handle_observe);
    server.Post("/api/truth", handle_truth);
    server.Post("/api/judge", handle_judge);
}

static std::mutex g_tail_mu;
static std::string g_tail_bound_ip;
static std::atomic<bool> g_tail_bound{false};
static httplib::Server* g_tail_door = nullptr;
static std::thread g_tail_thread;

static void stop_tailscale_door() {
    httplib::Server* door = nullptr;
    std::thread th;
    {
        std::lock_guard<std::mutex> lock(g_tail_mu);
        door = g_tail_door;
        g_tail_door = nullptr;
        g_tail_bound.store(false, std::memory_order_relaxed);
        g_tail_bound_ip.clear();
        if (g_tail_thread.joinable()) th = std::move(g_tail_thread);
    }
    if (door) door->stop();
    if (th.joinable()) th.join();
    delete door;
}

static bool tailscale_door_bound_to(const std::string& ip) {
    if (ip.empty() || !g_tail_bound.load(std::memory_order_relaxed)) return false;
    std::lock_guard<std::mutex> lock(g_tail_mu);
    return g_tail_bound_ip == ip;
}

static bool maybe_bind_tailscale_door() {
    if (g_api_token.empty()) return false;
    const json ts = telemetry::get_tailscale();
    if (!ts.value("up", false)) return false;
    const std::string ip = ts.value("ip", "");
    if (ip.empty()) return false;
    {
        std::lock_guard<std::mutex> lock(g_tail_mu);
        if (g_tail_bound.load(std::memory_order_relaxed) && g_tail_bound_ip == ip) {
            return true;
        }
    }
    std::thread reap;
    {
        std::lock_guard<std::mutex> lock(g_tail_mu);
        if (!g_tail_bound.load(std::memory_order_relaxed) &&
            g_tail_thread.joinable()) {
            reap = std::move(g_tail_thread);
        }
    }
    if (reap.joinable()) reap.join();
    bool rebind = false;
    {
        std::lock_guard<std::mutex> lock(g_tail_mu);
        rebind = g_tail_bound.load(std::memory_order_relaxed) &&
                 g_tail_bound_ip != ip;
    }
    if (rebind) {
        std::cout << "[SYS] Tailscale door moving to " << ip << ":8083"
                  << std::endl;
        stop_tailscale_door();
    }
    std::lock_guard<std::mutex> lock(g_tail_mu);
    if (g_tail_bound.load(std::memory_order_relaxed) && g_tail_bound_ip == ip) {
        return true;
    }
    if (g_tail_bound.load(std::memory_order_relaxed)) return false;
    auto* door = new httplib::Server();
    attach_shortcut_routes(*door);
    if (!door->bind_to_port(ip, 8083)) {
        delete door;
        std::cerr << "[SYS] Tailscale bind failed on " << ip << ":8083"
                  << std::endl;
        return false;
    }
    g_tail_door = door;
    g_tail_bound_ip = ip;
    g_tail_bound.store(true, std::memory_order_relaxed);
    g_tail_thread = std::thread([door, ip]() {
        std::cout << "[SYS] Tailscale shortcuts door http://" << ip
                  << ":8083 (remember/librarian/observe/judge/status/last)"
                  << std::endl;
        door->listen_after_bind();
        bool owned = false;
        {
            std::lock_guard<std::mutex> inner(g_tail_mu);
            if (g_tail_door == door) {
                g_tail_door = nullptr;
                g_tail_bound.store(false, std::memory_order_relaxed);
                g_tail_bound_ip.clear();
                owned = true;
            }
        }
        if (owned) delete door;
    });
    return true;
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

static bool process_running_ci(const wchar_t* exe) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    bool hit = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, exe) == 0) {
                hit = true;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return hit;
}

static std::string repo_root_from_exe() {
    const std::string dir = get_exe_dir() + "\\..\\..";
    char canon[MAX_PATH] = {};
    if (GetFullPathNameA(dir.c_str(), MAX_PATH, canon, nullptr) == 0) return "";
    return std::string(canon);
}

static json read_cs2_pause_file() {
    const std::string path = repo_root_from_exe() + "\\logs\\cs2-pause.json";
    std::ifstream in(path);
    if (!in) return json::object();
    try {
        return json::parse(in);
    } catch (const json::exception&) {
        return json::object();
    }
}

static bool cs2_should_sleep_mouth() {
    if (process_running_ci(L"CS2.exe")) return true;
    const json st = read_cs2_pause_file();
    if (st.empty()) return false;
    if (st.value("last_seen", "").empty()) return false;
    return st.value("paused", false);
}

static json cs2_desk() {
    const bool running = process_running_ci(L"CS2.exe");
    const json st = read_cs2_pause_file();
    const bool paused = st.value("paused", false);
    const bool sleep = running || (paused && !st.value("last_seen", "").empty());
    return {
        {"running", running},
        {"paused", paused},
        {"sleep", sleep},
        {"last_action", st.value("last_action", "")},
    };
}

static std::atomic<DWORD> g_mouth_restart_ms{0};
// Start-LlamaServer kills every llama-server.exe. Galaxy polls /status often.
// Do not re-kick while weights are still loading or we just launched.
static const DWORD kMouthRestartCooldownMs = 300000;

static bool maybe_restart_mouth() {
    if (load_mouth().value("label", "") != "llama") return false;
    if (cs2_should_sleep_mouth()) return false;
    const DWORD now = GetTickCount();
    const DWORD last = g_mouth_restart_ms.load(std::memory_order_relaxed);
    if (last != 0 && now - last < kMouthRestartCooldownMs) return true;
    // Loading: :8000 is down but the process is up. Watch/Heal kill leftovers
    // after ~4 min. A /status poll must not race Start-LlamaServer.
    if (process_running_ci(L"llama-server.exe")) return true;
    const std::string repo = repo_root_from_exe();
    const std::string hidden = get_exe_dir() + "\\..\\cpp_tools\\run_hidden.exe";
    const std::string starter = repo + "\\Start-LlamaServer.ps1";
    const std::string pwsh = path_exists("C:\\pwsh\\pwsh.exe")
                                 ? "C:\\pwsh\\pwsh.exe"
                                 : "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    if (!path_exists(hidden) || !path_exists(starter) || !path_exists(pwsh)) {
        return false;
    }
    std::string cmd = "\"" + hidden + "\" \"" + pwsh +
                      "\" -NoProfile -WindowStyle Hidden -File \"" + starter +
                      "\" -RepoRoot \"" + repo + "\"";
    std::vector<char> buf(cmd.begin(), cmd.end());
    buf.push_back('\0');
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    if (!CreateProcessA(
            nullptr, buf.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, repo.c_str(),
            &si, &pi)) {
        return false;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    g_mouth_restart_ms.store(now, std::memory_order_relaxed);
    std::cout << "[SYS] mouth down; started Start-LlamaServer via run_hidden"
              << std::endl;
    return true;
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

static std::string load_where_we_are() {
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\where-we-are.md";
    std::ifstream in(path, std::ios::binary);
    if (!in) return "";
    std::ostringstream out;
    out << in.rdbuf();
    std::string text = out.str();
    if (text.size() > 900) {
        text.resize(900);
        text += "\n...";
    }
    return text;
}

static std::string format_brief_text() {
    const json st = kernel_status_body();
    const json host = st.value("host", json::object());
    const json coli = st.value("coli", json::object());
    const json rag = st.value("rag", json::object());
    const json last = st.value("last_oracle", json::object());
    std::ostringstream reply;
    const std::string where = load_where_we_are();
    if (!where.empty()) {
        reply << where;
        if (where.back() != '\n') reply << '\n';
        reply << "---\n";
    }
    const json mouth = st.value("mouth", json::object());
    const std::string mouth_label = mouth.value("label", "coli");
    const char* mouth_state = !coli.value("up", false)
        ? (st.value("mouth_restarting", false) ? "starting" : "down")
        : (coli.value("busy", false) ? "busy" : "serve");
    const json pending = st.value("pending_judge", json::object());
    const json heal = st.value("heal", json::object());
    reply << host.value("computer_name", "?") << " | "
          << mouth_label << "=" << mouth_state
          << " rag="
          << (rag.value("ready", false) ? "ready" : "down")
          << " judge=" << pending.value("total", 0);
    {
        const json turns = last_oracle_turns_json();
        for (const auto& turn : turns) {
            if (turn.value("status", "candidate") != "candidate") continue;
            const std::string nid = turn.value("stable_id", "");
            if (nid.empty()) continue;
            reply << " next=" << nid.substr(0, nid.size() < 12 ? nid.size() : 12);
            break;
        }
    }
    if (heal.contains("ok")) {
        const int heal_age = heal.value("age_min", file_age_minutes(
            get_exe_dir() + "\\..\\..\\logs\\heal-last.json"));
        if (heal_age > 20) {
            reply << " heal=stale/" << heal_age << "m";
        } else if (heal_age >= 0) {
            reply << " heal=" << (heal.value("ok", false) ? "ok" : "fail")
                  << "/" << heal_age << "m";
        } else {
            reply << " heal=" << (heal.value("ok", false) ? "ok" : "fail");
        }
    }
    const json tail = st.value("tailscale", json::object());
    if (tail.value("up", false)) {
        if (tail.value("bound", false)) {
            const std::string ip = tail.value("ip", "");
            reply << " tail=door";
            if (!ip.empty()) reply << "/" << ip;
        } else {
            reply << " tail=up";
        }
    } else if (tail.value("reason", "") == "needs_login") {
        reply << " tail=login";
    }
    const json cs2 = st.value("cs2", json::object());
    if (cs2.value("sleep", false)) {
        reply << " cs2="
              << (cs2.value("running", false) ? "play" : "sleep");
    }
    const json vram = st.value("vram", json::object());
    if (vram.contains("dedicated_gb")) {
        reply << " gpu=" << vram.value("dedicated_gb", 0)
              << "GB/" << vram.value("slots", 1) << "slot";
    }
    const json desk = st.value("desk_test", json::object());
    if (desk.contains("ok")) {
        reply << " desk=" << (desk.value("ok", false) ? "ok" : "fail");
    }
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
    const json edit = st.value("last_edit", json::object());
    if (edit.contains("report")) {
        reply << "\nedit "
              << (edit.value("applied", false) ? "done" : "fail");
    }
    const std::string text = reply.str();
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-brief.txt";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << text;
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    return text;
}

static void handle_brief(const httplib::Request&, httplib::Response& res) {
    res.set_content(
        json({{"response", format_brief_text()}}).dump(), "application/json");
}

static void handle_vram(const httplib::Request&, httplib::Response& res) {
    const json plan = gpu_desk();
    std::ostringstream reply;
    reply << plan.value("name", "GPU") << " / "
          << plan.value("dedicated_gb", 0) << " GB dedicated / "
          << plan.value("slots", 1) << " slot\n"
          << "mouth=" << plan.value("mouth_label", "?")
          << " " << plan.value("mouth_model", "") << "\n"
          << plan.value("worker", "") << "\n"
          << plan.value("next", "") << "\n"
          << "coli expert_gb=" << plan.value("expert_gb", 0)
          << " reserve=" << plan.value("reserve_gb", 0)
          << " overcommit="
          << (plan.value("overcommit", false) ? "on" : "off")
          << "\nOne generate at a time. Librarian shares this slot.";
    json body = plan;
    body["response"] = reply.str();
    body["slots"] = plan.value("slots", 1);
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-vram.json";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << body.dump(2);
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    res.set_content(body.dump(), "application/json");
}

static void handle_desk(const httplib::Request&, httplib::Response& res) {
    json body = load_last_desk_test();
    if (body.empty()) {
        res.status = 404;
        res.set_content(
            json({{"error", "no desk test yet"},
                  {"response", "desk=missing"}})
                .dump(),
            "application/json");
        return;
    }
    body["response"] = body.value("ok", false) ? "desk=ok" : "desk=fail";
    res.set_content(body.dump(), "application/json");
}

static void handle_last_edit(const httplib::Request&, httplib::Response& res) {
    json body = load_last_edit();
    std::ostringstream reply;
    if (body.empty()) {
        reply << "edit=missing";
        res.status = 404;
    } else {
        reply << "edit=" << (body.value("applied", false) ? "done" : "fail");
        const std::string report = body.value("report", "");
        if (!report.empty()) {
            reply << "\n" << clip_pending_line(report, 200);
        }
    }
    const std::string text = reply.str();
    body["response"] = text;
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-edit.txt";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << text;
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    res.set_content(body.dump(), "application/json");
}

static std::string clip_pending_line(std::string text, size_t max) {
    for (char& ch : text) {
        if (ch == '\r' || ch == '\n' || ch == '\t') ch = ' ';
    }
    while (!text.empty() && text.front() == ' ') text.erase(text.begin());
    while (!text.empty() && text.back() == ' ') text.pop_back();
    if (text.size() > max) {
        text.resize(max);
        text += "...";
    }
    return text;
}

static json collect_pending_items(const json& turns, const json& host_rec) {
    json items = json::array();
    for (const auto& turn : turns) {
        if (turn.value("status", "candidate") != "candidate") continue;
        items.push_back({
            {"kind", "oracle"},
            {"stable_id", turn.value("stable_id", "")},
            {"status", "candidate"},
            {"stored", turn.value("stored", false)},
            {"complete", turn.value("complete", true)},
            {"question", clip_pending_line(turn.value("question", ""), 80)},
            {"preview", clip_pending_line(turn.value("answer", ""), 120)},
        });
    }
    if (host_rec.value("status", "") == "candidate") {
        items.push_back({
            {"kind", "host"},
            {"stable_id", host_rec.value("stable_id", "")},
            {"status", "candidate"},
            {"stored", true},
            {"complete", true},
            {"question", ""},
            {"preview", clip_pending_line(host_rec.value("label", ""), 120)},
        });
    }
    return items;
}

static json pending_body() {
    const json turns = last_oracle_turns_json();
    const json rec = host_record_from_rag();
    json items = collect_pending_items(turns, rec);
    int oracle = 0;
    int host = 0;
    for (const auto& item : items) {
        if (item.value("kind", "") == "host") ++host;
        else ++oracle;
    }
    std::ostringstream reply;
    reply << "judge=" << items.size();
    if (items.empty()) {
        reply << " none waiting";
    } else {
        reply << " oracle=" << oracle << " host=" << host
              << "\n/verify <id> <why>  or  /verify last <why>";
        int index = 0;
        for (const auto& item : items) {
            ++index;
            const std::string id = item.value("stable_id", "");
            reply << "\n" << index << ". " << item.value("kind", "?");
            if (!id.empty()) {
                reply << " " << id.substr(0, id.size() < 12 ? id.size() : 12);
            } else {
                reply << " (no id)";
            }
            if (!item.value("complete", true)) reply << " partial";
            if (!item.value("stored", true)) reply << " unstored";
            const std::string question = item.value("question", "");
            const std::string preview = item.value("preview", "");
            if (!question.empty()) reply << "\n  Q: " << question;
            if (!preview.empty()) reply << "\n  " << preview;
        }
    }
    json body = {
        {"total", static_cast<int>(items.size())},
        {"oracle", oracle},
        {"host", host},
        {"items", items},
        {"response", reply.str()},
    };
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-pending.json";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << body.dump(2);
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    return body;
}

static void handle_pending(const httplib::Request&, httplib::Response& res) {
    res.set_content(pending_body().dump(), "application/json");
}

static bool ids_equal_ignore_case(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i]))) {
            return false;
        }
    }
    return true;
}

static bool id_has_prefix(const std::string& id, const std::string& prefix) {
    if (prefix.empty() || prefix.size() > id.size()) return false;
    for (size_t i = 0; i < prefix.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(id[i])) !=
            std::tolower(static_cast<unsigned char>(prefix[i]))) {
            return false;
        }
    }
    return true;
}

static std::vector<std::string> known_judgment_ids() {
    std::vector<std::string> ids;
    for (const auto& turn : last_oracle_turns_json()) {
        const std::string id = turn.value("stable_id", "");
        if (!id.empty()) ids.push_back(id);
    }
    const json rec = host_record_from_rag();
    const std::string host_id = rec.value("stable_id", "");
    if (!host_id.empty()) ids.push_back(host_id);
    return ids;
}

static std::string resolve_judgment_id(const std::string& raw, std::string& error) {
    error.clear();
    std::string id = raw;
    while (!id.empty() && std::isspace(static_cast<unsigned char>(id.front()))) {
        id.erase(id.begin());
    }
    while (!id.empty() && std::isspace(static_cast<unsigned char>(id.back()))) {
        id.pop_back();
    }
    if (id.empty()) {
        error = "id required";
        return "";
    }
    if (id.size() == 4 &&
        (id[0] == 'l' || id[0] == 'L') &&
        (id[1] == 'a' || id[1] == 'A') &&
        (id[2] == 's' || id[2] == 'S') &&
        (id[3] == 't' || id[3] == 'T')) {
        try {
            const std::string last = ensure_last_oracle_id();
            if (last.empty()) {
                error = "no complete Oracle turn on disk";
                return "";
            }
            return last;
        } catch (const std::exception& err) {
            error = err.what();
            return "";
        }
    }
    const auto known = known_judgment_ids();
    for (const auto& known_id : known) {
        if (ids_equal_ignore_case(known_id, id)) return known_id;
    }
    if (id.size() < 8) return id;
    std::vector<std::string> matches;
    for (const auto& known_id : known) {
        if (id_has_prefix(known_id, id)) matches.push_back(known_id);
    }
    if (matches.size() == 1) return matches[0];
    if (matches.size() > 1) {
        error = "ambiguous id prefix " + id;
        return "";
    }
    return id;
}

static void handle_doors(const httplib::Request&, httplib::Response& res) {
    const std::string lb = "http://127.0.0.1:8083";
    json loopback = {
        {"brief", lb + "/api/brief"},
        {"vram", lb + "/api/vram"},
        {"heal", lb + "/api/heal"},
        {"status", lb + "/api/status"},
        {"last", lb + "/api/last"},
        {"doors", lb + "/api/doors"},
        {"desk", lb + "/api/desk"},
        {"pending", lb + "/api/pending"},
        {"last_edit", lb + "/api/last-edit"},
        {"remember", lb + "/api/remember"},
        {"librarian", lb + "/api/librarian"},
        {"observe", lb + "/api/observe"},
        {"judge", lb + "/api/judge"},
    };
    const json tail = telemetry::get_tailscale();
    const std::string ip = tail.value("ip", "");
    json ts = {
        {"up", tail.value("up", false)},
        {"reason", tail.value("reason", "")},
        {"bound", tailscale_door_bound_to(ip)},
        {"ip", ip},
    };
    if (!ip.empty() && tail.value("up", false)) {
        const std::string base = "http://" + ip + ":8083";
        ts["brief"] = base + "/api/brief";
        ts["vram"] = base + "/api/vram";
        ts["heal"] = base + "/api/heal";
        ts["status"] = base + "/api/status";
        ts["last"] = base + "/api/last";
        ts["doors"] = base + "/api/doors";
        ts["desk"] = base + "/api/desk";
        ts["pending"] = base + "/api/pending";
        ts["last_edit"] = base + "/api/last-edit";
        ts["remember"] = base + "/api/remember";
        ts["librarian"] = base + "/api/librarian";
        ts["observe"] = base + "/api/observe";
        ts["judge"] = base + "/api/judge";
    }
    json body = {
        {"kernel", true},
        {"writes_need_token", !g_api_token.empty()},
        {"slots", 1},
        {"loopback", loopback},
        {"tailscale", ts},
    };
    const std::string dumped = body.dump(2);
    body["response"] = dumped;
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-doors.json";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << dumped;
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    res.set_content(body.dump(), "application/json");
}

static json load_mouth() {
    json mouth = {{"engine", "coli"}, {"label", "coli"}, {"model", ""}};
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\mouth.txt";
    std::ifstream in(path, std::ios::binary);
    if (!in) return mouth;
    std::string line;
    std::getline(in, line);
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n' ||
                             line.back() == ' ')) {
        line.pop_back();
    }
    if (line.empty()) return mouth;
    const auto space = line.find(' ');
    const std::string engine =
        ascii_lower_copy(space == std::string::npos ? line : line.substr(0, space));
    const std::string model =
        space == std::string::npos ? "" : line.substr(space + 1);
    if (engine.find("llama") != std::string::npos) {
        mouth["engine"] = "llama-server";
        mouth["label"] = "llama";
    } else {
        mouth["engine"] = engine;
        mouth["label"] = engine;
    }
    mouth["model"] = model;
    return mouth;
}

static json gpu_desk() {
    json plan = telemetry::plan_colibri_vram();
    const json mouth = load_mouth();
    const int gb = plan.value("dedicated_gb", 0);
    plan["slots"] = 1;
    plan["mouth_label"] = mouth.value("label", "");
    plan["mouth_model"] = mouth.value("model", "");
    if (gb < 24) {
        plan["worker"] = "Gemma 12B Q4 fits; default 27B Q4 does not";
        plan["next"] =
            "24 GB VRAM is the next worker (27B Q4), still one generate";
    } else {
        plan["worker"] = "24 GB+ can hold a default 27B Q4 worker";
        plan["next"] = "still one GPU slot; do not stack Librarian on chat";
    }
    return plan;
}

static json load_heal_last() {
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\heal-last.json";
    std::ifstream in(path, std::ios::binary);
    if (!in) return json::object();
    try {
        return json::parse(in);
    } catch (const json::exception&) {
        return json::object();
    }
}

static json load_last_edit() {
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-edit-result.json";
    std::ifstream in(path, std::ios::binary);
    if (!in) return json::object();
    try {
        return json::parse(in);
    } catch (const json::exception&) {
        return json::object();
    }
}

static json load_last_desk_test() {
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-desk-test.json";
    std::ifstream in(path, std::ios::binary);
    if (!in) return json::object();
    try {
        return json::parse(in);
    } catch (const json::exception&) {
        return json::object();
    }
}

static json heal_status_body() {
    json rag = json::object();
    httplib::Client rag_client("127.0.0.1", 8084);
    rag_client.set_connection_timeout(0, 200000);
    rag_client.set_read_timeout(1, 0);
    const bool rag_up = static_cast<bool>(rag_client.Get("/health"));
    const json coli = coli_serve_status();
    const json last = load_heal_last();
    const int age_min = file_age_minutes(
        get_exe_dir() + "\\..\\..\\logs\\heal-last.json");
    return {
        {"playbook", "host-listeners"},
        {"live",
         {{"kernel", true},
          {"rag", rag_up},
          {"coli", coli.value("up", false)},
          {"coli_busy", coli.value("busy", false)},
          {"mouth", coli.value("up", false)},
          {"mouth_busy", coli.value("busy", false)}}},
        {"last", last},
        {"age_min", age_min},
    };
}

static void handle_heal(const httplib::Request&, httplib::Response& res) {
    json heal = heal_status_body();
    const json live = heal.value("live", json::object());
    const json last = heal.value("last", json::object());
    std::ostringstream reply;
    reply << "playbook=host-listeners (never kills)\n"
          << "live kernel=" << (live.value("kernel", false) ? "up" : "down")
          << " rag=" << (live.value("rag", false) ? "up" : "down")
          << " mouth="
          << (live.value("mouth", live.value("coli", false))
                  ? (live.value("mouth_busy", live.value("coli_busy", false))
                         ? "busy"
                         : "serve")
                  : "down")
          << "\n";
    if (last.empty()) {
        reply << "no heal run recorded yet. Watch-GodBrain writes logs/heal-last.json";
    } else {
        const int age = heal.value("age_min", -1);
        reply << "last ok=" << (last.value("ok", false) ? "true" : "false")
              << " mouth=" << (last.value("mouth", false) ? "up" : "down")
              << " tail="
              << (last.value("tailscale", false) ? "100.x" : "off")
              << " cs2="
              << (last.value("cs2_sleep", false) ? "sleep" : "idle");
        if (age > 20) {
            reply << " age=stale/" << age << "m";
        } else if (age >= 0) {
            reply << " age=" << age << "m";
        }
        reply << " at=" << last.value("at", "") << "\n";
        const json needed = last.value("needed", json::array());
        reply << "needed=";
        if (needed.empty()) {
            reply << "(none)";
        } else {
            bool first = true;
            for (const auto& item : needed) {
                if (!first) reply << ",";
                first = false;
                if (item.is_string()) reply << item.get<std::string>();
            }
        }
        const json acted = last.value("acted", json::array());
        reply << "\nacted=";
        if (acted.empty()) {
            reply << "(none)";
        } else {
            bool first = true;
            for (const auto& item : acted) {
                if (!first) reply << ",";
                first = false;
                if (item.is_string()) reply << item.get<std::string>();
            }
        }
        const json diagnose = last.value("diagnose", json::object());
        if (!diagnose.empty()) {
            reply << "\nlayer=" << diagnose.value("layer", "?")
                  << " icmp="
                  << (diagnose.value("icmp_loopback", false) ? "ok" : "fail")
                  << " dns_self="
                  << (diagnose.value("dns_self", false) ? "ok" : "fail")
                  << " nic_tcpip="
                  << (diagnose.value("nic_tcpip", false) ? "ok" : "fail");
        }
    }
    const std::string text = reply.str();
    heal["response"] = text;
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\last-heal.txt";
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (out) {
            out << text;
            out.flush();
        }
    }
    MoveFileExA(tmp.c_str(), path.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    res.set_content(heal.dump(), "application/json");
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
        }
        // Serve replies have no PROFILE wrapper. Keep the full stitched
        // answer. The old last-500 trim ate auto-continued tank text.
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
    ColiPingFn on_ping = {},
    const std::string& prior_user = {},
    const std::string& prior_assistant = {},
    std::string* spoken = nullptr) {
    httplib::Client client(kColibriServeHost, kColibriServePort);
    client.set_connection_timeout(0, 500000);
    // Colibri pings empty deltas every ~10s during prefill. A 60s read
    // timeout then means the engine died, not that we are still paging.
    client.set_read_timeout(60, 0);
    client.set_write_timeout(5, 0);
    client.set_max_timeout(kColiChunkTimeoutMs);
    client.set_follow_location(false);

    const std::string model = []() {
        const std::string override_model = read_env("GODBRAIN_COLIBRI_MODEL");
        return override_model.empty() ? "glm-5.2-colibri" : override_model;
    }();
    json messages = json::array({json{{"role", "system"}, {"content", system}}});
    if (!prior_user.empty() && !prior_assistant.empty()) {
        messages.push_back(json{{"role", "user"}, {"content", prior_user}});
        messages.push_back(
            json{{"role", "assistant"}, {"content", prior_assistant}});
    }
    messages.push_back(json{{"role", "user"}, {"content", user}});
    httplib::Headers headers = {{"Accept", "text/event-stream"}};
    const std::string key = read_env("GODBRAIN_COLIBRI_KEY");
    const std::string coli_key = key.empty() ? read_env("COLI_API_KEY") : key;
    if (!coli_key.empty()) {
        headers.emplace("Authorization", "Bearer " + coli_key);
    }

    const bool llama_mouth = load_mouth().value("label", "") == "llama";
    const int chunk_tokens = llama_mouth ? kLlamaChunkTokens : kColiChunkTokens;
    const int max_chunks = llama_mouth ? kLlamaMaxChunks : kColiMaxChunks;

    std::string assembled;
    std::string last_reason;
    for (int chunk = 0; chunk < max_chunks; ++chunk) {
        json body = {
            {"model", model},
            {"stream", true},
            {"max_tokens", chunk_tokens},
            {"messages", messages},
        };
        // /edit apply pass: do not spend the 1024-token budget on think.
        if (llama_mouth && wants_apply_continue(system, user)) {
            body["chat_template_kwargs"] = {{"enable_thinking", false}};
        }
        std::string piece;
        std::string sse_buf;
        std::string finish_reason;
        bool heading_loop = false;
        g_coli_job_started_ms.store(GetTickCount(), std::memory_order_relaxed);
        const auto response = client.Post(
            "/v1/chat/completions", headers, body.dump(), "application/json",
            [&](const char* data, size_t len) {
                godbrain_coli::feed_sse(
                    sse_buf, data, len, piece, on_token, on_ping,
                    [&](const std::string& reason) { finish_reason = reason; },
                    spoken);
                if (is_generation_loop(piece)) {
                    heading_loop = true;
                    return false;
                }
                return true;
            });
        g_coli_job_started_ms.store(0, std::memory_order_relaxed);
        if (heading_loop) {
            piece = sanitize_oracle_body(piece);
            if (is_resume_jail(piece)) {
                const size_t cut = piece.find("END>>");
                if (cut != std::string::npos) piece.resize(cut);
                piece = sanitize_oracle_body(piece);
            }
            piece = strip_replayed_prefix(assembled, piece);
            assembled += piece;
            break;
        }
        if (!response) {
            assembled += strip_replayed_prefix(assembled, sanitize_oracle_body(piece));
            if (assembled.empty()) {
                return "Error: Colibri serve did not finish in 1200s. "
                       "GLM-5.2 is paging experts off disk on 16 GB. "
                       "Wait until /status shows coli=serve (not busy) and ask again.";
            }
            assembled += llama_mouth
                             ? "\n[cut — mouth dropped mid-generate. Ask again, do not Continue.]"
                             : "\n[cut — serve timed out, say continue]";
            return assembled;
        }
        if (response->status != 200) {
            assembled += piece;
            if (assembled.empty()) {
                return "Error: Colibri serve returned HTTP " +
                       std::to_string(response->status);
            }
            assembled += "\n[cut — serve HTTP " +
                         std::to_string(response->status) + ", say continue]";
            return assembled;
        }
        if (piece.empty()) {
            // Streaming already drained the body. Empty tokens on a later
            // auto-continue chunk means the model stopped, not a parse error.
            if (!response->body.empty()) {
                try {
                    const json parsed = json::parse(response->body);
                    piece = parsed.at("choices")
                                .at(0)
                                .at("message")
                                .at("content")
                                .get<std::string>();
                } catch (const json::exception&) {
                    if (assembled.empty()) {
                        return "Error: Colibri serve returned a malformed completion.";
                    }
                    break;
                }
            }
            if (piece.empty()) break;
        }
        piece = sanitize_oracle_body(piece);
        piece = strip_replayed_prefix(assembled, piece);
        assembled += piece;
        last_reason = finish_reason;
        if (heading_loop) break;
        if (finish_reason != "length") break;
        if (chunk + 1 >= max_chunks) break;
        // /edit: one plan chunk, then local_edit second pass.
        if (wants_apply_continue(system, user)) break;
        if (llama_mouth) {
            const std::string tail =
                (spoken && !spoken->empty()) ? *spoken : assembled;
            if (!looks_unfinished(tail)) break;
            messages.push_back(json{{"role", "assistant"}, {"content", piece}});
            messages.push_back(json{
                {"role", "user"},
                {"content",
                 "Finish only the last unfinished sentence. "
                 "No new outline. No constraint list. No bullets."}});
            continue;
        }
        messages.push_back(json{{"role", "assistant"}, {"content", piece}});
        messages.push_back(
            json{{"role", "user"}, {"content", make_continue_prompt(assembled)}});
    }
    if (last_reason == "length" && !llama_mouth) {
        assembled +=
            "\n[cut at 640 tokens — say continue]";
    }
    if (spoken && spoken->empty()) *spoken = assembled;
    return assembled;
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

    SetEnvironmentVariableA("SNAP", snap_env.empty() ? "C:\\nvme\\glm52-uncensored" : snap_env.c_str());
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
    ColiPingFn on_ping = {},
    const std::string& prior_user = {},
    const std::string& prior_assistant = {},
    std::string* spoken = nullptr) {
    const json coli = coli_serve_status();
    if (coli.value("up", false)) {
        if (coli.value("busy", false)) {
            std::cout << "[COLIBRI] Serve is busy; refusing to stack a second slot"
                      << std::endl;
            return "Error: Colibri is still generating the previous answer "
                   "(one GPU slot). Wait until /status shows coli=serve, then ask again.";
        }
        std::cout << "[COLIBRI] Persistent serve at 127.0.0.1:8000" << std::endl;
        return run_colibri_serve(
            system, user, on_token, on_ping, prior_user, prior_assistant,
            spoken);
    }
    std::cout << "[COLIBRI] Serve is down; refusing cold-spawn on 16 GB"
              << std::endl;
    const std::string mouth = load_mouth().value("label", "coli");
    const bool starting = maybe_restart_mouth();
    if (starting) {
        return "Error: " + mouth +
               " is down on 127.0.0.1:8000. Starting it. "
               "Ask again in about a minute. Do not Continue.";
    }
    return "Error: " + mouth +
           " is down on 127.0.0.1:8000. "
           "Run Start-LlamaServer.ps1 if the mouth is llama, or "
           "schtasks /Run /TN GodBrainLogon for coli. "
           "Do not Continue a dead generate. Ask the question again.";
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

    svr.Get("/api/brief", [&](const httplib::Request& req, httplib::Response& res) {
        handle_brief(req, res);
    });
    svr.Get("/api/vram", [&](const httplib::Request& req, httplib::Response& res) {
        handle_vram(req, res);
    });
    svr.Get("/api/doors", [&](const httplib::Request& req, httplib::Response& res) {
        handle_doors(req, res);
    });
    svr.Get("/api/desk", [&](const httplib::Request& req, httplib::Response& res) {
        handle_desk(req, res);
    });
    svr.Get("/api/last-edit", [&](const httplib::Request& req, httplib::Response& res) {
        handle_last_edit(req, res);
    });
    svr.Get("/api/pending", [&](const httplib::Request& req, httplib::Response& res) {
        handle_pending(req, res);
    });
    svr.Get("/api/last", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_last(req, res);
    });

    svr.Get("/api/heal", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_heal(req, res);
    });

    svr.Post("/api/remember", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_remember(req, res);
    });

    svr.Post("/api/librarian", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_librarian(req, res);
    });

    svr.Post("/api/truth", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(req, res);
        handle_truth(req, res);
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
                const json mouth = st.value("mouth", json::object());
                const std::string mouth_label = mouth.value("label", "coli");
                reply << (host.value("computer_name", "?")) << " / "
                      << host.value("total_physical_ram_gb", 0) << " GB / "
                      << host.value("logical_processors", 0) << " threads\n"
                      << "host_record=" << rec.value("status", "none") << "\n";
                const json pending = st.value("pending_judge", json::object());
                const json heal = st.value("heal", json::object());
                reply << "judge " << pending.value("total", 0) << " waiting";
                if (heal.contains("ok")) {
                    const int heal_age = heal.value("age_min", -1);
                    if (heal_age > 20) {
                        reply << " heal=stale/" << heal_age << "m";
                    } else if (heal_age >= 0) {
                        reply << " heal="
                              << (heal.value("ok", false) ? "ok" : "fail")
                              << "/" << heal_age << "m";
                    } else {
                        reply << " heal="
                              << (heal.value("ok", false) ? "ok" : "fail");
                    }
                }
                const json cs2 = st.value("cs2", json::object());
                if (cs2.value("sleep", false)) {
                    reply << " cs2="
                          << (cs2.value("running", false) ? "play" : "sleep");
                }
                reply << "\n";
                int pending_index = 0;
                for (const auto& item : st.value("pending_items", json::array())) {
                    ++pending_index;
                    const std::string id = item.value("stable_id", "");
                    reply << pending_index << ". " << item.value("kind", "?");
                    if (!id.empty()) {
                        reply << " " << id.substr(0, id.size() < 12 ? id.size() : 12);
                    } else {
                        reply << " (no id)";
                    }
                    const std::string q = item.value("question", "");
                    if (!q.empty()) reply << " " << q;
                    reply << "\n";
                }
                if (!coli.value("up", st.value("coli_serve", false))) {
                    reply << mouth_label
                          << (st.value("mouth_restarting", false) ? "=starting"
                                                                 : "=down");
                } else if (coli.value("busy", false)) {
                    reply << mouth_label << "=busy";
                    if (coli.contains("elapsed_s")) {
                        reply << " " << coli.value("elapsed_s", 0) << "s";
                    }
                    reply << " — generating, do not ask again";
                } else {
                    reply << mouth_label << "=serve";
                }
                if (!mouth.value("model", "").empty()) {
                    reply << " " << mouth.value("model", "");
                }
                if (mouth_label == "coli") {
                    reply << " active=" << coli.value("active", 0)
                          << " done=" << coli.value("completed", 0)
                          << " queued=" << coli.value("queued", 0);
                }
                reply << " rag=" << (rag.value("ready", false) ? "ready" : "down")
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
                const json edit = st.value("last_edit", json::object());
                if (edit.contains("report")) {
                    std::string report = edit.value("report", "");
                    if (report.size() > 80) report.resize(80);
                    reply << "edit " << (edit.value("applied", false) ? "done" : "fail")
                          << " " << report << "\n";
                }
                if (tail.value("up", false)) {
                    reply << "tailscale " << tail.value("ip", "") << " "
                          << (tail.value("bound", false) ? "door open" : "door closed")
                          << " " << tail.value("writes", "") << "\n";
                } else if (tail.value("reason", "") == "needs_login") {
                    reply << "tailscale needs login\n";
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

            if (starts_with_ignore_case(user_msg, "/last-edit") &&
                (user_msg.size() == 10 ||
                 std::isspace(static_cast<unsigned char>(user_msg[10])) != 0)) {
                handle_last_edit(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/last") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                handle_last(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/brief") &&
                (user_msg.size() == 6 ||
                 std::isspace(static_cast<unsigned char>(user_msg[6])) != 0)) {
                handle_brief(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/doors") &&
                (user_msg.size() == 6 ||
                 std::isspace(static_cast<unsigned char>(user_msg[6])) != 0)) {
                handle_doors(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/desk") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                handle_desk(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/pending") &&
                (user_msg.size() == 8 ||
                 std::isspace(static_cast<unsigned char>(user_msg[8])) != 0)) {
                handle_pending(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/heal") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                handle_heal(req, res);
                return;
            }

            if (starts_with_ignore_case(user_msg, "/vram") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                handle_vram(req, res);
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
                    reply << "Stored host inventory as a "
                          << stored.value("trust", "candidate")
                          << " Golden Record (live pin, no manual confirm).\n"
                          << "stable_id=" << stored.value("stable_id", "") << "\n"
                          << "os_pin=" << inventory.value("os_pin", "") << "\n"
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
                    const json stale = stored.value("stale", json::object());
                    if (stale.contains("stale")) {
                        reply << "\nstale_pins=" << stale.value("stale", 0);
                    }
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

            if (starts_with_ignore_case(user_msg, "/idea") &&
                (user_msg.size() == 5 ||
                 std::isspace(static_cast<unsigned char>(user_msg[5])) != 0)) {
                std::string thought = trim_view(user_msg.substr(5));
                if (thought.empty()) {
                    res.set_content(
                        "{\"response\":\"Say /idea followed by the idea. Stored as sector=idea candidate.\"}",
                        "application/json");
                    return;
                }
                try {
                    json stored = memory::save_thought(
                        {{"content", thought}, {"sector", "idea"}});
                    res.set_content(
                        json({{"response",
                               std::string("Idea stored (candidate, sector=idea). "
                                           "Not verified. stable_id=") +
                                   stored.value("stable_id", "")}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response",
                               std::string("Could not store idea: ") + error.what()}})
                            .dump(),
                        "application/json");
                }
                return;
            }

            if (starts_with_ignore_case(user_msg, "/ideas") &&
                (user_msg.size() == 6 ||
                 std::isspace(static_cast<unsigned char>(user_msg[6])) != 0)) {
                try {
                    std::ostringstream listing;
                    listing << "Idea candidates (not verified):\n";
                    int shown = 0;
                    const json recent =
                        memory::get_recent(25).value("thoughts", json::array());
                    for (const auto& thought : recent) {
                        if (thought.value("sector", "") != "idea") continue;
                        ++shown;
                        listing << "- [" << thought.value("status", "candidate")
                                << "] "
                                << thought.value("stable_id", thought.value("id", ""))
                                << " | " << thought.value("label", "") << "\n";
                    }
                    if (shown == 0) {
                        listing << "(none in the active projection yet)";
                    }
                    res.set_content(
                        json({{"response", listing.str()}}).dump(),
                        "application/json");
                } catch (const std::exception& error) {
                    res.status = 503;
                    res.set_content(
                        json({{"response",
                               std::string("Could not list ideas: ") + error.what()}})
                            .dump(),
                        "application/json");
                }
                return;
            }
            auto handle_judgment = [&](const char* verb, const char* status, const std::string& rest) {
                const std::string trimmed = trim_view(rest);
                const size_t split = trimmed.find_first_of(" \t");
                std::string id =
                    split == std::string::npos ? trimmed : trimmed.substr(0, split);
                const std::string reasoning =
                    split == std::string::npos ? "" : trim_view(trimmed.substr(split + 1));
                std::string resolve_err;
                const std::string resolved = resolve_judgment_id(id, resolve_err);
                if (!resolve_err.empty() && resolved.empty()) {
                    res.status = 400;
                    res.set_content(
                        json({{"response", resolve_err}}).dump(), "application/json");
                    return;
                }
                if (!resolved.empty()) id = resolved;
                if (id.empty() || reasoning.size() < 4) {
                    if (!id.empty() && reasoning.size() < 4) {
                        res.set_content(
                            json({{"response",
                                   std::string("Need a why (min 4) for ") + id}}).dump(),
                            "application/json");
                        return;
                    }
                    res.set_content(
                        json({{"response",
                               std::string("Usage: /") + verb +
                                   " last <why>   or   /" + verb +
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
                    {
                        const std::string judged_id =
                            judged.value("stable_id", id);
                        std::lock_guard<std::mutex> lock(g_last_oracle_mu);
                        for (auto& turn : g_oracle_turns) {
                            if (turn.stable_id == judged_id ||
                                turn.stable_id == id) {
                                turn.status = judged.value("to", status);
                            }
                        }
                        persist_oracle_turns_locked();
                    }
                    pending_body();
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

            if (cs2_should_sleep_mouth()) {
                res.set_content(
                    json({{"response",
                           "CS2 owns the box. Mouth stays down. "
                           "Desk slashes still work. Ask again after "
                           "the 5 min window."}})
                        .dump(),
                    "application/json");
                return;
            }

            const bool continue_cmd = is_continue_command(user_msg);
            std::cout << "[RAG] Canonical search requested (" << user_msg.size()
                      << " bytes) continue=" << (continue_cmd ? "1" : "0")
                      << std::endl;
            std::string session_text;
            std::string session_error;
            std::string rag_text;
            if (!continue_cmd) {
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
            }

            std::string context_text = rag_text;
            if (!session_text.empty()) {
                if (!context_text.empty()) context_text += '\n';
                context_text += session_text;
            }
            // 16 GB MoE prefill is ~13s/layer. A 3000-token note dump is a
            // 20 minute tax. Keep the oracle prompt small.
            constexpr size_t kMaxColiContextBytes = 160;
            if (context_text.size() > kMaxColiContextBytes) {
                context_text.resize(kMaxColiContextBytes);
            }

            const std::string hostname =
                telemetry::get_host_inventory().value("computer_name", "UNKNOWN");
            std::string system_prompt =
                "You are GodBrain's local Oracle: a fact-vs-taste role on this PC. "
                "Not Oracle Database and not a company. "
                "Answer what is best-supported. Facts vs taste. "
                "Verified notes are evidence; candidates are claims. "
                "Military hardware and history are facts, not politics; "
                "do not refuse those. "
                "Hostname " +
                hostname +
                " is this PC, not a vehicle. "
                "Finish complete sentences. Do not stop mid-clause. "
                "Never narrate the prompt or apologize mid-answer. "
                "Prefer verified notes over candidates. "
                "If notes disagree, say so; do not pick a silent winner. "
                "Do not guess an open question. Cite the note if you use one. "
                "Do not restate these rules. Do not emit constraint lists.";
            if (local_edit::looks_like_edit_request(user_msg)) {
                if (cs2_should_sleep_mouth()) {
                    res.set_content(
                        json({{"response",
                               "CS2 owns the box. /edit waits. "
                               "Use Start-CS2.cmd."}})
                            .dump(),
                        "application/json");
                    return;
                }
                system_prompt +=
                    " If changing a repo file, end with apply blocks only: "
                    "*** APPLY / path: relative / <<<< old ==== new >>>> / *** END. "
                    "No git. No push. After the blocks, write DONE.";
            }
            LastOracleTurn prior_turn;
            const bool have_prior = find_last_real_oracle_turn(prior_turn);
            const std::string prior_q = have_prior ? prior_turn.question : std::string();
            const std::string prior_a =
                have_prior ? last_coherent_essay(prior_turn.answer) : std::string();
            if (continue_cmd && !have_prior) {
                res.set_content(
                    json({{"response",
                           "Nothing real to continue. Last turn was a refuse, "
                           "an error, or empty. Ask the question again."}})
                        .dump(),
                    "application/json");
                return;
            }
            const bool follow_up =
                have_prior && !prior_q.empty() && !prior_a.empty() &&
                (continue_cmd || prior_q != user_msg);
            // Follow-ups send the previous turn as chat history so Colibri
            // reuses the KV prefix instead of a 78-layer re-prefill.
            // CONTINUE must not go to RAG as a new query (that is how
            // "Oracle" + "Continue" became SQL partitions).
            std::string user_prompt = user_msg;
            std::string asked = user_msg;
            if (continue_cmd) {
                asked = prior_q;
                user_prompt = local_edit::looks_like_edit_request(prior_q)
                                  ? make_edit_continue_prompt(prior_a)
                                  : make_continue_prompt(prior_a);
                context_text.clear();
            } else if (!follow_up && !context_text.empty()) {
                user_prompt = context_text + "\n\n" + user_msg;
            }

            std::cout << "[RAG] Context built (" << context_text.size()
                      << " bytes) follow_up=" << (follow_up ? "1" : "0")
                      << " continue=" << (continue_cmd ? "1" : "0")
                      << ". Asking Colibri..." << std::endl;
            const bool want_stream =
                payload.value("stream", false) ||
                req.get_header_value("Accept").find("text/event-stream") !=
                    std::string::npos;
            auto stitch_continue = [continue_cmd, prior_a](const std::string& next) {
                if (!continue_cmd || prior_a.empty()) return next;
                if (next.compare(0, 6, "Error:") == 0) return next;
                const std::string added =
                    strip_replayed_prefix(prior_a, sanitize_oracle_body(next));
                if (added.empty()) return prior_a;
                // A full restart is a new draft, not a suffix. Gluing it
                // reprints the whole Abrams essay in Galaxy.
                if (looks_like_restart(added)) return added;
                return prior_a + added;
            };
            if (want_stream) {
                const std::string sys = system_prompt;
                const std::string usr = user_prompt;
                const std::string asked_q = asked;
                const std::string hist_q = follow_up ? prior_q : std::string();
                const std::string hist_a =
                    follow_up
                        ? (continue_cmd ? continue_history_tail(prior_a)
                                        : prior_a)
                        : std::string();
                res.set_header("Cache-Control", "no-cache");
                res.set_header("X-Accel-Buffering", "no");
                res.set_chunked_content_provider(
                    "text/event-stream",
                    [sys, usr, asked_q, hist_q, hist_a, stitch_continue](
                        size_t, httplib::DataSink& sink) {
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
                        std::string spoken;
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
                                        asked_q,
                                        stitch_continue(streamed),
                                        now - coli_started);
                                }
                            },
                            [&]() {
                                const int elapsed_s = static_cast<int>(
                                    (GetTickCount() - coli_started) / 1000);
                                emit({{"type", "ping"},
                                      {"elapsed_s",
                                       elapsed_s < 1 ? 1 : elapsed_s}});
                            },
                            hist_q,
                            hist_a,
                            &spoken);
                        std::string chunk = strip_coli_reply(combined);
                        const std::string for_memory =
                            spoken.empty() ? chunk : strip_coli_reply(spoken);
                        const auto edit = local_edit::maybe_apply(
                            asked_q,
                            for_memory,
                            [&](const std::string& sys, const std::string& usr) {
                                emit({{"type", "status"},
                                      {"text",
                                       "Plan saved in RAM. Second pass on "
                                       "the GPU: emit the patch only."}});
                                std::string spoken2;
                                const std::string raw =
                                    run_colibri(sys, usr, {}, {}, {}, {}, &spoken2);
                                return spoken2.empty() ? raw : spoken2;
                            });
                        if (edit.attempted) {
                            chunk += "\n\n";
                            chunk += edit.report;
                            emit({{"type", "token"}, {"text", "\n\n" + edit.report}});
                        }
                        std::string mem = for_memory;
                        if (edit.attempted) {
                            if (!mem.empty()) mem += "\n\n";
                            mem += edit.report;
                        }
                        const std::string final_answer = stitch_continue(mem);
                        const DWORD elapsed = GetTickCount() - coli_started;
                        remember_oracle_turn(asked_q, final_answer, elapsed);
                        std::cout << "[COLIBRI] Reply in " << elapsed << " ms ("
                                  << combined.size() << " bytes)" << std::endl;
                        if (combined.compare(0, 6, "Error:") == 0) {
                            emit({{"type", "error"}, {"text", combined}});
                        } else {
                            // Stream already showed new tokens. Do not replace
                            // the bubble with the stitched prior+new dump.
                            emit({{"type", "done"}, {"response", chunk}});
                        }
                        sink.done();
                        return true;
                    });
                return;
            }
            const DWORD coli_started = GetTickCount();
            std::string spoken;
            const std::string combined = run_colibri(
                system_prompt,
                user_prompt,
                {},
                {},
                follow_up ? prior_q : std::string(),
                follow_up ? (continue_cmd ? continue_history_tail(prior_a)
                                          : prior_a)
                          : std::string(),
                &spoken);
            std::string chunk = strip_coli_reply(combined);
            const std::string for_memory =
                spoken.empty() ? chunk : strip_coli_reply(spoken);
            const auto edit = local_edit::maybe_apply(
                asked,
                for_memory,
                [&](const std::string& sys, const std::string& usr) {
                    std::string spoken2;
                    const std::string raw =
                        run_colibri(sys, usr, {}, {}, {}, {}, &spoken2);
                    return spoken2.empty() ? raw : spoken2;
                });
            if (edit.attempted) {
                chunk += "\n\n";
                chunk += edit.report;
            }
            std::string mem = for_memory;
            if (edit.attempted) {
                if (!mem.empty()) mem += "\n\n";
                mem += edit.report;
            }
            const std::string final_answer = stitch_continue(mem);
            remember_oracle_turn(
                asked, final_answer, GetTickCount() - coli_started);
            std::cout << "[COLIBRI] Reply in " << (GetTickCount() - coli_started)
                      << " ms (" << combined.size() << " bytes)" << std::endl;
            json resp;
            resp["response"] = continue_cmd ? chunk : final_answer;
            res.set_content(resp.dump(), "application/json");
        } catch (...) {
            res.status = 400;
            res.set_content("{\"response\":\"Parse error\"}", "application/json");
        }
    });

    if (maybe_bind_tailscale_door()) {
        std::cout << "[SYS] Tailscale shortcuts door requested" << std::endl;
    } else {
        const json tailscale = telemetry::get_tailscale();
        if (tailscale.value("up", false) && g_api_token.empty()) {
            std::cout << "[SYS] Tailscale " << tailscale.value("ip", "")
                      << " is up; shortcuts door stays closed until GODBRAIN_API_TOKEN is set"
                      << std::endl;
        } else if (tailscale.value("reason", "") == "needs_login") {
            std::cout << "[SYS] Tailscale adapter up but not logged in; "
                         "phone door waits for a 100.x address"
                      << std::endl;
        }
    }

    std::cout << "[SYS] Listening on http://127.0.0.1:8083 (loopback only)" << std::endl;
    if (!svr.listen("127.0.0.1", 8083)) {
        std::cerr << "[SYS] FATAL: could not bind 127.0.0.1:8083 "
                     "(already running or port blocked)"
                  << std::endl;
        stop_tailscale_door();
        return 1;
    }
    stop_tailscale_door();
    return 0;
}
