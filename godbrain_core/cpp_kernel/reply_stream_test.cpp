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
                  large_chain["ledger"].get<std::string>().size() <= 4000 &&
                  large_chain["tool_evidence"][0]["content_retained"] == false,
              "executor evidence was taken after presentation clipping");
        for (const auto& row : load_core_event_tail(20)) {
            check(row.dump().find("RAW_FIXTURE_KEEP_LOCAL") == std::string::npos,
                  "raw tool content escaped into the metadata journal");
        }

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
        std::cout << "reply_stream_test ok: answer-only channels, execution-not-verification, "
                     "preclip evidence, correlation/resume/cancel, fail-closed persistence, "
                     "selective/lazy/restart retention, legacy migration and tool/edit guards"
                  << std::endl;
    } catch (const std::exception& error) {
        std::cerr << "reply fixture " << case_index << ": " << error.what() << std::endl;
        result = 1;
    }
    server.stop();
    listener.join();
    return result;
}
