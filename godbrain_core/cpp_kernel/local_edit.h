#pragma once

#include <functional>
#include <string>

// Two-pass local edit: save the plan in RAM, then a second GPU generate
// emits apply blocks. Writes repo files only. Never git push.
namespace local_edit {

struct Result {
    bool attempted = false;
    bool applied = false;
    std::string report;
};

bool looks_like_edit_request(const std::string& user_msg);

Result maybe_apply(
    const std::string& user_msg,
    const std::string& first_answer,
    const std::function<std::string(const std::string& system, const std::string& user)>&
        generate);

}  // namespace local_edit
