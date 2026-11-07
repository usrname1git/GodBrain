#include "kernel.h"
#include "memory.h"
#include "surgery.h"
#include "telemetry.h"
#include <stdexcept>
#include <iostream>

static int executions = 0, posts = 0;
static bool bad_receipt = false;
namespace surgery {
Outcome execute_self_command(const std::string&) { ++executions; return {true, 0, "fixture executed"}; }
}
namespace telemetry { json get_current_state() { return json::object(); } }
namespace memory {
json working_shelf(const json& payload) {
    ++posts;
    if (payload.at("shelf") != "research" || payload.at("scope") != "technical" ||
        payload.at("thread_id") != "architect-proposals") throw std::runtime_error("Wrong proposal scope");
    return {{"record", {{"text", bad_receipt ? "mismatch" : payload.at("text").get<std::string>()}}}};
}
json save_thought(const json&) { return {}; }
json search_verified(const std::string&, int) { return {}; }
json get_recent(int) { return {}; }
json set_status(const json&) { return {}; }
json record_skill_run(const json&) { return {}; }
json promote_skill(const json&) { return {}; }
json query_skills(const json&) { return {}; }
json observe_host() { return {}; }
json promote_claim(const json&) { return {}; }
}
int main() {
    const auto check = [](bool ok) { if (!ok) throw std::runtime_error("Proposal execution boundary regressed"); };
    try {
        GodBrainKernel kernel;
        const json proposal = {{"reasoning", "Synthetic fixture"}, {"proposal_script", "Write-Output 'must not execute'"}};
        auto result = kernel.dispatch("propose_sovereign_architect_change", proposal);
        check(result["status"] == "success" && result["staged"] == true &&
              result["executed"] == false && executions == 0 && posts == 1);
        bad_receipt = true;
        check(kernel.dispatch("propose_sovereign_architect_change", proposal)["status"] == "error" &&
              executions == 0);
        bad_receipt = false;
        for (const auto& script : {std::string(" \t\r\n"), std::string(32769, 'x')}) {
            auto invalid = proposal; invalid["proposal_script"] = script;
            check(kernel.dispatch("propose_sovereign_architect_change", invalid)["status"] == "error");
        }
        auto unauthorized = proposal; unauthorized["reasoning"] = " ";
        check(kernel.dispatch("propose_sovereign_architect_change", unauthorized)["status"] == "error");
        check(executions == 0);
        check(kernel.dispatch("execute_godbrain_script", {{"reasoning", "Fixture"}, {"command", "fixture"}})["status"] ==
              "success" && executions == 1);
        std::cout << "kernel_dispatch_test ok: proposals persist without execution, mismatches and invalid input fail\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
