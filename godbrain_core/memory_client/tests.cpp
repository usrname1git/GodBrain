#define GODBRAIN_CLIENT_TEST
#include "main.cpp"

#include <atomic>
#include <functional>
#include <sstream>
#include <thread>

namespace {
using namespace godbrain_client;
int checks = 0;

void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
    ++checks;
}

void rejects(const std::function<void()>& operation, const char* message) {
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, message);
}

Command arguments(std::initializer_list<std::string> args, const std::string& input = "") {
    std::istringstream stream(input);
    return parse_arguments(std::vector<std::string>(args), stream);
}

J record(const J& input) {
    J payload = input;
    payload.erase("action");
    payload["host_id"] = "fixture-target";
    J row = payload;
    row["schema_version"] = "working-shelf-v1";
    row["trust"] = "untrusted";
    row["source_hash"] = hash(row.at("text").get<std::string>());
    row["payload_hash"] = hash(payload.dump());
    row["_id"] = hash("working-shelf-v1\n" + row.at("shelf").get<std::string>() +
        "\ntechnical\nfixture-target\n" + row.at("request_id").get<std::string>());
    row["created_at"] = "2026-01-01T00:00:00Z";
    row["saved_ms"] = 1;
    return row;
}

J receipt(const Command& command) {
    return {{"schema_version", "working-shelf-v1"}, {"trust", "untrusted"},
            {"promoted", false}, {"status", "stored"}, {"idempotent", false},
            {"shelf", command.payload.at("shelf")}, {"record", record(command.payload)}};
}

void request_and_receipt_tests() {
    check(hash("") == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          "Legacy Keccak compatibility changed");
    const std::string unicode = "Observed caf\xc3\xa9 \xf0\x9f\x99\x82\nNot verified.";
    const auto post = arguments({"post", "research", "--thread", "fixture", "--request-id", "fixture-1",
        "--title", "Scoped finding", "--file", "-", "--source", "fixture artifact; sha256=example"}, unicode);
    check(post.payload.at("text") == unicode, "UTF-8 input changed");
    validate_response(post, receipt(post));
    ++checks;
    const auto retry = arguments({"post", "research", "--thread", "fixture", "--request-id", "fixture-1",
        "--title", "Scoped finding", "--file", "-", "--source", "fixture artifact; sha256=example"}, unicode);
    check(post.payload == retry.payload, "Retry changed its idempotent payload");
    for (const auto* field : {"source_hash", "payload_hash", "_id"}) {
        auto bad = receipt(post);
        bad["record"][field] = std::string(64, '0');
        rejects([&] { validate_response(post, bad); }, "Bad provenance hash accepted");
    }
    auto other = post;
    other.payload["text"] = "Different complete content";
    rejects([&] { validate_response(post, receipt(other)); }, "Mismatched post echo accepted");
    auto promoted = receipt(post);
    promoted["promoted"] = true;
    rejects([&] { validate_response(post, promoted); }, "Promoted shelf receipt accepted");
    const auto read = arguments({"read", "research", "--thread", "fixture", "--limit", "1"});
    J rows{{"schema_version", "working-shelf-v1"}, {"trust", "untrusted"}, {"promoted", false},
           {"status", "ok"}, {"shelf", "research"}, {"records", J::array({record(post.payload)})},
           {"count", 1}, {"more", false}};
    validate_response(read, rows);
    ++checks;
    auto cross_scope = rows;
    cross_scope["records"][0]["scope"] = "personal";
    rejects([&] { validate_response(read, cross_scope); }, "Personal record entered technical output");
    auto other_thread = post;
    other_thread.payload["thread_id"] = "different-thread";
    rows["records"][0] = record(other_thread.payload);
    rejects([&] { validate_response(read, rows); }, "Another thread entered thread-bound read");
    rows["records"] = J::array({record(post.payload), record(post.payload)});
    rows["count"] = 2;
    rejects([&] { validate_response(read, rows); }, "Oversized record count accepted");
    auto personal = post;
    personal.payload["scope"] = "personal";
    rejects([&] { validate_request(personal); }, "Personal request accepted");
    rejects([&] { arguments({"post", "research", "--thread", "fixture", "--request-id", "x",
        "--title", "Fixture", "--file", "-"}, "No provenance"); }, "Unbound post accepted");
    rejects([&] { arguments({"post", "research", "--thread", "fixture", "--request-id", "x",
        "--title", "Fixture", "--file", "-", "--source", "fixture"}, std::string(32769, 'x')); },
        "Oversized post accepted");
    rejects([&] { arguments({"post", "research", "--thread", "fixture", "--request-id", "x",
        "--title", "Fixture", "--file", "-", "--source", "fixture"}, "\xc3"); }, "Invalid UTF-8 accepted");
    rejects([&] { arguments({"context", "--thread", "bad thread"}); }, "Invalid thread accepted");
    rejects([&] { arguments({"context", "--thread", "x", "--scope", "personal"}); }, "Scope override accepted");
    rejects([&] { arguments({"read", "personal"}); }, "Personal shelf accepted");
    rejects([&] { arguments({"read", "research", "--limit", "21"}); }, "Unbounded read accepted");
    rejects([&] { arguments({"read", "research", "--limit", "1junk"}); }, "Partial number accepted");
    rejects([&] { arguments({"context", "--thread", "a", "--thread", "b"}); }, "Duplicate option accepted");
    rejects([&] { arguments({"/api/judge"}); }, "Arbitrary route accepted");
}

void configuration_tests() {
    std::array<char, 64> pattern{};
    const std::string prefix = "/tmp/godbrain-memory-test-XXXXXX";
    std::copy(prefix.begin(), prefix.end(), pattern.begin());
    auto* directory_path = mkdtemp(pattern.data());
    if (!directory_path) throw std::runtime_error("Cannot create isolated configuration fixture");
    const std::string path = std::string(directory_path) + "/client.json";
    const auto write_config = [&](const std::string& host, const std::string& token) {
        std::ofstream file(path);
        file << J{{"host", host}, {"token", token}}.dump();
        file.close();
        if (!file || chmod(path.c_str(), 0600) != 0) throw std::runtime_error("Fixture write failed");
    };
    try {
        Descriptor directory(open(directory_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        write_config("127.0.0.1", "fixture-secret");
        check(load_config(directory.get()).token == "fixture-secret", "Private config did not load");
        chmod(path.c_str(), 0644);
        rejects([&] { load_config(directory.get()); }, "World-readable credential accepted");
        chmod(path.c_str(), 0600);
        chmod(directory_path, 0755);
        rejects([&] { load_config(directory.get()); }, "Public credential directory accepted");
        chmod(directory_path, 0700);
        write_config("example.com", "fixture-secret");
        rejects([&] { load_config(directory.get()); }, "DNS endpoint accepted");
        write_config("192.0.2.1", "fixture-secret");
        rejects([&] { load_config(directory.get()); }, "Public endpoint accepted");
        write_config("127.0.0.1", "fixture\r\ninjected: header");
        rejects([&] { load_config(directory.get()); }, "Credential header injection accepted");
        for (const auto& token : {std::string("fixture\"secret"), std::string("fixture\\secret")}) {
            write_config("127.0.0.1", token);
            check(load_config(directory.get()).token == token, "Accepted credential encoding changed");
        }
        write_config("127.0.0.1", "fixture-secret");
        const auto original = path + ".original";
        if (rename(path.c_str(), original.c_str()) != 0 || symlink("client.json.original", path.c_str()) != 0)
            throw std::runtime_error("Cannot create symlink fixture");
        rejects([&] { load_config(directory.get()); }, "Symlinked credential accepted");
        unlink(path.c_str());
        if (link(original.c_str(), path.c_str()) != 0) throw std::runtime_error("Cannot create hardlink fixture");
        rejects([&] { load_config(directory.get()); }, "Multiply linked credential accepted");
        unlink(path.c_str());
        unlink(original.c_str());
        rmdir(directory_path);
    } catch (...) {
        unlink(path.c_str());
        unlink((path + ".original").c_str());
        rmdir(directory_path);
        throw;
    }
}

void transport_tests() {
    httplib::Server server;
    std::atomic<int> calls{0};
    std::atomic<int> mode{0};
    const std::array<std::string, 3> tokens{
        "fixture-transport-token", "fixture\"secret", "fixture\\secret"};
    const auto full_post = arguments({"post", "research", "--thread", "fixture", "--request-id", "large-1",
        "--title", "Complete fixture", "--file", "-", "--source", "offline fixture"}, std::string(8192, 'x'));
    const auto full_record = record(full_post.payload);
    server.Post("/api/context", [&](const httplib::Request& req, httplib::Response& response) {
        ++calls;
        const auto authorization = req.get_header_value("Authorization");
        const auto token = authorization.rfind("Bearer ", 0) == 0 ? authorization.substr(7) : "";
        if (std::find(tokens.begin(), tokens.end(), token) == tokens.end()) {
            response.status = 401;
            return;
        }
        if (mode == 1) {
            response.status = 307;
            response.set_header("Location", "/credential-leak");
            return;
        }
        if (mode == 2) {
            response.set_content(std::string(response_limit + 1, 'x'), "application/json");
            return;
        }
        if (mode == 5) {
            response.set_content(
                R"({"schema_version":"shared-context-v1","state":"ready","scope":"technical","trust":"untrusted_reference","context":"fixture-\u0074ransport-token","request_tools":[]})",
                "application/json");
            return;
        }
        J context{{"schema_version", "shared-context-v1"}, {"state", "ready"},
                  {"scope", "technical"}, {"trust", "untrusted_reference"},
                  {"context", "Untrusted fixture \xf0\x9f\x99\x82"}, {"request_tools", J::array()}};
        if (mode == 3) context["request_tools"] = J::array({"run_command"});
        if (mode == 4) context["scope"] = "personal";
        if (mode == 6) context["context"] = token;
        if (mode == 7) {
            context["research"] = {{"records", J::array({full_record})}};
            context["host_profile"] = {{"raw", "host-snapshot-canary"}};
            context["capabilities"] = {{"raw", "capability-canary"}};
        }
        if (mode == 8) context["extra"] = J{{token, "fixture"}};
        if (mode == 9) context["extra"] = J::array({J{{"nested", token}}});
        response.set_content(context.dump(), "application/json");
    });
    server.Post("/api/shelf", [&](const httplib::Request& req, httplib::Response& response) {
        if (req.get_header_value("Authorization") != "Bearer fixture-transport-token") {
            response.status = 401;
            return;
        }
        response.set_content(J{{"schema_version", "working-shelf-v1"}, {"trust", "untrusted"},
            {"promoted", false}, {"status", "ok"}, {"shelf", "research"},
            {"records", J::array({full_record})}, {"count", 1}, {"more", false}}.dump(), "application/json");
    });
    server.Post("/credential-leak", [&](const httplib::Request&, httplib::Response&) { ++calls; });
    const int port = server.bind_to_any_port("127.0.0.1");
    if (port <= 0) throw std::runtime_error("Cannot bind loopback-only offline test server");
    std::thread listener([&] { server.listen_after_bind(); });
    server.wait_until_ready();
    const auto stop = [&] { server.stop(); listener.join(); };
    try {
        Config config{"127.0.0.1", "fixture-transport-token", port};
        const auto context = arguments({"context", "--thread", "fixture"});
        check(perform(config, context).at("state") == "ready", "Native HTTP context request failed");
        auto invalid = config;
        invalid.token = "wrong-token";
        rejects([&] { perform(invalid, context); }, "Invalid authentication accepted");
        mode = 1;
        const int before = calls;
        rejects([&] { perform(config, context); }, "Redirect accepted");
        check(calls == before + 1, "Redirect followed or request silently retried");
        mode = 2;
        rejects([&] { perform(config, context); }, "Oversized HTTP response accepted");
        mode = 3;
        rejects([&] { perform(config, context); }, "Context granted tools");
        mode = 4;
        rejects([&] { perform(config, context); }, "Cross-scope context accepted");
        mode = 5;
        rejects([&] { perform(config, context); }, "JSON-escaped credential entered output");
        auto secret = context;
        secret.payload["query"] = config.token;
        const int before_secret = calls;
        rejects([&] { perform(config, secret); }, "Credential was sent as source data");
        check(calls == before_secret, "Rejected credential made a network request");
        for (size_t i = 1; i < tokens.size(); ++i) {
            auto escaped = config;
            escaped.token = tokens[i];
            secret.payload["query"] = escaped.token;
            const int before_escaped = calls;
            rejects([&] { perform(escaped, secret); }, "JSON-escaped request credential accepted");
            check(calls == before_escaped, "Escaped request credential made a network request");
            mode = 6;
            rejects([&] { perform(escaped, context); }, "JSON-escaped response credential accepted");
            mode = 8;
            rejects([&] { perform(escaped, context); }, "Credential in decoded object key accepted");
            mode = 9;
            rejects([&] { perform(escaped, context); }, "Credential in nested response value accepted");
        }
        mode = 7;
        const auto bounded = perform(config, context);
        check(bounded.size() == 6 && !bounded.contains("research") && !bounded.contains("host_profile") &&
              !bounded.contains("capabilities"), "Context emitted unchecked envelope fields");
        check(bounded.at("context") == "Untrusted fixture \xf0\x9f\x99\x82",
              "Context projection changed bounded UTF-8 evidence");
        const auto full_read = arguments({"read", "research", "--limit", "1"});
        check(perform(config, full_read).at("records").at(0).at("text") == full_post.payload.at("text"),
              "Explicit shelf read lost complete content beyond the context budget");
        stop();
    } catch (...) {
        stop();
        throw;
    }
}
}

int main() {
    try {
        request_and_receipt_tests();
        configuration_tests();
        transport_tests();
        std::cout << checks << " native client checks passed (offline, loopback fixtures only)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Client test failed: " << error.what() << '\n';
        return 1;
    }
}
