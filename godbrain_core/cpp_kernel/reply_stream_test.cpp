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
    int recoveries = 0;
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
    server.wait_until_ready();
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
                         bool exl3 = true,
                         bool llama = false,
                         const std::string& evidence_context = {},
                         bool with_history = false,
                         const godbrain_rag::Client* skill_client = nullptr) {
        ++case_index;
        {
            std::lock_guard<std::mutex> lock(mutex);
            completions = std::move(replies);
            requests.clear();
        }
        std::ofstream(logs / "thinking.txt", std::ios::binary) << preference << "\n";
        std::ofstream(logs / "mouth.txt") << (llama ? "llama\n" : "fixture\n");
        ReplyResult result;
        result.answer = run_colibri_serve(
            system, evidence_context.empty() ? question : evidence_context + "\n\n" + question,
            [&](const std::string& token) { result.tokens += token; },
            [&] { ++result.pings; },
            with_history ? "Prior fixture question." : "",
            with_history ? "Prior untrusted answer." : "",
            capture_spoken ? &result.spoken : nullptr,
            question, "127.0.0.1", port, "fixture", exl3,
            [&](bool force) {
                check(force, "fixture unexpectedly requested ordinary mouth recovery");
                ++result.recoveries;
                return false;
            }, skill_client);
        {
            std::lock_guard<std::mutex> lock(mutex);
            result.requests = requests;
        }
        for (const auto& body : result.requests) {
            check(body.dump().find("PRIVATE_REASONING") == std::string::npos,
                  "private reasoning entered a subsequent request");
            check(body.at("max_tokens") == ((exl3 || llama) ? kLlamaChunkTokens : kColiChunkTokens),
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
        {
            httplib::Request request;
            request.body = R"({"class":"doc_fact","text":"unrelated caller prose","learn_url":"https://example.invalid/","quote":"An unrelated documentation quote."})";
            request.headers.emplace("Authorization", "Bearer fixture-truth-token");
            httplib::Response unconfigured;
            g_api_token.clear();
            handle_truth(request, unconfigured);
            check(unconfigured.status == 401, "Truth write accepted an unconfigured bearer gate");
            g_api_token = "fixture-truth-token";
            request.headers.clear();
            httplib::Response absent;
            handle_truth(request, absent);
            check(absent.status == 401, "Truth write accepted a missing bearer");
            request.headers.emplace("Authorization", "Bearer wrong-fixture-token");
            httplib::Response wrong;
            handle_truth(request, wrong);
            check(wrong.status == 403, "Truth write accepted a wrong bearer");
            request.headers.clear();
            request.headers.emplace("Authorization", "Bearer fixture-truth-token");
            httplib::Response invalid_source;
            handle_truth(request, invalid_source);
            check(invalid_source.status == 503 &&
                json::parse(invalid_source.body).at("error").get<std::string>().find("documentation URL") !=
                    std::string::npos,
                "Authenticated truth route did not use the production assertion source gate");
            request.body = "{";
            httplib::Response malformed;
            handle_truth(request, malformed);
            check(malformed.status == 400, "Truth route did not report malformed input");
            request.body = R"({"outcome":"fresh","ttl":999999,"id":"caller-selected"})";
            httplib::Response supplied_result;
            handle_evidence(request, supplied_result);
            check(supplied_result.status == 400,
                  "Maintenance accepted a caller-selected verdict or source");
            request.body = "[";
            httplib::Response malformed_evidence;
            handle_evidence(request, malformed_evidence);
            check(malformed_evidence.status == 400, "Maintenance accepted malformed JSON");
            request.body = "{}";
            request.headers.clear();
            httplib::Response missing_evidence_token;
            handle_evidence(request, missing_evidence_token);
            check(missing_evidence_token.status == 401, "Maintenance accepted a missing bearer");
            g_api_token.clear();
            httplib::Response unconfigured_evidence;
            handle_evidence(request, unconfigured_evidence);
            check(unconfigured_evidence.status == 401, "Maintenance accepted an unconfigured bearer");
            httplib::Response unconfigured_research;
            handle_research(request, unconfigured_research);
            check(unconfigured_research.status == 401, "Research accepted an unconfigured bearer");
            g_api_token = "fixture-research-token";
            httplib::Response missing_research_token;
            handle_research(request, missing_research_token);
            check(missing_research_token.status == 401, "Research accepted a missing bearer");
            request.headers.emplace("Authorization", "Bearer fixture-research-token");
            for (const auto* body : {
                     R"({"url":"https://example.invalid","decision":"new"})",
                     R"({"inference":"yes"})",
                     R"({"inference":false,"inference":true})"}) {
                request.body = body;
                httplib::Response invalid_research;
                handle_research(request, invalid_research);
                check(invalid_research.status == 400,
                      "Research accepted caller-selected sources/verdicts or invalid flags");
            }
            g_api_token.clear();
        }
        const std::string hostname = telemetry::get_computer_name();
        check(!hostname.empty() &&
                  oracle_system_prompt().find("Hostname " + hostname + " is this PC") != std::string::npos,
              "Ordinary chat prompt could not read its hostname independently");
        if (read_env("GODBRAIN_REPLY_TEST_MISSING_PIN") == "1") {
            bool rejected = false;
            try {
                telemetry::get_host_inventory();
            } catch (const std::runtime_error& failure) {
                rejected = std::string(failure.what()) == "Windows UBR could not be read";
            }
            check(rejected, "Unavailable pin was not rejected by strict host inventory");
            const auto advisory = run(
                {completion("", "The RAG-free advisory still responds.")},
                "off", "No tools. Fixture advisory.", oracle_system_prompt());
            check(advisory.answer == "The RAG-free advisory still responds." &&
                      advisory.requests.at(0)["messages"].at(0)["content"] == oracle_system_prompt(),
                  "Missing-pin failure prevented the actual Oracle prompt from reaching the mouth");
        }
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
        const auto native_chain = load_chain();
        check(native_chain["execution"]["outcome"] == "completed" &&
                  native_chain["verification"]["status"] == "not_run" &&
                  native_chain["skill_promote_eligible"] == false &&
                  native_chain["tool_evidence"].size() == 1 &&
                  native_chain["tool_evidence"][0]["executor_ok"] == true,
              "tool completion was confused with independently verified task success");
        const auto events = load_core_event_tail(20);
        bool correlated = false;
        for (const auto& row : events) {
            if (row.value("kind", "") == "tool_result" &&
                row.value("task_id", "") == native_chain["id"]) {
                correlated = row["evidence"]["attempt_id"] == native_chain["attempt_id"];
            }
        }
        check(correlated, "tool evidence lost task/attempt correlation");
        const auto native_call = [&](const std::string& name, const json& args) {
            MockCompletion reply = completion(private_text, "", "tool_calls");
            reply.deltas.push_back({{"tool_calls", json::array({{
                {"id", "fixture"}, {"type", "function"},
                {"function", {{"name", name}, {"arguments", args.dump()}}}
            }})}});
            return reply;
        };
        const auto artifact = root / "wrong-outcome.txt";
        const auto execute_fixture = [&](const std::string& name, const json& args,
                                         bool expected_ok) {
            const auto request = native_call(name, args);
            const auto parsed = local_tools::calls_from_openai(request.deltas.back()["tool_calls"]);
            bool ok = !expected_ok;
            local_tools::execute_calls(parsed, &ok);
            check(ok == expected_ok, "typed executor flag disagreed with fixture outcome");
        };
        std::ofstream(artifact, std::ios::trunc);
        execute_fixture("read_local_file", {{"path", artifact.string()}}, true);
        execute_fixture("get_file_info", {{"path", (root / "absent.txt").string()}}, false);
        execute_fixture("list_local_dir", {{"path", artifact.string()}}, false);
        execute_fixture("edit_local_file", {{"path", artifact.string()},
                                          {"old_text", "missing"}, {"content", "new"}}, false);
        execute_fixture("create_local_dir", {{"path", (artifact / "child").string()}}, false);
        execute_fixture("search_local", {{"path", root.string()}, {"args", ""}}, false);
        execute_fixture("unknown_fixture_tool", json::object(), false);
        HANDLE locked = CreateFileA(artifact.string().c_str(), GENERIC_READ, 0,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        check(locked != INVALID_HANDLE_VALUE, "could not lock read fixture");
        execute_fixture("read_local_file", {{"path", artifact.string()}}, false);
        execute_fixture("write_local_file", {{"path", artifact.string()}, {"content", "blocked"}}, false);
        CloseHandle(locked);
        const auto audit_path = logs / "tool-audit.jsonl";
        const auto audit_backup = logs / "audit.fixture-backup";
        std::filesystem::rename(audit_path, audit_backup);
        std::filesystem::create_directory(audit_path);
        execute_fixture("write_local_file", {{"path", artifact.string()}, {"content", "blocked"}}, false);
        std::filesystem::remove(audit_path);
        std::filesystem::rename(audit_backup, audit_path);
        check(std::filesystem::file_size(artifact) == 0, "failed read/audit changed the file");
        std::ofstream(artifact) << "original";
        run({native_call("write_local_file", {{"path", artifact.string()},
                                            {"content", "wrong outcome"}}),
             completion("", "The required correct outcome is verified.")},
            "on", "Fixture writing task.");
        std::ifstream wrong(artifact);
        std::string wrong_text((std::istreambuf_iterator<char>(wrong)), {});
        wrong.close();
        check(wrong_text == "wrong outcome" &&
                  load_chain()["execution"]["outcome"] == "completed" &&
                  load_chain()["verification"]["status"] == "not_run",
              "a model success claim upgraded the wrong artifact to verified");

        run({native_call("read_local_file", {{"path", (root / "absent.txt").string()}}),
             completion("", "Everything succeeded.")}, "on", "Fixture missing-file task.");
        check(load_chain()["status"] == "failed" &&
                  load_chain()["tool_evidence"][0]["executor_ok"] == false &&
                  load_chain()["verification"]["status"] == "not_run",
              "a failed executor became success because of the model's final answer");

        const std::string large_text = "RAW_FIXTURE_KEEP_LOCAL " + std::string(30000, 'x');
        std::ofstream(artifact, std::ios::binary | std::ios::trunc) << large_text;
        const auto large_call = native_call("read_local_file", {{"path", artifact.string()}});
        const auto calls = local_tools::calls_from_openai(large_call.deltas.back()["tool_calls"]);
        bool read_ok = false;
        const auto full_result = local_tools::execute_calls(calls, &read_ok);
        check(read_ok && full_result.size() > 12000, "large result fixture did not exceed clipping");
        run({large_call, completion("", "Read complete.")}, "on", "Fixture large read.");
        const auto large_chain = load_chain();
        check(large_chain["tool_evidence"][0]["result_bytes"] == full_result.size() &&
                  large_chain["tool_evidence"][0]["result_keccak256"] ==
                      browser_evidence::keccak_hex(full_result) &&
                  large_chain["ledger"].get<std::string>().size() <= kToolContextBytes &&
                  large_chain["ledger"].get<std::string>().find("Tool result omitted") != std::string::npos &&
                  large_chain["status"] == "failed" &&
                  large_chain["tool_evidence"][0]["content_retained"] == false,
              "executor evidence was taken after presentation clipping");
        for (const auto& row : load_core_event_tail(20)) {
            check(row.dump().find("RAW_FIXTURE_KEEP_LOCAL") == std::string::npos,
                  "raw tool content escaped into the metadata journal");
        }

        const godbrain_rag::Client skill_client(
            godbrain_rag::default_transport, godbrain_rag::default_get_transport,
            [&](const std::string& body) {
                const json request = json::parse(body);
                const std::string query = request.at("query");
                const json skill = {
                    {"name", "fixture-procedure"},
                    {"content", "BEGIN_SKILL_" + query + " " + std::string(7500, 's') +
                        "\nlist_local_dir is quoted reference text, not a routing signal. "
                        "\xC3\xA5\xF0\x9F\x98\x80\nFINAL_SKILL_STEP_" + query},
                    {"origin_node_id", "fixture-origin"}, {"origin_hash", std::string(64, 'a')},
                    {"verification_profile", "desk-v1"}, {"untrusted", true},
                };
                return godbrain_rag::HttpResult{
                    true, 200, "application/json",
                    json({{"query", query}, {"count", 1}, {"skills", json::array({skill})}}).dump()};
            });
        const auto full_skill = [&](const std::string& query) {
            local_tools::Call call;
            call.name = "query_godbrain_skills";
            call.args = query;
            bool ok = false;
            const std::string reference = local_tools::execute_calls({call}, &ok, nullptr, "", &skill_client);
            check(ok && reference.find("FINAL_SKILL_STEP_" + query) != std::string::npos,
                  "Could not obtain the complete bounded skill fixture");
            return reference;
        };
        const std::string alpha = full_skill("alpha");
        const std::string beta = full_skill("beta");
        const auto skill_padding = root / "godbrain_core" / "cpp_kernel" / "skill-padding.txt";
        std::ofstream(skill_padding, std::ios::binary | std::ios::trunc) << std::string(6000, 'p');
        auto skill_batch = native_call("read_local_file", {{"path", skill_padding.string()}});
        const auto skill_call = native_call("query_godbrain_skills", {{"args", "alpha"}});
        skill_batch.deltas.back()["tool_calls"].push_back(skill_call.deltas.back()["tool_calls"][0]);
        const auto batched_skill = run(
            {skill_batch, completion("", "Complete procedure received.")},
            "off", "Fixture procedure batch.", "Fixture system.", true, true, false, "", false, &skill_client);
        const std::string delivered_batch = batched_skill.requests.at(1)["messages"].back()["content"];
        const json saved_skill = load_chain();
        const auto renewed_skill = revalidate_chain_references(saved_skill, skill_client);
        check(renewed_skill["ledger"].get<std::string>().find(alpha) != std::string::npos,
              "Canonical-current procedure was dropped on Continue");
        const godbrain_rag::Client expired_skill_client(
            godbrain_rag::default_transport, godbrain_rag::default_get_transport,
            [](const std::string& body) {
                const auto query = json::parse(body).at("query");
                return godbrain_rag::HttpResult{
                    true, 200, "application/json",
                    json({{"query", query}, {"count", 0}, {"skills", json::array()}}).dump()};
            });
        const auto expired_skill = revalidate_chain_references(saved_skill, expired_skill_client);
        check(expired_skill["ledger"].get<std::string>().find("BEGIN_SKILL_alpha") == std::string::npos &&
                  expired_skill["ledger"].get<std::string>().find("Cached procedure withheld") != std::string::npos,
              "Expired or revoked procedure survived Continue");
        check(delivered_batch.find(alpha) != std::string::npos &&
                  delivered_batch.find("Earlier tool results omitted") != std::string::npos &&
                  saved_skill["ledger"].get<std::string>().find(alpha) != std::string::npos &&
                  saved_skill["hop_ok"] == true &&
                  saved_skill["tool_evidence"].size() == 2 &&
                  saved_skill["tool_evidence"][1]["result_bytes"] == alpha.size() &&
                  saved_skill["tool_evidence"][1]["result_keccak256"] == browser_evidence::keccak_hex(alpha) &&
                  resume_chain_prompt(saved_skill, "Continue fixture.").find(alpha) != std::string::npos,
              "Same-round batching, persistence or Continue clipped the accepted procedure");
        const auto later_skill = run(
            {native_call("read_local_file", {{"path", skill_padding.string()}}), skill_call,
             completion("", "Complete later procedure received.")},
            "off", "Fixture later procedure.", "Fixture system.", true, true, false, "", false, &skill_client);
        check(later_skill.requests.at(2)["messages"].back()["content"].get<std::string>().find(alpha) != std::string::npos,
              "Accumulated earlier rounds clipped the current procedure");
        const std::string analysis_question = "Explain this procedure in " + root.string();
        check(local_tools::looks_like_local_fs_ask(analysis_question) &&
                  !local_tools::looks_like_list_only_ask(analysis_question),
              "Procedure presentation fixture did not enter the analysis route");
        const auto analysis_skill = run(
            {skill_call, completion("", "The reference was not replaced by a repo map.")},
            "off", analysis_question, "Fixture system.", true, true, false, "", false, &skill_client);
        check(analysis_skill.requests.at(0)["messages"].back()["content"].get<std::string>().find(
                  "Kernel repo map") != std::string::npos &&
                  analysis_skill.requests.at(1)["messages"].back()["content"].get<std::string>().find(alpha) != std::string::npos,
              "Quoted list_local_dir procedure text triggered a repo-map replacement");
        auto two_skills = skill_call;
        two_skills.deltas.back()["tool_calls"].push_back(
            native_call("query_godbrain_skills", {{"args", "beta"}}).deltas.back()["tool_calls"][0]);
        const auto newest_skill = run(
            {two_skills, completion("", "Newest complete procedure received.")},
            "off", "Fixture multiple procedures.", "Fixture system.", true, true, false, "", false, &skill_client);
        const std::string delivered_newest = newest_skill.requests.at(1)["messages"].back()["content"];
        check(delivered_newest.find(beta) != std::string::npos &&
                  delivered_newest.find("BEGIN_SKILL_alpha") == std::string::npos &&
                  delivered_newest.find("Earlier tool results omitted") != std::string::npos,
              "Multiple accepted procedures left an unmarked partial reference");
        const auto legacy_skill = run(
            {completion("", "*** TOOL\nname: query_godbrain_skills\nargs: alpha\n*** END\n"),
             completion("", "Legacy complete procedure received.")},
            "off", "Fixture legacy procedure.", "Fixture system.", true, true, false, "", false, &skill_client);
        check(legacy_skill.requests.at(1)["messages"].back()["content"].get<std::string>().find(alpha) != std::string::npos,
              "Legacy TOOL flattening clipped the complete procedure");
        const auto legacy_oversize = run(
            {completion("", "*** TOOL\nname: query_godbrain_skills\nargs: alpha\n*** END\n"
                            "*** TOOL\nname: query_godbrain_skills\nargs: beta\n*** END\n"),
             completion("", "Oversized procedure batch was omitted.")},
            "off", "Fixture oversized legacy procedures.", "Fixture system.", true, true, false, "", false, &skill_client);
        const std::string delivered_omission = legacy_oversize.requests.at(1)["messages"].back()["content"];
        check(delivered_omission.find("No partial output or procedure returned") != std::string::npos &&
                  delivered_omission.find("BEGIN_SKILL_") == std::string::npos &&
                  load_chain()["status"] == "failed",
              "Oversized legacy batch returned a partial procedure or hid delivery failure");

        run({completion(private_text, "*** TOOL\nname: list_granted_roots\n*** END\n"),
             completion("", "Legacy tool complete.")}, "on", "Fixture legacy tools.");
        check(load_chain()["tool_evidence"].size() == 1 &&
                  load_chain()["tool_evidence"][0]["executor_ok"] == true &&
                  load_chain()["verification"]["status"] == "not_run",
              "legacy TOOL execution bypassed evidence capture");

        run({completion(private_text, "*** TOOL\nname: list_granted_roots\n*** END\n")},
            "on", "No tools. Fixture prohibited call.");
        check(load_chain()["tool_evidence"][0]["executor_ok"] == false &&
                  load_chain()["status"] == "failed",
              "streamed TOOL text escaped its empty advertised tool set");

        const std::string long_goal = "Fixture resumable task " + std::string(600, 'z');
        save_chain(long_goal, "prior ledger", "", 1, "after");
        const auto resume_id = load_chain()["id"];
        run({tool_reply, completion("", "Resumed.")}, "on", long_goal);
        check(load_chain()["id"] == resume_id &&
                  load_chain()["evidence_history_complete"] == false,
              "restart/long-goal continuation lost identity or claimed complete history");
        ChainEvidence bounded;
        bounded.task_id = mint_chain_id();
        bounded.attempt_id = mint_chain_id();
        for (int i = 0; i < 129; ++i) {
            record_tool_evidence(bounded, {}, {}, true, "synthetic result metadata");
        }
        save_chain("bounded evidence", "", "answer", 1, "final", true, &bounded);
        check(load_chain()["tool_evidence"].size() == 128 &&
                  load_chain()["evidence_omitted"] == 1 &&
                  load_chain()["evidence_history_complete"] == false,
              "bounded evidence silently claimed complete retained history");

        ChainEvidence cancelled;
        cancelled.task_id = mint_chain_id();
        cancelled.attempt_id = mint_chain_id();
        save_chain(long_goal, "", "", 1, "before", true, &cancelled);
        httplib::Response cancel_response;
        handle_cancel_chain({}, cancel_response);
        save_chain(long_goal, "later output", "done", 1, "final", true, &cancelled);
        check(load_chain()["status"] == "cancelled" &&
                  load_chain()["execution"]["outcome"] == "cancelled" &&
                  chain_is_cancelled(long_goal),
              "in-flight save overwrote cancellation or missed the unclipped goal");

        for (const auto& invalid : {std::string("{"), std::string("[]"),
                                    std::string(R"({"verification":{"status":"passed","scope":"task_outcome"}})"),
                                    std::string(R"({"skill_promote_eligible":true})"),
                                    std::string(128 * 1024 + 1, ' ')}) {
            std::ofstream(chain_path(), std::ios::binary | std::ios::trunc) << invalid;
            bool rejected = false;
            try { load_chain(); } catch (const std::runtime_error&) { rejected = true; }
            check(rejected, "invalid task state or a forged verifier/promotion claim was accepted");
        }
        std::ofstream(chain_path(), std::ios::trunc) << "{}";
        save_chain("persist fixture", "", "", 1);
        const auto preserved = load_chain();
        ChainEvidence oversized;
        oversized.task_id = mint_chain_id();
        oversized.attempt_id = mint_chain_id();
        oversized.results = json::array({{{"oversized_fixture", std::string(128 * 1024, 'x')}}});
        bool size_rejected = false;
        try { save_chain("oversized fixture", "", "", 1, "after", true, &oversized); }
        catch (const std::runtime_error& failure) {
            size_rejected = std::string(failure.what()).find("readable bound") != std::string::npos;
        }
        check(size_rejected && load_chain() == preserved,
              "An unreadable serialized ledger replaced the previous task");
        size_rejected = false;
        try { resume_chain_prompt({{"ledger", std::string(kToolContextBytes + 1, 'x')}}, "Continue."); }
        catch (const std::runtime_error&) { size_rejected = true; }
        check(size_rejected, "Continue silently clipped oversized persisted context");
        const auto tmp_chain = std::filesystem::path(chain_path() + ".tmp");
        std::filesystem::create_directory(tmp_chain);
        bool write_failed = false;
        try { save_chain("must fail", "", "", 1); }
        catch (const std::runtime_error&) { write_failed = true; }
        std::filesystem::remove(tmp_chain);
        check(write_failed && load_chain() == preserved,
              "failed evidence write replaced the previous task or returned success");
        const auto event_path = std::filesystem::path(core_events_path());
        const auto event_backup = logs / "events.fixture-backup";
        std::filesystem::rename(event_path, event_backup);
        std::filesystem::create_directory(event_path);
        bool journal_failed = false;
        try {
            run({native_call("write_local_file", {{"path", artifact.string()},
                                                {"content", "must not execute"}})},
                "on", "Fixture blocked journal.");
        } catch (const std::runtime_error&) { journal_failed = true; }
        std::filesystem::remove(event_path);
        std::filesystem::rename(event_backup, event_path);
        std::ifstream unchanged(artifact, std::ios::binary);
        const std::string kept((std::istreambuf_iterator<char>(unchanged)), {});
        unchanged.close();
        check(journal_failed && kept == large_text && load_chain()["phase"] == "before",
              "a tool ran without durable admission evidence");
        std::ofstream(chain_path(), std::ios::trunc) << "{}";

        int saved_oracles = 0;
        bool fail_save = false;
        const std::string oracle_id(64, 'a');
        g_oracle_save = [&](const json& payload) {
            ++saved_oracles;
            check(payload["sector"] == "oracle", "Oracle retention changed sector");
            check(payload["content"].get<std::string>().find("PRIVATE_REASONING") == std::string::npos,
                  "private reasoning entered a retained candidate");
            if (fail_save) throw std::runtime_error("synthetic store failure");
            return json{{"status", "success"}, {"stable_id", oracle_id}};
        };
        const std::string local_reply =
            "A local reply that remains available without being retained.";
        remember_oracle_turn("Fixture ordinary conversation.", local_reply, 1);
        check(saved_oracles == 0 && last_oracle_json()["retention"] == "local_only" &&
                  oracle_retention_requests().empty(),
              "ordinary chat was automatically retained or queued for retry");
        std::string local_context, local_error;
        check(memory::render_session_context(local_context, local_error) &&
                  local_context.find(local_reply) != std::string::npos &&
                  local_context.find("candidate") != std::string::npos,
              "selective retention broke untrusted local session continuity");
        {
            std::lock_guard<std::mutex> lock(g_last_oracle_mu);
            g_oracle_turns.clear();
        }
        load_oracle_turns();
        check(last_oracle_json()["answer"] == local_reply &&
                  oracle_retention_requests().empty(),
              "restart lost local history or requeued intentionally unretained replies");
        fail_save = true;
        bool save_failed = false;
        try { ensure_last_oracle_id(); }
        catch (const std::runtime_error&) { save_failed = true; }
        check(save_failed && last_oracle_json()["retention"] == "requested" &&
                  last_oracle_json()["stored"] == false,
              "failed explicit retention returned a stored candidate or lost intent");
        load_oracle_turns();
        check(oracle_retention_requests().size() == 1,
              "explicit failed retention was not recoverable after restart");
        fail_save = false;
        std::string judgment_error;
        check(resolve_judgment_id("last", judgment_error) == oracle_id &&
                  judgment_error.empty() && last_oracle_json()["stored"] == true &&
                  oracle_retention_requests().empty(),
              "lazy explicit judgment did not retain the selected local turn");
        const int saved_before_repeat = saved_oracles;
        check(ensure_last_oracle_id() == oracle_id && saved_oracles == saved_before_repeat,
              "repeated judgment duplicated candidate retention");
        check(mark_oracle_status(oracle_id, "verified"), "local judgment state was not updated");
        load_oracle_turns();
        check(last_oracle_json()["status"] == "verified", "explicit judgment was lost on restart");
        remember_oracle_turn("Fixture incomplete.",
                             "An unfinished reply intentionally left without a final sentence [cut", 1);
        check(ensure_last_oracle_id().empty() && saved_oracles == saved_before_repeat,
              "an incomplete reply was retained for judgment");

        std::ofstream(last_oracle_path(), std::ios::binary | std::ios::trunc) <<
            json({{"version", 1}, {"turns", json::array({
                {{"question", "Legacy unstored"},
                 {"answer", "This old reply was not deliberately selected for retention."},
                 {"ok", true}, {"complete", true}, {"stored", false}},
                {{"question", "Legacy stored"},
                 {"answer", "This old candidate must keep its existing stored identity."},
                 {"ok", true}, {"stored", true}, {"stable_id", oracle_id}}
            })}}).dump();
        load_oracle_turns();
        check(oracle_retention_requests().empty() && last_oracle_json()["stored"] == true &&
                  last_oracle_json()["stable_id"] == oracle_id,
              "legacy migration retried automatic clutter or discarded existing candidate identity");
        g_oracle_save = memory::save_thought;

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
        for (const bool native : {false, true}) {
            const auto hidden_tag = run({
                completion("PRIVATE_REASONING <unused49>", "", "length")
            }, "on", native ? "Fixture tool question." : "No tools. Fixture question.",
               "Fixture system.", true, false, true);
            check(hidden_tag.answer.compare(0, 6, "Error:") == 0 &&
                      hidden_tag.spoken == hidden_tag.answer && hidden_tag.tokens.empty() &&
                      hidden_tag.requests.size() == 1 && hidden_tag.recoveries == 1,
                  "hidden reasoning-only unused49 did not recover the llama slot exactly once");
        }
        const auto exl3_tag = run({
            completion("PRIVATE_REASONING <unused49>", "", "length")
        }, "on", "No tools. Fixture question.", "Fixture system.", true, true, true);
        check(exl3_tag.answer.compare(0, 6, "Error:") == 0 && exl3_tag.recoveries == 0,
              "EXL3 hidden tag attempted to start the paused llama mouth");
        json session_document = {
            {"node_id", "0123456789abcdef01234567"}, {"stable_id", "fixture:session-origin"},
            {"node_version", "v1"}, {"kind", "claim"}, {"sector", "security"},
            {"status", "verified"}, {"confidence", 1.0}, {"schema_version", "claim-v1"},
            {"content", "FRESH_SESSION_ORIGIN " + std::string(300, 'x') + " ORIGINAL_TAIL"},
            {"label", "Fixture session origin"},
        };
        json session_graph = {
            {"generation", "fixture-gen"}, {"projection_version", "hybrid-v1"},
            {"projection_schema", "rag-document-v2"}, {"count", 1}, {"truncated", false},
            {"links_truncated", false}, {"links", json::array()},
            {"nodes", json::array({{
                {"node_id", session_document["node_id"]},
                {"stable_id", session_document["stable_id"]},
                {"kind", "claim"}, {"sector", "security"}, {"status", "verified"},
                {"confidence", 1.0}, {"label", "Fixture session origin"},
            }})},
        };
        bool origin_available = true;
        int origin_reads = 0;
        const godbrain_rag::Client session_client(
            [](const std::string&) -> godbrain_rag::HttpResult {
                throw std::runtime_error("Session read unexpectedly posted");
            },
            [&](const std::string& path) {
                if (path.find("/v1/graph?limit=") == 0) {
                    return godbrain_rag::HttpResult{
                        true, 200, "application/json", session_graph.dump()};
                }
                check(path.find("/v1/document?id=") == 0, "Unexpected session GET path");
                ++origin_reads;
                json response = session_document;
                for (const auto& node : session_graph["nodes"]) {
                    if (path == "/v1/document?id=" + node["node_id"].get<std::string>()) {
                        response["node_id"] = node["node_id"];
                        response["stable_id"] = node["stable_id"];
                    }
                }
                return godbrain_rag::HttpResult{
                    origin_available, 200, "application/json", response.dump()};
            });
        // Evict earlier conversation fixtures without introducing a reset-only runtime API.
        for (int index = 0; index < 3; ++index) {
            const std::string id = "fixture:shelf:" + std::to_string(index);
            memory::note_session(id, id, "Untrusted conversation fixture", "verified");
        }
        check(memory::hydrate_session_from_rag(session_client)["loaded"] == 1,
              "Memory API did not hydrate a verified canonical reference");
        std::string session_context, session_error;
        check(memory::render_session_context(session_context, session_error, session_client) &&
                  session_context.find("FRESH_SESSION_ORIGIN") != std::string::npos &&
                  origin_reads == 2,
              "Memory API did not recheck an origin between hydration and prompt rendering");
        session_document["status"] = "stale";
        check(memory::render_session_context(session_context, session_error, session_client) &&
                  session_context.find("FRESH_SESSION_ORIGIN") == std::string::npos &&
                  session_context.find("Untrusted conversation fixture") != std::string::npos,
              "Memory API emitted retired verified context or lost unrelated local notes");
        const json stale_snapshot = memory::session_snapshot(8, session_client);
        check(stale_snapshot["omitted"].size() == 1 &&
                  stale_snapshot["thoughts"].size() == 2 &&
                  stale_snapshot["thoughts"][0]["status"] == "candidate",
              "Recall silently returned a stale reference or a local verified-status forgery");
        session_document["status"] = "verified";
        session_document["content"] =
            "FRESH_SESSION_ORIGIN " + std::string(300, 'x') + " CHANGED_TAIL";
        check(memory::session_snapshot(8, session_client)["omitted"].size() == 1,
              "Memory API only checked the clipped origin snippet");
        session_document["content"] =
            "FRESH_SESSION_ORIGIN " + std::string(300, 'x') + " ORIGINAL_TAIL";
        origin_available = false;
        check(memory::session_snapshot(8, session_client)["omitted"].size() == 1,
              "Unavailable canonical origin fell back to a cached verified snapshot");
        origin_available = true;
        check(memory::session_snapshot(8, session_client)["thoughts"].size() == 3,
              "Memory API lost its reference rather than recovering on retry");
        const json graph_node = session_graph["nodes"][0];
        json prompt_records = {{"results", json::array({{
            {"status", "verified"}, {"sector", "security"},
            {"snippet", "FRESH_FACT_PAST_160: keep the inspected boundary."},
        }})}};
        std::string prompt_rag, prompt_context, prompt_error;
        check(godbrain_rag::render_coli_notes(prompt_records, prompt_rag, prompt_error),
              "Could not render prompt-evidence fixture");
        check(memory::render_session_context(session_context, session_error, session_client),
              "Could not render current session for prompt-evidence fixture");
        check(godbrain_rag::compose_prompt_context(
                  prompt_rag, session_context, std::string(4000, 'd'),
                  prompt_context, prompt_error) &&
                  prompt_context.find("FRESH_FACT_PAST_160", 161) != std::string::npos &&
                  prompt_context.find("Untrusted conversation fixture") != std::string::npos &&
                  prompt_context.find("pointer_omitted=true") != std::string::npos &&
                  prompt_context.size() <= godbrain_rag::kContextBytes,
              "Prompt budgeting lost useful evidence, continuity or its deterministic bound");
        for (const bool exl3 : {false, true}) {
            for (const bool llama : {false, true}) {
                for (const bool with_history : {false, true}) {
                    const auto evidence_reply = run(
                        {completion("", "Fixture evidence received.")}, "off",
                        "No tools. Explain the fixture fact.", "Fixture system.", true,
                        exl3, llama, prompt_context, with_history);
                    const auto& messages = evidence_reply.requests.at(0).at("messages");
                    const std::string sent = messages.back().at("content");
                    check(sent == prompt_context + "\n\nNo tools. Explain the fixture fact." &&
                              sent.find("FRESH_FACT_PAST_160") != std::string::npos &&
                              sent.find("Untrusted conversation fixture") != std::string::npos &&
                              sent.find(godbrain_rag::kUntrustedEnd) <
                                  sent.find("\n\nNo tools.") &&
                              !evidence_reply.requests[0].contains("tools") &&
                              messages.size() == (with_history ? 4 : 2),
                          "Serialized model request lost current evidence, framing or history");
                }
            }
        }
        session_graph["nodes"] = json::array();
        for (int index = 0; index < 3; ++index) {
            json node = graph_node;
            node["node_id"] = std::string(23, 'a') + std::to_string(index);
            node["stable_id"] = "fixture:only-rag:" + std::to_string(index);
            session_graph["nodes"].push_back(node);
        }
        session_graph["count"] = 3;
        check(memory::hydrate_session_from_rag(session_client)["loaded"] == 3,
              "Could not seed the all-RAG fallback fixture");
        origin_available = false;
        check(memory::render_session_context(session_context, session_error, session_client) &&
                  session_context.empty(),
              "Unavailable origins left a nonempty wrapper that could bypass the prompt gate");
        const json empty_snapshot = memory::session_snapshot(8, session_client);
        check(empty_snapshot["thoughts"].empty() && empty_snapshot["omitted"].size() == 3,
              "All-withheld session recall hid diagnostics or exposed cached content");
        origin_available = true;
        check(memory::session_snapshot(8, session_client)["thoughts"].size() == 3,
              "Withholding all origins destroyed retryable references");
        session_graph["nodes"][0]["status"] = "candidate";
        session_graph["nodes"][1]["status"] = "rejected";
        session_graph["nodes"][2]["sector"] = "personal";
        const int before_ineligible = origin_reads;
        check(memory::hydrate_session_from_rag(session_client)["loaded"] == 0 &&
                  origin_reads == before_ineligible,
              "Boot hydration tried to seed nonverified or personal graph entries");

        std::cout << "reply_stream_test ok: answer-only channels, execution-not-verification, "
                     "preclip evidence, correlation/resume/cancel, fail-closed persistence, "
                     "selective/lazy/restart retention, private recovery, tool/edit guards "
                     "and canonical session revalidation, whole-procedure context/Continue "
                     "and hostname/pin isolation"
                  << std::endl;
    } catch (const std::exception& error) {
        std::cerr << "reply fixture " << case_index << ": " << error.what() << std::endl;
        result = 1;
    }
    server.stop();
    listener.join();
    return result;
}
