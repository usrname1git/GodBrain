#pragma once

#include "json.hpp"

#include <string>
#include <vector>

namespace local_tools {

struct Call {
    std::string name;
    std::string path;
    std::string sql;
    std::string content;
    std::string exe;
    std::string args;
    std::string old_text;
    std::string dest;
};

std::vector<std::string> default_roots();
bool path_is_granted(const std::string& path, std::string* err = nullptr);
bool yolo_active();
std::string set_yolo_minutes(int minutes);  // 0 clears
std::string yolo_status_line();
std::vector<Call> parse_tool_blocks(const std::string& text);
bool has_tool_block(const std::string& text);
std::string execute_calls(const std::vector<Call>& calls);
std::string run_tools_from_text(const std::string& model_text);
std::string tool_system_addendum();
std::string tool_system_addendum_for(const std::string& user_msg);
nlohmann::json openai_tool_defs();
nlohmann::json openai_tool_defs(bool full);
nlohmann::json openai_tool_defs_for(const std::string& user_msg);
bool looks_like_local_fs_ask(const std::string& msg);
// True for list/ls/dir/r/w/jail. False for "what's wrong in this repo".
bool looks_like_list_only_ask(const std::string& msg);
bool looks_like_host_inspect(const std::string& msg);
bool looks_like_no_tools(const std::string& msg);
bool looks_like_fs_refuse(const std::string& text);
std::string first_granted_path(const std::string& msg);
std::string answer_fs_ask(const std::string& user_msg);
// If the hop missed the granted path named in the ask, append a kernel
// list/info of that path. No GPU.
std::string complete_fs_listing(const std::string& user_msg,
                                const std::string& tool_out);
// Analysis observe: git + root doors + leftovers + nearest README.
// Sentences, not list_local_dir. Empty on list-only asks.
std::string repo_map(const std::string& dir);
std::string changed_context(const std::string& dir);
std::string analysis_observe(const std::string& user_msg);
// logs/last-host-snap.txt; process pid/ppid + granted FS depth-1.
std::string host_snap();
std::string host_snap_clip(size_t max_bytes);
std::string live_stack_blurb();
bool looks_like_jarvis_need_ask(const std::string& msg);
// Analysis asks: kernel-read AGENTS.md and Heal-GodBrain.ps1 under the
// named folder (for tests / ledger). Do not paste those files into the
// 12B prompt — that unused49's / IMA's. Use jarvis_rails_blurb().
std::string read_repo_rails(const std::string& user_msg);
std::string jarvis_rails_blurb();
bool use_full_tool_defs(const std::string& user_msg);
std::vector<Call> calls_from_openai(const nlohmann::json& tool_calls);

}  // namespace local_tools
