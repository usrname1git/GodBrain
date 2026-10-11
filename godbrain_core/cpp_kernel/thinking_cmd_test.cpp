#include <iostream>
#include <fstream>
#include <chrono>

#include "thinking_cmd.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    if (!expect(parse_thinking_command("enable_thinking: false") == 0,
                "spaced false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking:false") == 0,
                "tight false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("  Enable_Thinking: False \n") == 0,
                "case/trim false")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking: true") == 1,
                "spaced true")) {
        return 1;
    }
    if (!expect(parse_thinking_command("enable_thinking:true") == 1,
                "tight true")) {
        return 1;
    }
    if (!expect(parse_thinking_command("/edit enable_thinking: false") == -1,
                "must not steal /edit")) {
        return 1;
    }
    if (!expect(parse_thinking_command("please enable_thinking: false") == -1,
                "must not steal prose")) {
        return 1;
    }
    if (!expect(parse_thinking_command("") == -1, "empty")) {
        return 1;
    }
    using json = nlohmann::json;
    const json models = {{"data", json::array({{
        {"id", "fixture"}, {"supported_reasoning_efforts", {"low", "medium", "xhigh"}}
    }})}};
    for (const std::string value : {"on", "true", "1", "off", "false", "0", "low", "medium", "xhigh", " XHIGH\r\n"}) {
        const auto preference = parse_thinking_preference(value);
        if (!expect(preference.error.empty(), "valid preference rejected")) return 1;
        for (const bool force_off : {false, true}) {
            json body = {{"model", "fixture"}, {"max_tokens", 1024}, {"reasoning_effort", "stale"}};
            std::string error;
            if (!expect(configure_thinking_request(body, preference, force_off, models, error),
                        "valid request rejected")) return 1;
            if (!expect(body["chat_template_kwargs"]["enable_thinking"] == (!force_off && preference.enabled),
                        "thinking override lost")) return 1;
            const bool effort_expected = !force_off && preference.enabled && !preference.effort.empty();
            if (!expect(body.contains("reasoning_effort") == effort_expected, "wrong effort presence")) return 1;
            if (effort_expected && !expect(body["reasoning_effort"] == preference.effort, "wrong effort")) return 1;
            if (!expect(body["max_tokens"] == 1024, "effort changed output limit")) return 1;
        }
    }
    for (const std::string value : {"", "high", "max", "low\non", "low medium"}) {
        const auto preference = parse_thinking_preference(value);
        json body = {{"model", "fixture"}};
        std::string error;
        if (!expect(!configure_thinking_request(body, preference, false, models, error) && !error.empty(),
                    "invalid preference did not fail explicitly")) return 1;
        if (!expect(configure_thinking_request(body, preference, true, models, error) &&
                    body["chat_template_kwargs"]["enable_thinking"] == false,
                    "invalid preference broke mandatory thinking-off path")) return 1;
    }
    for (const json capabilities : {json(), json::object(), json{{"data", "invalid"}},
            json{{"data", json::array({{{"id", "different"}, {"supported_reasoning_efforts", {"xhigh"}}}})}},
            json{{"data", json::array({models["data"][0], models["data"][0]})}}}) {
        json body = {{"model", "fixture"}};
        std::string error;
        if (!expect(!configure_thinking_request(body, parse_thinking_preference("xhigh"), false, capabilities, error),
                    "unadvertised model effort accepted")) return 1;
    }
    const auto temporary = std::filesystem::temp_directory_path() /
        ("godbrain-thinking-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".txt");
    if (!expect(read_thinking_preference(temporary.string()).error.empty(), "missing file changed default")) return 1;
    {
        std::ofstream out(temporary, std::ios::binary);
        out << "medium\n";
    }
    const auto saved = read_thinking_preference(temporary.string());
    if (!expect(saved.enabled && saved.effort == "medium", "persisted effort lost")) return 1;
    {
        std::ofstream out(temporary, std::ios::binary);
        out << std::string(65, 'x');
    }
    const bool oversized_failed = !read_thinking_preference(temporary.string()).error.empty();
    std::filesystem::remove(temporary);
    if (!expect(oversized_failed, "oversized preference accepted")) return 1;
    std::cout << "thinking_cmd_test ok" << std::endl;
    return 0;
}
