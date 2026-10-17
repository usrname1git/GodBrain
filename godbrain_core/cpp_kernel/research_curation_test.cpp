#include "research_mouth.h"
#include <atomic>
#include <fstream>
#include <iostream>
#include <thread>

using namespace godbrain_research;

static void check(bool pass, const char* message) {
    if (!pass) throw std::runtime_error(message);
}

template <class F> static void rejects(F operation) {
    try {
        operation();
    } catch (const std::exception&) {
        return;
    }
    throw std::runtime_error("expected explicit research failure");
}

static json selection(const Fixture& fixture) {
    return {{"decision", fixture.decision},
            {"quote", fixture.quote},
            {"related_ids", fixture.related},
            {"note", "Synthetic fixture classification."}};
}

static json model_selection(const Fixture& fixture) {
    auto result = selection(fixture);
    for (auto& id : result.at("related_ids")) {
        for (size_t i = 0; i < fixture.in.at("references").size(); ++i) {
            if (fixture.in.at("references").at(i).at("id") != id) continue;
            id = "r" + std::to_string(i + 1);
            break;
        }
    }
    return result;
}

static json unicode_relation_fixture() {
    const auto fixture = fixtures().at(3);
    const std::string sentence =
        "Windows\xC2\xA0" "component\xE2\x80\x83" "cleanup is disabled by default.";
    const godbrain_truth::Document source{sentence, "text/plain; charset=utf-8", true};
    const auto in = input(fixture.in.at("url"), fixture.in.at("title"), source,
                          fixture.in.at("references"));
    auto result = selection(fixture);
    result["quote"] = sentence;
    const auto observation = assertion(in, source, result);
    return relation_candidate(in, source, result,
                              observation.at("payload").at("provenance").at("source_hash"));
}

struct Loop {
    json state = initial_state();
    json persisted = state;
    int64_t now = 10000;
    int fetched = 0, inferred = 0, published = 0, saves = 0;
    std::string fail;
    std::string body = fixtures().at(0).in.at("source_text");
    json refs = json::array();
    std::string decision = "new";

    Operations operations(bool inference = true) {
        Operations ops;
        ops.persist = [&](const json& next) {
            if (fail == "persist") throw std::runtime_error("fixture disk failure");
            validate_state(next);
            persisted = strict_json(next.dump(), kMaxStateBytes);
            ++saves;
        };
        ops.discover = [&](const std::string& url) {
            check(url.rfind("https://learn.microsoft.com/api/search?", 0) == 0,
                  "discovery escaped the fixed primary-source endpoint");
            if (fail == "discover") throw std::runtime_error("fixture search unavailable");
            return json{
                {"count", 1},
                {"results",
                 json::array(
                     {{{"title", "Windows servicing fixture"},
                       {"url", "https://learn.microsoft.com/en-us/windows/test-fixture"}}})}};
        };
        ops.fetch = [&](const std::string&) {
            ++fetched;
            if (fail == "fetch") throw std::runtime_error("fixture source unavailable");
            return godbrain_truth::Document{body, "text/plain; charset=utf-8", true};
        };
        ops.references = [&](const std::string&) {
            if (fail == "references") throw std::runtime_error("fixture RAG unavailable");
            return refs;
        };
        if (inference) {
            ops.infer = [&](const json& request) {
                ++inferred;
                check(!request.contains("tools") && request.at("stream") == false &&
                          request.at("chat_template_kwargs").at("enable_thinking") == false,
                      "curation advertised execution tools or private thinking");
                if (fail == "infer") throw std::runtime_error("fixture model failed qualification");
                if (fail == "output") return std::string("```json\n{}\n```");
                auto result = selection(fixtures().at(0));
                result["decision"] = decision;
                if (decision == "irrelevant") result["quote"] = "";
                if (decision == "duplicate" || decision == "conflict")
                    result["related_ids"] = json::array({"r1"});
                return result.dump();
            };
        }
        ops.publish = [&](const json& in, const godbrain_truth::Document& source,
                          const json& result) {
            if (fail == "publish") throw std::runtime_error("fixture projection unavailable");
            ++published;
            const auto envelope = assertion(in, source, result);
            const auto raw = json::parse(envelope.at("raw_transcript").get<std::string>());
            check(raw.at("evidence").at("body") == source.body &&
                      envelope.at("payload").at("trust_tier") == "candidate",
                  "publication lost complete immutable evidence or bypassed candidate ingestion");
            if (result.at("decision") == "conflict" || result.at("decision") == "question") {
                const auto candidate = relation_candidate(
                    in, source, result, envelope.at("payload").at("provenance").at("source_hash"));
                check(candidate.at("payload").at("trust_tier") == "candidate" &&
                          candidate.at("payload")
                                  .at("claims")
                                  .at(0)
                                  .at("content")
                                  .get<std::string>()
                                  .find("NOT verified") != std::string::npos,
                      "semantic conflict acquired verified authority");
            }
            return json{
                {"observation", {{"stable_id", std::string(64, 'b')}, {"trust", "verified"}}}};
        };
        return ops;
    }

    json run(bool inference = true) { return tick(state, now, operations(inference)); }
};

static void test_mouth_binding() {
    httplib::Server server;
    std::atomic<bool> healthy{true}, busy{false};
    std::atomic<int> model{1}, fault{0}, posts{0};
    server.Get("/health", [&](const httplib::Request&, httplib::Response& response) {
        response.set_content(json{{"ok", healthy.load()}, {"busy", busy.load()}}.dump(),
                             "application/json");
    });
    server.Get("/v1/models", [&](const httplib::Request&, httplib::Response& response) {
        response.set_content(
            json{{"data", json::array({{{"id", "fixture-" + std::to_string(model.load())}}})}}
                .dump(),
            "application/json");
    });
    server.Post("/v1/chat/completions", [&](const httplib::Request&, httplib::Response& response) {
        ++posts;
        if (fault == 1) model = 2;
        json message = {{"role", "assistant"}, {"content", "{}"}};
        if (fault == 3) message["tool_calls"] = json::array({{{"id", "forbidden"}}});
        response.set_content(
            json{{"choices", json::array({{{"finish_reason", fault == 2 ? "length" : "stop"},
                                           {"message", message}}})}}
                .dump(),
            "application/json");
    });
    const int port = server.bind_to_any_port("127.0.0.1");
    check(port > 0, "cannot bind the isolated mouth fixture");
    std::thread thread([&] { server.listen_after_bind(); });
    struct Cleanup {
        httplib::Server& server;
        std::thread& thread;
        ~Cleanup() {
            server.stop();
            thread.join();
        }
    } cleanup{server, thread};
    for (int i = 0; i < 200 && !server.is_running(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    check(server.is_running(), "isolated mouth fixture did not start");
    const godbrain_research_mouth::Runner runner{port, "fixture-1",
                                                 godbrain_research_mouth::process_identity(port)};
    const auto request = godbrain_research::request(fixtures().front().in);
    healthy = false;
    rejects([&] { runner.infer(request); });
    healthy = true;
    busy = true;
    rejects([&] { runner.infer(request); });
    busy = false;
    model = 2;
    rejects([&] { runner.infer(request); });
    check(posts == 0, "unready/busy/replaced mouth received generation");
    model = 1;
    fault = 1;
    rejects([&] { runner.infer(request); });
    model = 1;
    fault = 2;
    rejects([&] { runner.infer(request); });
    fault = 3;
    rejects([&] { runner.infer(request); });
    fault = 0;
    check(runner.infer(request) == "{}" && posts == 4,
          "complete instance-bound tool-free transport failed");
}

int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--relation-document") {
            std::cout << unicode_relation_fixture().dump() << '\n';
            return 0;
        }
        if (argc == 4 && std::string(argv[1]) == "--sample") {
            const auto port = std::string(argv[2]);
            if (port != "8888" && port != "8000")
                throw std::runtime_error("invalid local model port");
            std::ifstream file(argv[3], std::ios::binary);
            if (!file) throw std::runtime_error("cannot read public sample fixture");
            const auto raw = godbrain_truth::read_document([&]() -> std::optional<std::string> {
                std::array<char, 8192> buffer{};
                file.read(buffer.data(), buffer.size());
                if (file.bad()) throw std::runtime_error("public sample read failed");
                if (!file.gcount()) return std::nullopt;
                return std::string(buffer.data(), static_cast<size_t>(file.gcount()));
            });
            const auto sample = strict_json(raw, godbrain_truth::kMaxDocumentBytes);
            const godbrain_truth::Document source{sample.at("body"), sample.at("content_type"),
                                                  true};
            const auto in =
                input(sample.at("url"), sample.at("title"), source, sample.at("references"));
            const auto runner = godbrain_research_mouth::connect(std::stoi(port));
            const auto selected = review(runner.infer(request(in)), in);
            json proof = {
                {"scope", "read-only public sample; no vault writes or qualification"},
                {"model_id", runner.model},
                {"selection", selected},
                {"source_hash", in.at("source_hash")},
                {"source_text_bytes", in.at("source_text").get_ref<const std::string&>().size()}};
            if (selected.at("decision") != "irrelevant" && selected.at("decision") != "duplicate")
                proof["observation"] = assertion(in, source, selected);
            std::cout << proof.dump(2) << '\n';
            return 0;
        }
        if (argc == 4 && std::string(argv[1]) == "--fixture") {
            const auto port = std::string(argv[2]);
            if (port != "8888" && port != "8000")
                throw std::runtime_error("invalid local model port");
            const auto runner = godbrain_research_mouth::connect(std::stoi(port));
            for (const auto& fixture : fixtures()) {
                if (fixture.name != argv[3]) continue;
                const auto output = runner.infer(request(fixture.in));
                std::cout << json{{"fixture", fixture.name},
                                  {"output", output},
                                  {"scope", "single-case diagnostic, not qualification"}}
                                 .dump(2)
                          << '\n';
                (void)review(output, fixture.in);
                return 0;
            }
            throw std::runtime_error("unknown protected fixture");
        }
        if (argc == 3 && std::string(argv[1]) == "--qualify") {
            const auto port = std::string(argv[2]);
            if (port != "8888" && port != "8000")
                throw std::runtime_error("invalid local model port");
            const auto runner = godbrain_research_mouth::connect(std::stoi(port));
            auto proof = qualify([&](const json& request) { return runner.infer(request); });
            proof["model_id"] = runner.model;
            proof["instance"] = runner.instance;
            proof["scope"] = "protected curation fixtures only; not general model qualification";
            std::cout << proof.dump(2) << '\n';
            return proof.at("pass").get<bool>() ? 0 : 1;
        }
        check(argc == 1, "unsupported research test arguments");
        test_mouth_binding();
        const auto cases = fixtures();
        {
            const auto candidate = unicode_relation_fixture();
            const auto content = candidate.at("payload").at("claims").at(0).at("content").get<std::string>();
            const auto normalized = godbrain_truth::collapse_ws(content);
            const auto marker = normalized.find("relation=");
            check(marker != std::string::npos &&
                      json::parse(normalized.substr(marker + 9)) ==
                          json::parse(candidate.at("raw_transcript").get<std::string>()).at("relation") &&
                      std::all_of(content.begin(), content.end(),
                                  [](unsigned char ch) { return ch < 128; }) &&
                      candidate.at("extractor_version") == kRelationExtractorVersion,
                  "relation normalization changed its Unicode quote or reused the old extractor");
        }
        {
            int reads = 0;
            const auto unavailable = [&]() -> std::string {
                ++reads;
                throw std::runtime_error("fixture Windows pin unavailable");
            };
            require_reference_pin("An unpinned Windows document.", unavailable);
            check(reads == 0, "unpinned research required a Windows pin");
            const std::string pinned = "A host-specific finding. os_pin=fixture/123.45";
            require_reference_pin(pinned, [] { return "fixture/123.45"; });
            rejects([&] { require_reference_pin(pinned, unavailable); });
            rejects([&] { require_reference_pin(pinned, [] { return ""; }); });
            rejects([&] { require_reference_pin(pinned, [] { return "fixture/123.46"; }); });
            rejects([&] {
                require_reference_pin(pinned + " os_pin=fixture/123.46",
                                      [] { return "fixture/123.45"; });
            });
        }
        {
            const auto& fixture = cases.at(3);
            const godbrain_truth::Document source{fixture.in.at("source_text"),
                                                  "text/plain; charset=utf-8", true};
            for (const auto* failure : {"relation", "observation", "judge", "none"}) {
                std::vector<std::string> calls;
                const auto publish = [&] {
                    return publish_selection(
                        fixture.in, source, selection(fixture), "fixture-model",
                        [&](const json& document) {
                            const bool relation =
                                document.at("extractor_id") == "Kernel-Research-CPP";
                            const std::string stage = relation ? "relation" : "observation";
                            calls.push_back(stage);
                            if (stage == failure) throw std::runtime_error("fixture commit failed");
                            return json{{"status", "success"},
                                        {"store_status", "committed"},
                                        {"stable_id", std::string(64, relation ? 'a' : 'b')},
                                        {"source_hash",
                                         document.at("payload").at("provenance").at("source_hash")},
                                        {"run_id", "fixture-run"},
                                        {"record_id", "fixture-record"}};
                        },
                        [&](const json& judgment) {
                            calls.push_back("judge");
                            check(judgment.at("id") == std::string(64, 'b'),
                                  "semantic relation reached automatic judgment");
                            if (std::string(failure) == "judge")
                                throw std::runtime_error("fixture judgment failed");
                            return json{{"status", "judged"},
                                        {"stable_id", judgment.at("id")},
                                        {"to", "verified"}};
                        });
                };
                if (std::string(failure) == "none") {
                    check(publish().at("observation").at("trust") == "verified" &&
                              calls == std::vector<std::string>{"relation", "observation", "judge"},
                          "unresolved relation was not durable before verified observation");
                } else {
                    rejects(publish);
                    check(!calls.empty() && calls.front() == "relation" &&
                              (std::string(failure) != "relation" || calls.size() == 1),
                          "failed relation was hidden by its own verified duplicate");
                }
            }
        }
        const Infer synthetic = [&](const json& request) {
            for (const auto& fixture : cases) {
                if (godbrain_research::request(fixture.in) == request)
                    return model_selection(fixture).dump();
            }
            throw std::runtime_error("unknown synthetic fixture");
        };
        const auto simulated = qualify(synthetic);
        check(simulated.at("pass") == true && simulated.at("count") == cases.size(),
              "protected fixture verifier rejected its exact synthetic answers");
        check(qualify([](const json&) { return "{}"; }).at("pass") == false,
              "invalid model output qualified");
        {
            const auto failed = qualify([](const json&) -> std::string {
                throw std::runtime_error("fixture transient HTTP failure");
            });
            const std::string instance = "same-runner";
            check(!qualification_current(failed.at("pass"), instance, instance, 1000, 1001),
                  "transient qualification failure was cached");
            int attempts = 0;
            auto recovered = failed;
            if (!qualification_current(failed.at("pass"), instance, instance, 1000, 1001)) {
                ++attempts;
                recovered = qualify(synthetic);
            }
            check(attempts == 1 && recovered.at("pass") == true &&
                      qualification_current(true, instance, instance, 1000, 1001) &&
                      !qualification_current(true, instance, "replaced-runner", 1000, 1001) &&
                      !qualification_current(true, instance, instance, 1000, 1000 + 6 * 60 * 60 * 1000ULL) &&
                      !qualification_current(true, instance, instance, 1000, 999),
                  "qualification cache identity or lifetime gate failed");
        }
        const auto in = cases.at(0).in;
        auto good = selection(cases.at(0));
        for (const auto* bad : {"unknown", "quote", "reference", "relation"}) {
            auto output = good;
            if (std::string(bad) == "unknown") output["status"] = "verified";
            if (std::string(bad) == "quote")
                output["quote"] = "This unsupported sentence is invented.";
            if (std::string(bad) == "reference")
                output["related_ids"] = json::array({std::string(64, 'f')});
            if (std::string(bad) == "relation") output["decision"] = "conflict";
            rejects([&] { review(output.dump(), in); });
        }
        rejects([&] { review(R"({"decision":"new","decision":"irrelevant"})", in); });
        rejects([&] { review(good.dump() + "{}", in); });
        {
            auto partial = model_selection(cases.back());
            partial["quote"] = "replace the Windows component store.";
            rejects([&] { review(partial.dump(), cases.back().in); });
            auto wrong_label = model_selection(cases.back());
            wrong_label["related_ids"] = json::array({"r2"});
            rejects([&] { review(wrong_label.dump(), cases.back().in); });
            rejects([&] { review(selection(cases.back()).dump(), cases.back().in); });
        }
        for (const auto* url :
             {"https://example.invalid/a", "http://learn.microsoft.com/en-us/windows/a",
              "https://learn.microsoft.com.evil.invalid/en-us/windows/a",
              "https://learn.microsoft.com/en-us/dotnet/a",
              "https://learn.microsoft.com/en-us/windows/%2e%2e/a",
              "https://learn.microsoft.com/en-us/windows/../a"})
            rejects([&] { source_url(url); });
        {
            Loop loop;
            check(loop.run(false).at("status") == "discovered" &&
                      loop.state.at("queue").size() == 1 && loop.fetched == 0 &&
                      loop.inferred == 0 && loop.published == 0,
                  "discovery-only tick used inference, fetched a page, or wrote the vault");
            check(loop.run().at("status") == "checked" && loop.published == 1,
                  "idle local curation did not publish a checked observation");
            loop.now += kDay;
            check(loop.run().at("decision") == "unchanged" && loop.inferred == 1,
                  "unchanged source/manual repeated model work");
            loop.refs = json::array(
                {{{"id", std::string(64, 'a')}, {"content", "A new canonical finding."}}});
            loop.now += kDay;
            check(loop.run().at("decision") == "new" && loop.inferred == 2,
                  "changed manual reused stale novelty classification");
            loop.body += " A new source version contains another complete sentence.";
            loop.now += kDay;
            check(loop.run().at("status") == "checked" && loop.published == 3,
                  "changed source reused its old immutable evidence binding");
        }
        for (const auto* failure : {"fetch", "references", "infer", "output", "publish"}) {
            Loop loop;
            loop.run(false);
            loop.fail = failure;
            for (int attempt = 1; attempt <= 6; ++attempt) {
                check(loop.run().at("status") == "retry" &&
                          loop.state.at("queue").at(0).at("failures") == attempt &&
                          loop.state.at("queue").at(0).at("last_hash") == "",
                      "failed worker acknowledged a source or lost retry progression");
                loop.now = loop.state.at("queue").at(0).at("due");
            }
            check(!summary(loop.state).at("exceptions").empty(),
                  "exhausted recovery was not escalated");
            loop.fail.clear();
            check(loop.run().at("status") == "checked" &&
                      summary(loop.state).at("exceptions").empty(),
                  "recovered source did not clear its grouped exception");
        }
        for (const auto* decision : {"duplicate", "irrelevant", "conflict", "question"}) {
            Loop loop;
            loop.decision = decision;
            loop.refs = json::array({{{"id", std::string(64, 'a')}, {"content", loop.body}}});
            check(loop.run().at("status") == "checked", "valid relation failed");
            const bool selects =
                std::string(decision) == "conflict" || std::string(decision) == "question";
            check(loop.published == (selects ? 1 : 0),
                  "discarded/duplicate source polluted the vault");
        }
        {
            Loop loop;
            loop.fail = "persist";
            rejects([&] { loop.run(); });
            check(loop.fetched == 0 && loop.inferred == 0 && loop.published == 0,
                  "failed durable checkpoint allowed external work");
        }
        {
            Loop loop;
            loop.run(false);
            loop.state["queue"][0]["failures"] = 5;
            loop.state["queue"][0]["reason"] = "worker_interrupted";
            loop.state["queue"][0]["due"] = loop.now;
            loop.persisted = loop.state;
            loop.state = strict_json(loop.persisted.dump(), kMaxStateBytes);
            loop.fail = "fetch";
            loop.run();
            check(loop.state.at("queue").at(0).at("failures") == 6,
                  "restart reset interrupted-worker recovery");
        }
        {
            Loop loop;
            loop.fail = "discover";
            for (int i = 0; i < 6; ++i) {
                loop.run(false);
                loop.now = loop.state.at("discover_after");
            }
            check(summary(loop.state).at("exceptions").contains("discovery_failed"),
                  "failed discovery did not reach bounded escalation");
            loop.fail.clear();
            check(loop.run(false).at("status") == "discovered", "discovery could not recover");
        }
        {
            Loop loop;
            loop.run(false);
            loop.now = loop.state.at("discover_after");
            loop.fail = "discover";
            check(loop.run().at("status") == "partial" && loop.published == 1,
                  "successful curation hid a simultaneous discovery failure");
        }
        {
            auto state = initial_state();
            state["topic"] = uint64_t{1} << 32;
            rejects([&] { validate_state(state); });
            state = initial_state();
            state["discovery_failures"] = uint64_t{1} << 32;
            rejects([&] { validate_state(state); });
            rejects([&] { strict_json("{\"profile\":1,\"profile\":2}", 512); });
            const godbrain_truth::Document source{"not complete", "text/plain", false};
            rejects([&] { input(in.at("url"), in.at("title"), source, json::array()); });
        }
        std::cout
            << "PASS: protected curation verifier, fixed discovery, authority/quote bounds, "
               "novelty invalidation, candidate conflicts, durable retry/restart and recovery "
               "(offline only; no local model qualified)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
