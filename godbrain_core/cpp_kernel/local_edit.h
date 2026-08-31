#pragma once

#include <functional>
#include <string>

// Two-pass local edit: save the plan in RAM, then a second GPU generate
// emits apply blocks. Writes repo files only. Never git push.
namespace local_edit {

struct Result {
    bool attempted = false;
    bool applied = false;
    bool rolled_back = false;
    bool check_ran = false;
    bool check_ok = false;
    std::string check_profile;
    std::string report;
    std::string before_hash;
    std::string after_hash;
    std::string preview_path;
    std::string preview_old;
    std::string preview_new;
};

struct Preview {
    int count = 0;
    std::string first_path;
    std::string first_old;
    std::string first_new;
    std::string first_hash;
};

bool looks_like_edit_request(const std::string& user_msg);
bool apply_still_open(const std::string& text);
std::string edit_user_with_excerpt(const std::string& user_msg);
Preview preview_apply_blocks(const std::string& text);
std::string check_profile_for(const std::string& rel);
void set_verify_script_for_test(const std::string& path);

Result maybe_apply(
    const std::string& user_msg,
    const std::string& first_answer,
    const std::function<std::string(const std::string& system, const std::string& user)>&
        generate);

}  // namespace local_edit
