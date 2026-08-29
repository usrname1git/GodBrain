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
nlohmann::json openai_tool_defs();
std::vector<Call> calls_from_openai(const nlohmann::json& tool_calls);

}  // namespace local_tools
