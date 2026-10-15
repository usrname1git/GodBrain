#define main godbrain_runtime_main
#include "main.cpp"
#undef main

#include <filesystem>
#include <stdexcept>

struct MockCompletion {
    std::vector<json> deltas;
    std::string finish = "stop";
};

struct ReplyResult {
    std::string answer;
    std::string spoken;
    std::string tokens;
    std::vector<json> requests;
    int pings = 0;
};

int main() {
    const auto root = std::filesystem::path(repo_root_from_exe()).lexically_normal();
    const auto expected =
        std::filesystem::path(read_env("GODBRAIN_REPLY_TEST_ROOT")).lexically_normal();
    if (expected.empty() ||
        ascii_lower_copy(root.string()) != ascii_lower_copy(expected.string()) ||
        std::filesystem::exists(root / ".git") ||
        std::filesystem::exists(root / "AGENTS.md")) {
        std::cerr << "Run this test through scripts\\Test-KernelReplies.ps1 "
                     "in its isolated fixture root." << std::endl;
        return 1;
    }
    const auto logs = root / "logs";
    std::filesystem::create_directories(logs);
    std::ofstream(logs / "mouth.txt") << "fixture\n";
    std::ofstream(logs / "last-chain.json") << "{}\n";

    httplib::Server server;
    std::mutex mutex;
    std::vector<MockCompletion> completions;
    std::vector<json> requests;
    server.Get("/v1/models", [](const httplib::Request&, httplib::Response& response) {
        response.set_content(
            R"({"data":[{"id":"fixture","supported_reasoning_efforts":["low","medium","xhigh"]}]})",
            "application/json");
    });
    server.Post("/v1/chat/completions",
                [&](const httplib::Request& request, httplib::Response& response) {
        const json body = json::parse(request.body);
        MockCompletion reply;
        {
            std::lock_guard<std::mutex> lock(mutex);
            const size_t index = requests.size();
            requests.push_back(body);
            if (index >= completions.size()) {
                response.status = 500;
                response.set_content("Unexpected fixture request.", "text/plain");
                return;
            }
            reply = completions[index];
        }
        if (body.value("stream", false)) {
            std::string data;
            for (const auto& delta : reply.deltas) {
                data += "data: " +
                        json({{"choices", json::array({{{"delta", delta}}})}}).dump() +
                        "\n\n";
            }
            data += "data: " +
                    json({{"choices", json::array({{
                        {"delta", json::object()}, {"finish_reason", reply.finish}
                    }})}}).dump() +
                    "\n\ndata: [DONE]\n\n";
            response.set_content(data, "text/event-stream");
        } else {
            json message = {{"role", "assistant"}};
            for (const auto& delta : reply.deltas) {
                for (const char* key : {"content", "reasoning_content"}) {
                    if (delta.contains(key)) {
                        message[key] =
                            message.value(key, std::string()) + delta.at(key).get<std::string>();
                    }
                }
                if (delta.contains("tool_calls")) message["tool_calls"] = delta["tool_calls"];
            }
            response.set_content(
                json({{"choices", json::array({{
                    {"message", message}, {"finish_reason", reply.finish}
                }})}}).dump(), "application/json");
        }
    });
    const int port = server.bind_to_any_port("127.0.0.1");
    if (port < 1) {
        std::cerr << "Could not bind isolated mock server." << std::endl;
        return 1;
    }
    std::thread listener([&] { server.listen_after_bind(); });
    const auto check = [](bool ok, const char* why) {
        if (!ok) throw std::runtime_error(why);
    };
    const auto completion = [](const std::string& reasoning,
                               const std::string& content,
                               const std::string& finish = "stop") {
        MockCompletion result;
        if (!reasoning.empty()) result.deltas.push_back({{"reasoning_content", reasoning}});
        if (!content.empty()) result.deltas.push_back({{"content", content}});
        result.finish = finish;
        return result;
    };
    int case_index = 0;
    const auto run = [&](std::vector<MockCompletion> replies,
                         const std::string& preference = "on",
                         const std::string& question = "No tools. Fixture question.",
                         const std::string& system = "Fixture system.",
                         bool capture_spoken = true,
                         bool exl3 = true) {
        ++case_index;
        {
            std::lock_guard<std::mutex> lock(mutex);
            completions = std::move(replies);
            requests.clear();
        }
        std::ofstream(logs / "thinking.txt", std::ios::binary) << preference << "\n";
        ReplyResult result;
        result.answer = run_colibri_serve(
            system, question,
            [&](const std::string& token) { result.tokens += token; },
            [&] { ++result.pings; }, "", "",
            capture_spoken ? &result.spoken : nullptr,
            question, "127.0.0.1", port, "fixture", exl3);
        {
            std::lock_guard<std::mutex> lock(mutex);
            result.requests = requests;
        }
        for (const auto& body : result.requests) {
            check(body.dump().find("PRIVATE_REASONING") == std::string::npos,
                  "private reasoning entered a subsequent request");
            check(body.at("max_tokens") == (exl3 ? kLlamaChunkTokens : kColiChunkTokens),
                  "output budget changed");
        }
        check(result.answer.find("PRIVATE_REASONING") == std::string::npos &&
                  result.spoken.find("PRIVATE_REASONING") == std::string::npos &&
                  result.tokens.find("PRIVATE_REASONING") == std::string::npos,
              "private reasoning escaped through a reply channel");
        return result;
    };
    const std::string private_text = "PRIVATE_REASONING: inspect the harmless fixture first.";
    int result = 0;
    try {
        for (const std::string preference : {"on", "off", "low", "medium", "xhigh"}) {
            const auto reply = run({completion(private_text, "The result is four.")}, preference);
            check(reply.answer == "The result is four." &&
                      reply.spoken == reply.answer && reply.tokens == reply.answer,
                  "mixed reasoning/final reply was not separated");
            check(reply.pings > 0 && reply.requests.size() == 1, "thinking progress or request count changed");
            check(reply.requests[0]["chat_template_kwargs"]["enable_thinking"] == (preference != "off"),
                  "thinking preference changed");
            const bool explicit_effort = preference != "on" && preference != "off";
            check(reply.requests[0].contains("reasoning_effort") == explicit_effort,
                  "reasoning effort presence changed");
            if (explicit_effort) {
                check(reply.requests[0]["reasoning_effort"] == preference, "reasoning effort changed");
            }
        }
        const auto no_outparam = run({completion(private_text, "Four.")}, "on",
                                    "No tools. Fixture question.", "Fixture system.", false);
        check(no_outparam.answer == "Four." && no_outparam.tokens == "Four.",
              "caller without spoken outparam received reasoning");

        for (const std::string finish : {"length", "stop"}) {
            const auto reply = run({completion(private_text, "", finish)});
            check(reply.answer.compare(0, 6, "Error:") == 0 &&
                      reply.spoken == reply.answer && reply.tokens.empty() &&
                      reply.requests.size() == 1,
                  "reasoning-only output was returned or automatically continued");
            check((reply.answer.find("output limit") != std::string::npos) == (finish == "length"),
                  "reasoning-only finish reason was lost");
        }
        const auto blank = run({completion(private_text, " \n", "length")});
        check(blank.answer.compare(0, 6, "Error:") == 0 && blank.requests.size() == 1,
              "whitespace answer triggered continuation");
        const auto empty = run({completion("", "")});
        check(empty.answer.compare(0, 6, "Error:") == 0 && empty.spoken == empty.answer,
              "empty completion silently succeeded");

        const auto continued = run({
            completion(private_text, "A blue-", "length"),
            completion(private_text, "green.")
        });
        check(continued.answer == "A blue-green." && continued.spoken == continued.answer &&
                  continued.tokens == continued.answer && continued.requests.size() == 2,
              "bounded answer continuation changed");
        const auto& history = continued.requests[1].at("messages");
        check(history.at(history.size() - 2).at("role") == "assistant" &&
                  history.at(history.size() - 2).at("content") == "A blue-",
              "continuation history is not answer-only");
        const auto failed_continuation = run({
            completion(private_text, "A blue-", "length"),
            completion(private_text, "", "length")
        });
        check(failed_continuation.answer.compare(0, 6, "Error:") == 0 &&
                  failed_continuation.spoken == failed_continuation.answer &&
                  failed_continuation.requests.size() == 2,
              "reasoning-only continuation silently returned a partial answer");

        const auto native_empty = run({completion(private_text, "", "length")}, "on",
                                      "Fixture tool question.");
        check(native_empty.answer.compare(0, 6, "Error:") == 0 &&
                  native_empty.spoken == native_empty.answer && native_empty.requests.size() == 1 &&
                  native_empty.requests[0]["stream"] == false &&
                  native_empty.requests[0]["chat_template_kwargs"]["enable_thinking"] == false,
              "nonstream native-tool reasoning-only response did not fail closed");
        MockCompletion tool_reply = completion(private_text, "", "tool_calls");
        tool_reply.deltas.push_back({{"tool_calls", json::array({{
            {"id", "fixture_call"}, {"type", "function"},
            {"function", {{"name", "list_granted_roots"}, {"arguments", "{}"}}}
        }})}});
        const auto tool = run({tool_reply, completion(private_text, "Fixture roots inspected.")},
                              "on", "Fixture tool question.");
        check(tool.answer == "Fixture roots inspected." && tool.spoken == tool.answer &&
                  tool.requests.size() == 2 && tool.requests[0].contains("tools") &&
                  tool.requests[1].contains("tools"),
              "native tool execution/flattening changed");
        for (const auto& body : tool.requests) {
            check(body["chat_template_kwargs"]["enable_thinking"] == false,
                  "tool round enabled reasoning");
            for (const auto& message : body.at("messages")) {
                check(message.at("role") != "tool", "tool history was not flattened");
            }
        }

        const auto edit = run({
            completion(private_text, "*** APPLY\npath: docs\\fixture.md\n<<<<\nold\n====\nnew", "length"),
            completion(private_text, "\n>>>>\n*** END\n")
        }, "on", "No tools. Fixture edit.", "local file editor");
        check(edit.requests.size() == 2 && edit.answer.find(">>>>") != std::string::npos,
              "open APPLY block no longer continues");
        for (const auto& body : edit.requests) {
            check(body["chat_template_kwargs"]["enable_thinking"] == false &&
                      !body.contains("tools"), "edit thinking/tool policy changed");
        }

        const auto legacy = run({completion(private_text, "Legacy final answer.")}, "on",
                                "No tools. Fixture question.", "Fixture system.", true, false);
        check(legacy.answer == "Legacy final answer." && legacy.spoken == legacy.answer,
              "legacy SSE answer separation failed");
        const auto legacy_empty = run({completion(private_text, "", "length")}, "on",
                                      "No tools. Fixture question.", "Fixture system.", true, false);
        check(legacy_empty.answer.compare(0, 6, "Error:") == 0 &&
                  legacy_empty.requests.size() == 1,
              "legacy reasoning-only completion became a cut-marker answer");

        std::string loop = "PRIVATE_REASONING ";
        for (int i = 0; i < 80; ++i) loop += "check fixture. ";
        check(is_generation_loop(loop), "private loop fixture does not exercise the loop guard");
        const auto loop_reply = run({completion(loop, "", "length")});
        check(loop_reply.answer.compare(0, 6, "Error:") == 0 &&
                  loop_reply.answer.find("output limit") == std::string::npos &&
                  loop_reply.requests.size() == 1,
              "private reasoning loop guard no longer aborts");
        const auto unused = run({
            completion("PRIVATE_REASONING <unused49>", "Fixture partial", "length")
        });
        check(unused.answer == "Fixture partial" && unused.requests.size() == 1 &&
                  unused.tokens.find("unused49") == std::string::npos,
              "private unused49 guard no longer stops continuation");
        std::cout << "reply_stream_test ok: answer-only callbacks/history, explicit incomplete "
                     "replies, preferences, limits, tool/edit continuation and private loop guards"
                  << std::endl;
    } catch (const std::exception& error) {
        std::cerr << "reply fixture " << case_index << ": " << error.what() << std::endl;
        result = 1;
    }
    server.stop();
    listener.join();
    return result;
}
