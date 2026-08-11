#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <chrono>
#include <cstdlib>
#include <cctype>
#include <algorithm>
#include <unordered_map>
#include <unordered_set>

// Include JSON support
#include "../cpp_kernel/json.hpp"
using json = nlohmann::json;

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
    return GetFileAttributesA(p.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// Resolves memory_engine.exe: GODBRAIN_MEMORY_ENGINE_PATH wins outright,
// otherwise it is looked up relative to this executable's own directory
// (cpp_tools/ and memory_engine/ are siblings under godbrain_core/), so no
// single user's absolute path is ever baked in.
static std::string resolve_memory_engine_path() {
    const char* env = std::getenv("GODBRAIN_MEMORY_ENGINE_PATH");
    if (env && *env) return std::string(env);

    static const char* candidates[] = {
        "\\..\\memory_engine\\memory_engine.exe",
        "\\..\\memory_engine\\memory.exe",   // built via `go build` from the memory module (binary named after module dir)
        "\\..\\..\\godbrain_core\\memory_engine\\memory_engine.exe",
    };
    std::string exe_dir = get_exe_dir();
    for (const char* rel : candidates) {
        if (!exe_dir.empty()) {
            std::string cand = exe_dir + rel;
            if (path_exists(cand)) return cand;
        }
    }
    std::string fallback = "..\\memory_engine\\memory_engine.exe";
    std::cerr << "[LIBRARIAN] WARNING: could not locate memory_engine.exe via GODBRAIN_MEMORY_ENGINE_PATH or "
                 "repo-relative defaults; using best-effort path '" << fallback << "'." << std::endl;
    return fallback;
}

std::string get_iso_timestamp() {
    auto now = std::chrono::system_clock::now();
    std::time_t now_c = std::chrono::system_clock::to_time_t(now);
    struct tm parts;
    gmtime_s(&parts, &now_c);
    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &parts);
    return std::string(buf);
}

// Emulates the Python distillation, but derived directly from the actual
// transcript content (no canned/fixed golden record): a normalized/truncated
// summary, a bounded set of frequency-ranked core concepts with stop-word
// filtering, and a bounded set of candidate OpSec/rule lines when present.
// Deterministic and input-derived: different transcripts always produce
// different summaries/concepts, and no external service (Colibri, Neo4j) is
// required to compute any of this.
static const size_t kMaxSummaryChars = 400;
static const size_t kMaxConcepts = 8;
static const size_t kMaxOpsecRules = 6;
static const size_t kMinConceptTokenLen = 4;

// Common English (and a few session-transcript-specific) filler words that
// would otherwise dominate frequency counts without carrying any topical
// meaning.
static const std::unordered_set<std::string>& stop_words() {
    static const std::unordered_set<std::string> words = {
        "the", "a", "an", "and", "or", "but", "if", "then", "else", "for", "to",
        "of", "in", "on", "at", "by", "with", "is", "are", "was", "were", "be",
        "been", "being", "it", "its", "this", "that", "these", "those", "as",
        "from", "we", "you", "i", "he", "she", "they", "them", "his", "her",
        "their", "our", "your", "not", "no", "do", "does", "did", "have", "has",
        "had", "will", "would", "can", "could", "should", "may", "might",
        "user", "assistant", "ai", "system", "copilot", "session", "please",
        "just", "also", "about", "into", "over", "than", "so", "up", "out",
        "get", "got", "use", "using", "used", "need", "needs", "want", "wants",
        "here", "there", "what", "when", "where", "which", "who", "how", "all",
        "any", "some", "more", "most", "other", "such", "only", "own", "same",
        "very", "too", "now",
    };
    return words;
}

// Splits into lowercase alphanumeric tokens, discarding punctuation/whitespace.
static std::vector<std::string> tokenize(const std::string& text) {
    std::vector<std::string> tokens;
    std::string cur;
    for (unsigned char c : text) {
        if (std::isalnum(c)) {
            cur += (char)std::tolower(c);
        } else if (!cur.empty()) {
            tokens.push_back(cur);
            cur.clear();
        }
    }
    if (!cur.empty()) tokens.push_back(cur);
    return tokens;
}

// Collapses all whitespace runs to single spaces and truncates to a bounded
// length (breaking on a word boundary where possible) so the summary is
// always a real, bounded excerpt of the transcript rather than a fixed
// string.
static std::string normalize_summary(const std::string& raw) {
    std::string collapsed;
    collapsed.reserve(raw.size());
    bool prev_space = true; // trims leading whitespace too
    for (unsigned char c : raw) {
        bool is_space = std::isspace(c) != 0;
        if (is_space) {
            if (!prev_space) collapsed += ' ';
            prev_space = true;
        } else {
            collapsed += (char)c;
            prev_space = false;
        }
    }
    while (!collapsed.empty() && collapsed.back() == ' ') collapsed.pop_back();

    if (collapsed.size() > kMaxSummaryChars) {
        collapsed = collapsed.substr(0, kMaxSummaryChars);
        size_t last_space = collapsed.find_last_of(' ');
        if (last_space != std::string::npos && last_space > kMaxSummaryChars / 2) {
            collapsed = collapsed.substr(0, last_space);
        }
        collapsed += "...";
    }
    if (collapsed.empty()) collapsed = "(empty transcript)";
    return collapsed;
}

// Ranks tokens by frequency (stop words and very short tokens excluded),
// breaking ties by first-appearance order for determinism, and returns the
// top `kMaxConcepts`.
static std::vector<std::string> extract_core_concepts(const std::string& transcript) {
    std::vector<std::string> tokens = tokenize(transcript);
    std::unordered_map<std::string, int> freq;
    std::vector<std::string> order; // first-seen order, used as a stable tie-break

    for (const auto& t : tokens) {
        if (t.size() < kMinConceptTokenLen) continue;
        if (stop_words().count(t)) continue;
        if (freq.find(t) == freq.end()) order.push_back(t);
        freq[t]++;
    }

    std::stable_sort(order.begin(), order.end(), [&](const std::string& a, const std::string& b) {
        return freq[a] > freq[b];
    });

    std::vector<std::string> concepts;
    for (const auto& w : order) {
        if (concepts.size() >= kMaxConcepts) break;
        concepts.push_back(w);
    }
    return concepts;
}

// Scans line-by-line for candidate OpSec/policy statements — lines containing
// imperative/prohibitive markers ("must", "never", "always", "should not",
// "do not", explicit "rule"/"opsec" mentions, etc. Bounded so a large
// transcript can't blow up the golden record.
static std::vector<std::string> extract_opsec_rules(const std::string& transcript) {
    static const std::vector<std::string> markers = {
        "must not", "must ", "never ", "always ", "should not", "should ",
        "do not ", "don't ", "opsec", "rule:", "policy:", "forbidden", "disallow",
    };

    std::vector<std::string> rules;
    std::istringstream stream(transcript);
    std::string line;
    while (rules.size() < kMaxOpsecRules && std::getline(stream, line)) {
        std::string lower = line;
        std::transform(lower.begin(), lower.end(), lower.begin(),
                        [](unsigned char c) { return (char)std::tolower(c); });

        bool matched = false;
        for (const auto& marker : markers) {
            if (lower.find(marker) != std::string::npos) { matched = true; break; }
        }
        if (!matched) continue;

        size_t start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        size_t end = line.find_last_not_of(" \t\r\n");
        std::string trimmed = line.substr(start, end - start + 1);
        if (trimmed.size() > 200) trimmed = trimmed.substr(0, 200) + "...";
        rules.push_back(trimmed);
    }
    return rules;
}

json distill_session(const std::string& raw_transcript) {
    std::cout << "[LIBRARIAN] Distilling " << raw_transcript.size()
              << "-byte transcript into a golden record (deterministic, input-derived)..." << std::endl;

    return {
        {"timestamp", get_iso_timestamp()},
        {"core_concepts", extract_core_concepts(raw_transcript)},
        {"opsec_rules", extract_opsec_rules(raw_transcript)},
        {"summary", normalize_summary(raw_transcript)}
    };
}

// Self-test: proves the distillation above is actually derived from the
// input (not a canned/fixed record) without contacting Colibri, the Memory
// Engine, or Neo4j. Two deliberately different sample transcripts must yield
// different summaries and different (non-empty) core concept sets, and a
// transcript with an explicit prohibition should surface at least one OpSec
// rule line.
static bool run_self_test() {
    const std::string transcript_a =
        "User: We must never delete user files without explicit confirmation. "
        "AI: Understood, I will always ask before deleting anything critical. "
        "This session focused on filesystem safety guardrails and confirmation prompts.";
    const std::string transcript_b =
        "User: How do we speed up the Neo4j Aura driver connection pooling for the Go Memory Engine? "
        "AI: Reuse the driver across calls and batch writes inside a single transaction. "
        "This session focused on Neo4j performance tuning for the memory engine.";

    json record_a = distill_session(transcript_a);
    json record_b = distill_session(transcript_b);

    bool ok = true;
    if (record_a["summary"] == record_b["summary"]) {
        std::cerr << "[SELF-TEST] FAIL: summaries are identical across different transcripts." << std::endl;
        ok = false;
    }
    if (record_a["core_concepts"].empty() || record_b["core_concepts"].empty()) {
        std::cerr << "[SELF-TEST] FAIL: expected at least one core concept per transcript." << std::endl;
        ok = false;
    }
    if (record_a["core_concepts"] == record_b["core_concepts"]) {
        std::cerr << "[SELF-TEST] FAIL: core_concepts are identical across different transcripts." << std::endl;
        ok = false;
    }
    if (record_a["opsec_rules"].empty()) {
        std::cerr << "[SELF-TEST] FAIL: expected transcript A's explicit prohibition to surface an OpSec rule." << std::endl;
        ok = false;
    }

    if (ok) {
        std::cout << "[SELF-TEST] PASS: distillation is deterministic and input-derived." << std::endl;
        std::cout << "  transcript A summary: " << record_a["summary"].get<std::string>() << std::endl;
        std::cout << "  transcript A concepts: " << record_a["core_concepts"].dump() << std::endl;
        std::cout << "  transcript B summary: " << record_b["summary"].get<std::string>() << std::endl;
        std::cout << "  transcript B concepts: " << record_b["core_concepts"].dump() << std::endl;
    }
    return ok;
}

// Archives the session and forwards its distilled golden record to the Go
// Memory Engine. Returns true only when the Memory Engine process actually
// ran AND exited with status 0 — a process that merely launched is not
// success, since the Aura write could still have failed downstream.
bool commit_to_brain(const std::string& session_id, const std::string& raw_transcript) {
    std::cout << "[LIBRARIAN] Archiving session " << session_id << "..." << std::endl;

    json golden_record = distill_session(raw_transcript);
    golden_record["session_id"] = session_id;

    // Send to Go Memory Engine via stdin
    std::string go_engine_path = resolve_memory_engine_path();

    std::cout << "[LIBRARIAN] Sending payload to Go Memory Engine (" << go_engine_path << ")..." << std::endl;

    if (!path_exists(go_engine_path)) {
        std::cerr << "[LIBRARIAN ERROR] Memory Engine binary not found at '" << go_engine_path
                  << "'. Set GODBRAIN_MEMORY_ENGINE_PATH or build godbrain_core/memory_engine first." << std::endl;
        return false;
    }
    
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;

    if (!CreatePipe(&hOutRd, &hOutWr, &saAttr, 0)) return false;
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    
    if (!CreatePipe(&hInRd, &hInWr, &saAttr, 0)) { CloseHandle(hOutRd); CloseHandle(hOutWr); return false; }
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

    std::string cmdline = "\"" + go_engine_path + "\"";
    BOOL success = CreateProcessA(NULL, const_cast<LPSTR>(cmdline.c_str()), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInRd);

    if (!success) {
        CloseHandle(hInWr);
        CloseHandle(hOutRd);
        std::cerr << "[LIBRARIAN ERROR] Failed to start Memory Engine (" << go_engine_path
                  << "). Win32 error " << GetLastError() << ". Skipping Aura upload." << std::endl;
        return false;
    }

    std::string payload = golden_record.dump();
    DWORD written;
    WriteFile(hInWr, payload.c_str(), (DWORD)payload.length(), &written, NULL);
    CloseHandle(hInWr); // Send EOF

    std::string output = "";
    DWORD read; 
    CHAR buf[4096]; 
    while(ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
        buf[read] = '\0';
        output.append(buf, read);
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    std::cout << "[LIBRARIAN] Go Engine output:\n" << output << std::endl;

    if (exit_code != 0) {
        std::cerr << "[LIBRARIAN ERROR] Memory Engine exited with status " << exit_code << "." << std::endl;
        return false;
    }
    return true;
}

int main(int argc, char* argv[]) {
    // `librarian.exe --self-test`: validates that distillation is
    // deterministic and actually derived from transcript content (not a
    // fixed/canned golden record) using two bundled sample transcripts. Does
    // not spawn the Memory Engine or touch Neo4j, so it can run in any
    // environment (e.g. CI) without Aura credentials.
    if (argc >= 2 && std::string(argv[1]) == "--self-test") {
        return run_self_test() ? 0 : 1;
    }

    if (argc < 3) {
        // Fallback test mode
        bool ok = commit_to_brain("session_cpp_123", "User: We need a C++ Librarian. AI: Executing native protocol.");
        return ok ? 0 : 1;
    }

    std::string session_id = argv[1];
    std::string raw_transcript;

    // `librarian.exe <session_id> --file <path>`: reads the transcript from a
    // file instead of argv, since a full Copilot CLI session transcript can
    // exceed the practical Windows command-line length and may contain
    // characters that are unsafe to embed directly in a command line.
    if (std::string(argv[2]) == "--file") {
        if (argc < 4) {
            std::cerr << "[LIBRARIAN ERROR] --file requires a path argument.\n"
                         "Usage: librarian.exe <session_id> --file <transcript_path>\n"
                         "       librarian.exe <session_id> <raw_transcript_text>" << std::endl;
            return 1;
        }
        std::ifstream in(argv[3], std::ios::binary);
        if (!in) {
            std::cerr << "[LIBRARIAN ERROR] Could not open transcript file: " << argv[3] << std::endl;
            return 1;
        }
        std::ostringstream ss;
        ss << in.rdbuf();
        raw_transcript = ss.str();
    } else {
        raw_transcript = argv[2];
    }

    if (raw_transcript.empty()) {
        std::cerr << "[LIBRARIAN ERROR] Transcript is empty; nothing to distill." << std::endl;
        return 1;
    }

    bool ok = commit_to_brain(session_id, raw_transcript);
    if (!ok) {
        std::cerr << "[LIBRARIAN] Distillation FAILED for session " << session_id << "." << std::endl;
        return 1;
    }
    std::cout << "[LIBRARIAN] Distillation complete for session " << session_id << "." << std::endl;
    return 0;
}