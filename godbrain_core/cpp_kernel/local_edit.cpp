#include "local_edit.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <mutex>
#include <sstream>
#include <vector>

namespace local_edit {
namespace {

std::string exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    const size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

std::string repo_root() {
    std::string dir = exe_dir();
    if (dir.empty()) return "";
    dir += "\\..\\..";
    char canon[MAX_PATH];
    if (GetFullPathNameA(dir.c_str(), MAX_PATH, canon, nullptr) == 0) return "";
    return std::string(canon);
}

std::string ascii_lower(std::string value) {
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string replace_slashes(std::string path) {
    for (char& ch : path) {
        if (ch == '/') ch = '\\';
    }
    return path;
}

bool ends_with(const std::string& value, const std::string& suf) {
    return value.size() >= suf.size() &&
           value.compare(value.size() - suf.size(), suf.size(), suf) == 0;
}

bool path_ok(const std::string& rel) {
    if (rel.empty() || rel.size() > 240) return false;
    if (rel.find("..") != std::string::npos) return false;
    if (rel.size() >= 2 && rel[1] == ':') return false;
    const std::string lower = ascii_lower(rel);
    if (lower.rfind(".git\\", 0) == 0 || lower.find("\\.git\\") != std::string::npos) {
        return false;
    }
    static const char* denied[] = {
        "build\\", "target\\", "out\\", "cache\\", "node_modules\\",
        "llm\\", "archive\\", "godbrain_core\\smart_contracts\\lib\\",
    };
    for (const char* d : denied) {
        if (lower.rfind(d, 0) == 0 || lower.find(std::string("\\") + d) != std::string::npos) {
            return false;
        }
    }
    const bool root_file = lower.find('\\') == std::string::npos;
    if (root_file) {
        return ends_with(lower, ".ps1") || ends_with(lower, ".cmd") ||
               ends_with(lower, ".md");
    }
    if (lower.rfind("scripts\\", 0) == 0) {
        return ends_with(lower, ".ps1") &&
               lower.find('\\', 8) == std::string::npos;
    }
    if (lower.rfind("docs\\", 0) == 0) {
        return ends_with(lower, ".md");
    }
    return lower.rfind("godbrain_core\\", 0) == 0;
}

bool read_all(const std::string& path, std::string& body) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream out;
    out << in.rdbuf();
    if (!in && !in.eof()) return false;
    body = out.str();
    return true;
}

bool write_all(const std::string& path, const std::string& body) {
    const std::string tmp = path + ".edit.tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out << body;
        if (!out) return false;
    }
    return MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
}

struct Hunk {
    std::string path;
    std::string old_text;
    std::string new_text;
};

size_t find_marker(const std::string& text, size_t from,
                     const char* spaced, const char* tight) {
    const size_t a = text.find(spaced, from);
    const size_t b = text.find(tight, from);
    if (a == std::string::npos) return b;
    if (b == std::string::npos) return a;
    return a < b ? a : b;
}

std::string trim_path_token(std::string path) {
    while (!path.empty() && (path.front() == '`' || path.front() == '"' ||
                             path.front() == '\'' || path.front() == ' ' ||
                             path.front() == '\t')) {
        path.erase(path.begin());
    }
    while (!path.empty() && (path.back() == '`' || path.back() == '"' ||
                             path.back() == '\'' || path.back() == ' ' ||
                             path.back() == '\t' || path.back() == '\r')) {
        path.pop_back();
    }
    return replace_slashes(path);
}

std::vector<Hunk> parse_apply_blocks(const std::string& text) {
    std::vector<Hunk> hunks;
    size_t pos = 0;
    while (hunks.size() < 6) {
        const size_t start = find_marker(text, pos, "*** APPLY", "***APPLY");
        if (start == std::string::npos) break;
        const size_t stop = find_marker(text, start, "*** END", "***END");
        if (stop == std::string::npos) break;
        const std::string block = text.substr(start, stop - start);
        Hunk hunk;
        const size_t path_at = block.find("path:");
        if (path_at == std::string::npos) {
            pos = stop + 6;
            continue;
        }
        size_t path_line = path_at + 5;
        while (path_line < block.size() &&
               (block[path_line] == ' ' || block[path_line] == '\t')) {
            ++path_line;
        }
        size_t path_end = block.find_first_of("\r\n", path_line);
        if (path_end == std::string::npos) path_end = block.size();
        hunk.path = trim_path_token(block.substr(path_line, path_end - path_line));
        const size_t old_at = block.find("<<<<");
        const size_t mid_at = block.find("====", old_at == std::string::npos ? 0 : old_at);
        const size_t new_at = block.find(">>>>", mid_at == std::string::npos ? 0 : mid_at);
        if (old_at == std::string::npos || mid_at == std::string::npos ||
            new_at == std::string::npos) {
            pos = stop + 6;
            continue;
        }
        hunk.old_text = block.substr(old_at + 4, mid_at - (old_at + 4));
        hunk.new_text = block.substr(mid_at + 4, new_at - (mid_at + 4));
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\r') hunk.old_text.erase(0, 1);
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\n') hunk.old_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\r') hunk.new_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\n') hunk.new_text.erase(0, 1);
        if (!hunk.path.empty()) hunks.push_back(hunk);
        pos = stop + 6;
    }
    return hunks;
}

std::mutex g_plan_mu;
std::string g_plan;

void save_plan(const std::string& user_msg, const std::string& first_answer) {
    g_plan = first_answer;
    if (g_plan.size() > 4000) g_plan.resize(4000);
    const std::string path = repo_root() + "\\logs\\last-edit-plan.txt";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << "USER\n" << user_msg << "\n\nPLAN\n" << g_plan << "\n";
}

void save_result(bool applied, const std::string& report) {
    const std::string path = repo_root() + "\\logs\\last-edit-result.json";
    std::ostringstream json;
    json << "{\"applied\":" << (applied ? "true" : "false")
         << ",\"verification_profile\":\"local-edit-apply-v1\""
         << ",\"skill_promote_eligible\":false"
         << ",\"report\":\"";
    for (char ch : report) {
        if (ch == '\\' || ch == '"') json << '\\';
        if (ch == '\n') json << "\\n";
        else if (ch == '\r') continue;
        else json << ch;
    }
    json << "\"}\n";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << json.str();
}

std::string guess_file(const std::string& text) {
    const std::string lower = ascii_lower(text);
    static const char* names[] = {
        "start-llamaserver.ps1", "start-godbrain.ps1", "heal-godbrain.ps1",
        "watch-godbrain.ps1", "watch-cs2pause.ps1", "godbrain-cs2.ps1",
        "start-cs2.ps1", "main.cpp", "coli_sse.h", "memory.cpp",
    };
    for (const char* name : names) {
        if (lower.find(name) != std::string::npos) {
            if (std::string(name) == "start-llamaserver.ps1") return "scripts\\Start-LlamaServer.ps1";
            if (std::string(name) == "start-godbrain.ps1") return "Start-GodBrain.ps1";
            if (std::string(name) == "heal-godbrain.ps1") return "Heal-GodBrain.ps1";
            if (std::string(name) == "watch-godbrain.ps1") return "Watch-GodBrain.ps1";
            if (std::string(name) == "watch-cs2pause.ps1") return "Watch-Cs2Pause.ps1";
            if (std::string(name) == "godbrain-cs2.ps1") return "GodBrain-Cs2.ps1";
            if (std::string(name) == "start-cs2.ps1") return "Start-CS2.ps1";
            if (std::string(name) == "main.cpp") return "godbrain_core\\cpp_kernel\\main.cpp";
            if (std::string(name) == "coli_sse.h") return "godbrain_core\\cpp_kernel\\coli_sse.h";
            if (std::string(name) == "memory.cpp") return "godbrain_core\\cpp_kernel\\memory.cpp";
        }
    }
    return "";
}

std::string excerpt(const std::string& rel) {
    const std::string full = repo_root() + "\\" + rel;
    std::string body;
    if (!read_all(full, body)) return "";
    if (body.size() > 4000) body.resize(4000);
    return body;
}

std::string apply_hunks(const std::vector<Hunk>& hunks) {
    const std::string root = repo_root();
    if (root.empty()) return "FAIL: cannot resolve repo root";
    std::ostringstream report;
    int ok = 0;
    for (const Hunk& hunk : hunks) {
        if (!path_ok(hunk.path)) {
            report << "skip bad path " << hunk.path << "\n";
            continue;
        }
        const std::string full = root + "\\" + hunk.path;
        std::string body;
        if (!read_all(full, body)) {
            report << "skip missing " << hunk.path << "\n";
            continue;
        }
        if (body.empty() && hunk.old_text.empty()) {
            if (!write_all(full, hunk.new_text)) {
                report << "skip write failed " << hunk.path << "\n";
                continue;
            }
            ++ok;
            report << "edited " << hunk.path << "\n";
            continue;
        }
        const size_t at = body.find(hunk.old_text);
        if (at == std::string::npos) {
            report << "skip no match " << hunk.path << "\n";
            continue;
        }
        if (body.find(hunk.old_text, at + 1) != std::string::npos) {
            report << "skip ambiguous " << hunk.path << "\n";
            continue;
        }
        body.replace(at, hunk.old_text.size(), hunk.new_text);
        if (!write_all(full, body)) {
            report << "skip write failed " << hunk.path << "\n";
            continue;
        }
        ++ok;
        report << "edited " << hunk.path << "\n";
    }
    if (ok == 0) return "FAIL\n" + report.str();
    return "DONE\n" + report.str();
}

}  // namespace

bool looks_like_edit_request(const std::string& user_msg) {
    const std::string lower = ascii_lower(user_msg);
    if (lower.rfind("/edit", 0) == 0) return true;
    const bool named =
        lower.find(".ps1") != std::string::npos ||
        lower.find(".cpp") != std::string::npos ||
        lower.find(".h") != std::string::npos ||
        lower.find(".go") != std::string::npos;
    if (!named) return false;
    return lower.find("edit") != std::string::npos ||
           lower.find("add") != std::string::npos ||
           lower.find("change") != std::string::npos ||
           lower.find("fix") != std::string::npos ||
           lower.find("guard") != std::string::npos ||
           lower.find("patch") != std::string::npos ||
           lower.find("write") != std::string::npos ||
           lower.find("do not launch") != std::string::npos;
}

Result maybe_apply(
    const std::string& user_msg,
    const std::string& first_answer,
    const std::function<std::string(const std::string&, const std::string&)>& generate) {
    Result result;
    if (!looks_like_edit_request(user_msg)) return result;
    std::lock_guard<std::mutex> lock(g_plan_mu);
    result.attempted = true;
    save_plan(user_msg, first_answer);

    std::vector<Hunk> hunks = parse_apply_blocks(first_answer);
    if (hunks.empty() && generate) {
        const std::string file = guess_file(user_msg + "\n" + first_answer);
        std::ostringstream usr;
        usr << "You already planned this job (kept in RAM, do not re-plan):\n"
            << (g_plan.empty() ? first_answer : g_plan) << "\n\n";
        if (!file.empty()) {
            usr << "File " << file << " excerpt:\n" << excerpt(file) << "\n\n";
        }
        usr << "Emit ONLY apply blocks, no prose, no thinking:\n"
               "*** APPLY\n"
               "path: relative/from/repo\n"
               "<<<<\n"
               "exact old text\n"
               "====\n"
               "exact new text\n"
               ">>>>\n"
               "*** END\n";
        const std::string sys =
            "You are a local file editor. Output apply blocks only. "
            "No git. No push. No extra files.";
        const std::string second = generate(sys, usr.str());
        hunks = parse_apply_blocks(second);
        if (hunks.empty()) {
            result.report =
                "Plan saved. Second pass had no apply blocks. "
                "Ask again with /edit and a file name.";
            save_result(false, result.report);
            return result;
        }
    } else if (hunks.empty()) {
        result.report = "Plan saved. No apply blocks and no second pass.";
        save_result(false, result.report);
        return result;
    }

    result.report = apply_hunks(hunks);
    result.applied = result.report.rfind("DONE", 0) == 0;
    save_result(result.applied, result.report);
    return result;
}

Preview preview_apply_blocks(const std::string& text) {
    Preview out;
    const auto hunks = parse_apply_blocks(text);
    out.count = static_cast<int>(hunks.size());
    if (!hunks.empty()) {
        out.first_path = hunks[0].path;
        out.first_old = hunks[0].old_text;
        out.first_new = hunks[0].new_text;
    }
    return out;
}

}  // namespace local_edit
