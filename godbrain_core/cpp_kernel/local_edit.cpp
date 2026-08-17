#include "local_edit.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <fstream>
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

bool path_ok(const std::string& rel) {
    if (rel.empty() || rel.size() > 240) return false;
    if (rel.find("..") != std::string::npos) return false;
    if (rel.size() >= 2 && rel[1] == ':') return false;
    const std::string lower = ascii_lower(rel);
    if (lower.rfind(".git\\", 0) == 0 || lower.find("\\.git\\") != std::string::npos) {
        return false;
    }
    return true;
}

std::string read_all(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return "";
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
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

std::vector<Hunk> parse_apply_blocks(const std::string& text) {
    std::vector<Hunk> hunks;
    size_t pos = 0;
    while (hunks.size() < 6) {
        const size_t start = text.find("*** APPLY", pos);
        if (start == std::string::npos) break;
        const size_t end = text.find("*** END", start);
        if (end == std::string::npos) break;
        const std::string block = text.substr(start, end - start);
        Hunk hunk;
        const size_t path_at = block.find("path:");
        if (path_at == std::string::npos) {
            pos = end + 7;
            continue;
        }
        size_t path_line = path_at + 5;
        while (path_line < block.size() &&
               (block[path_line] == ' ' || block[path_line] == '\t')) {
            ++path_line;
        }
        size_t path_end = block.find_first_of("\r\n", path_line);
        if (path_end == std::string::npos) path_end = block.size();
        hunk.path = replace_slashes(block.substr(path_line, path_end - path_line));
        while (!hunk.path.empty() && (hunk.path.back() == ' ' || hunk.path.back() == '\t')) {
            hunk.path.pop_back();
        }
        const size_t old_at = block.find("<<<<");
        const size_t mid_at = block.find("====", old_at == std::string::npos ? 0 : old_at);
        const size_t new_at = block.find(">>>>", mid_at == std::string::npos ? 0 : mid_at);
        if (old_at == std::string::npos || mid_at == std::string::npos ||
            new_at == std::string::npos) {
            pos = end + 7;
            continue;
        }
        hunk.old_text = block.substr(old_at + 4, mid_at - (old_at + 4));
        hunk.new_text = block.substr(mid_at + 4, new_at - (mid_at + 4));
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\r') hunk.old_text.erase(0, 1);
        if (!hunk.old_text.empty() && hunk.old_text[0] == '\n') hunk.old_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\r') hunk.new_text.erase(0, 1);
        if (!hunk.new_text.empty() && hunk.new_text[0] == '\n') hunk.new_text.erase(0, 1);
        if (!hunk.path.empty() && !hunk.old_text.empty()) hunks.push_back(hunk);
        pos = end + 7;
    }
    return hunks;
}

std::string g_plan;

void save_plan(const std::string& user_msg, const std::string& first_answer) {
    g_plan = first_answer;
    if (g_plan.size() > 4000) g_plan.resize(4000);
    const std::string path = repo_root() + "\\logs\\last-edit-plan.txt";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << "USER\n" << user_msg << "\n\nPLAN\n" << g_plan << "\n";
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
            if (std::string(name) == "start-llamaserver.ps1") return "Start-LlamaServer.ps1";
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
    std::string body = read_all(full);
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
        std::string body = read_all(full);
        if (body.empty()) {
            report << "skip missing " << hunk.path << "\n";
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
            return result;
        }
    } else if (hunks.empty()) {
        result.report = "Plan saved. No apply blocks and no second pass.";
        return result;
    }

    result.report = apply_hunks(hunks);
    result.applied = result.report.rfind("DONE", 0) == 0;
    return result;
}

}  // namespace local_edit
