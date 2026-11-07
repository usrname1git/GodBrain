#define main librarian_program_main
#include "librarian.cpp"
#undef main
#include <filesystem>

static void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static json extraction(const std::string& span = "[0:4]", double confidence = 0.8) {
    return {{"claims", json::array({{
        {"claim_id", "fixture"}, {"type", "factual"}, {"content", "Fixture claim"},
        {"confidence", confidence}, {"evidence_spans", json::array({span})}
    }})}};
}
int main() {
    if (env_or("GODBRAIN_LIBRARIAN_TEST_CHILD", "") == "store") {
        const std::string input((std::istreambuf_iterator<char>(std::cin)), {});
        const auto request = json::parse(input);
        auto receipt = json{
            {"run_id", "fixture-run"}, {"record_id", "fixture-record"}, {"version", "v1"},
            {"schema_version", request.at("schema_version")}, {"status", "committed"},
            {"insert_count", 1}, {"update_count", 0}, {"timestamp", "2026-01-01T00:00:00Z"}};
        const auto mode = env_or("GODBRAIN_LIBRARIAN_TEST_RECEIPT", "");
        if (mode == "empty") receipt = json::object();
        if (mode == "failed") receipt["status"] = "failed";
        if (mode == "missing") receipt.erase("record_id");
        if (mode == "wrong-schema") receipt["schema_version"] = "wrong";
        if (mode == "negative") receipt["insert_count"] = -1;
        if (mode == "noop") { receipt["status"] = "idempotent_noop"; receipt["insert_count"] = 0; }
        std::cout << receipt.dump();
        return 0;
    }
    if (env_or("SERVE", "") == "1") {
        std::cout << "READY\n" << std::flush;
        std::string header;
        std::getline(std::cin, header);
        std::istringstream parser(header);
        std::string marker;
        size_t bytes = 0;
        parser >> marker >> bytes;
        std::string input(bytes, '\0');
        std::cin.read(input.data(), static_cast<std::streamsize>(bytes));
        auto result = extraction();
        result["core_concepts"] = json::array({keccak256(input)});
        std::cout << result.dump() << std::flush;
        return 0;
    }
    const auto directory = std::filesystem::temp_directory_path() /
        ("GodBrain-Librarian-" + std::to_string(GetCurrentProcessId()));
    std::filesystem::create_directory(directory);
    const auto prompt = directory / "prompt.json";
    httplib::Server server;
    std::vector<json> requests;
    std::mutex request_mutex;
    std::vector<json> pending_requests;
    std::vector<std::string> replies;
    server.Get("/health", [](const httplib::Request&, httplib::Response& response) {
        response.set_content("{}", "application/json");
    });
    server.Post("/v1/chat/completions", [&](const httplib::Request& request, httplib::Response& response) {
        std::lock_guard<std::mutex> lock(request_mutex);
        const auto index = pending_requests.size();
        pending_requests.push_back(json::parse(request.body));
        if (index >= replies.size()) { response.status = 500; return; }
        response.set_content(json({{"choices", json::array({
            {{"message", {{"content", replies[index]}}}, {"finish_reason", "stop"}}})}}).dump(), "application/json");
    });
    const auto port = server.bind_to_any_port("127.0.0.1");
    if (port < 1) return 1;
    std::thread listener([&] { server.listen_after_bind(); });
    server.wait_until_ready();
    int status = 0;
    try {
        std::ofstream(prompt, std::ios::binary) <<
            R"({"prompt_version":"fixture-template","system_prompt":"UNUSED_TEMPLATE_SENTINEL"})";
        char executable[MAX_PATH]{};
        check(GetModuleFileNameA(nullptr, executable, MAX_PATH) != 0, "Missing test executable");
        LibrarianConfig config{executable, prompt.string(), executable, "fixture", "fixture-hash",
                               "127.0.0.1", port, 0.1, false};
        const SourceEnvelope source("fixture", "a\xc3\xa9z", "session_transcript");
        LLMDistillationProvider provider(config);
        const auto run = [&](std::vector<std::string> sequence) {
            {
                std::lock_guard<std::mutex> lock(request_mutex);
                replies = std::move(sequence); pending_requests.clear();
            }
            try {
                auto result = provider.distill(source);
                std::lock_guard<std::mutex> lock(request_mutex);
                requests = pending_requests;
                return result;
            } catch (...) {
                std::lock_guard<std::mutex> lock(request_mutex);
                requests = pending_requests;
                throw;
            }
        };
        auto valid = run({extraction().dump()});
        check(valid.payload.provenance.prompt_hash == keccak256(requests.back().at("messages").dump()) &&
              valid.extractor_version.find("librarian-http-v2") != std::string::npos &&
              requests.back().dump().find("UNUSED_TEMPLATE_SENTINEL") == std::string::npos,
              "HTTP provenance did not bind the executed short prompt");
        for (const auto& bad : {std::string("{"), extraction("[0:100]").dump(),
                              extraction("[2:4]").dump(), extraction("[0:2]").dump(),
                              extraction("[0:4]", 1.5).dump()}) {
            valid = run({bad, extraction().dump()});
            check(requests.size() == 2 &&
                  requests[0]["messages"][0]["content"] != requests[1]["messages"][0]["content"] &&
                  valid.payload.provenance.prompt_hash == keccak256(requests.back().at("messages").dump()),
                  "Validation retry omitted HTTP feedback or used stale prompt provenance");
        }
        bool rejected = false;
        try { run({extraction("[0:100]").dump(), extraction("[0:100]").dump()}); }
        catch (const std::runtime_error&) { rejected = true; }
        check(rejected && requests.size() == 2, "Invalid source evidence escaped bounded retries");
        _putenv_s("GODBRAIN_LIBRARIAN_SPAWN", "1");
        config.mouth_port = 1;
        const auto spawned = LLMDistillationProvider(config).distill(source);
        check(spawned.payload.provenance.prompt_hash == spawned.payload.core_concepts.at(0) &&
              spawned.extractor_version.find("colibri-framed-v2/fixture-template") != std::string::npos,
              "Spawn provenance did not bind the executed frame");
        _putenv_s("GODBRAIN_LIBRARIAN_SPAWN", "");
        _putenv_s("GODBRAIN_LIBRARIAN_TEST_CHILD", "store");
        SubprocessMemoryStore store(executable);
        for (const char* mode : {"", "noop"}) {
            _putenv_s("GODBRAIN_LIBRARIAN_TEST_RECEIPT", mode);
            check(store.upsert(source, valid).record_id == "fixture-record", "Valid native receipt rejected");
        }
        for (const char* mode : {"empty", "failed", "missing", "wrong-schema", "negative"}) {
            _putenv_s("GODBRAIN_LIBRARIAN_TEST_RECEIPT", mode);
            bool failed = false;
            try { store.upsert(source, valid); } catch (const std::exception&) { failed = true; }
            check(failed, "Invalid native receipt reported successful persistence");
        }
        _putenv_s("GODBRAIN_LIBRARIAN_TEST_CHILD", "");
        std::cout << "librarian_test ok: actual prompt provenance, retries, source byte spans, framed spawn and store receipts\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; status = 1;
    }
    server.stop(); listener.join();
    std::filesystem::remove(prompt);
    std::filesystem::remove(directory);
    return status;
}
