#include "phone_desk.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

using phone_desk::json;
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
int main(int argc, char** argv) {
    try {
        if (argc == 3 && std::string(argv[1]) == "--image-health-fixture") {
            std::ifstream input(argv[2]);
            const json health = json::parse(input);
            for (const char* phase : {"idle", "busy"}) {
                const json model = phone_desk::model_status(8871, json::object(), health.at(phase));
                check(model["name"] == "Qwen-Image-2.1", "Real image endpoint identity was lost");
                check(model["state"] == (std::string(phase) == "idle" ? "ready" : "busy"), "Real image endpoint state was lost");
            }
            std::cout << "PASS: actual Python image health contract consumed by C++ Phone Desk\n";
            return 0;
        }
        if (argc == 4 && std::string(argv[1]) == "--proxy-fixture") {
            httplib::Server fixture;
            const std::string owner = argv[3];
            fixture.Get("/", [&](const httplib::Request& req, httplib::Response& res) {
                const bool proxy = phone_desk::trusted_serve_peer(req);
                res.status = phone_desk::authorized(req, "fixture", owner, proxy) ? 200 : 403;
                res.set_content(json({{"authenticated_proxy", proxy}}).dump(), "application/json");
            });
            if (!fixture.listen("127.0.0.1", std::stoi(argv[2]))) throw std::runtime_error("Proxy fixture listener failed");
            return 0;
        }
        httplib::Request request;
        request.remote_addr = "127.0.0.1";
        request.method = "GET";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Anonymous request accepted");
        request.headers.emplace("Tailscale-User-Login", "operator@example.invalid");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Local owner header spoof accepted");
        check(!phone_desk::trusted_serve_peer(request), "Incomplete socket tuple trusted");
        check(phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Authenticated owner Serve identity rejected");
        check(!phone_desk::authorized(request, "", "operator@example.invalid", true), "Unconfigured server accepted");
        check(!phone_desk::authorized(request, " \t", "operator@example.invalid", true), "Blank token accepted");
        request.body = R"({"command_type":"fixture"})";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Control body accepted");
        request.body.clear();
        request.headers.emplace("Content-Length", "0");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Body framing accepted");
        request.headers.erase("Content-Length");
        request.headers.emplace("Transfer-Encoding", "chunked");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Chunked body accepted");
        request.headers.erase("Transfer-Encoding");
        request.params.emplace("command_type", "fixture");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Control query accepted");
        request.params.clear();
        request.method = "POST";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Mutation verb accepted");
        request.method = "GET";
        check(!phone_desk::authorized(request, "fixture", "other@example.invalid", true), "Shared device identity accepted");
        request.remote_addr = "100.64.0.1";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid", true), "Direct remote spoof accepted");
        request.remote_addr = "127.0.0.1";
        request.headers.clear();
        request.headers.emplace("Authorization", "Bearer fixture");
        check(phone_desk::authorized(request, "fixture", ""), "Local bearer rejected");
        check(!phone_desk::authorized(request, "wrong", ""), "Wrong bearer accepted");
        const json status = {{"Self", {{"UserID", 42u}, {"Online", true}}}, {"User", {{"42", {{"LoginName", "operator@example.invalid"}}}}},
                             {"BackendState", "Running"}};
        check(phone_desk::owner_login(status) == "operator@example.invalid", "Owner extraction failed");
        check(phone_desk::owner_login(json::object()).empty(), "Missing owner defaulted");
        check(phone_desk::tailscale_status(status)["state"] == "ready", "Running daemon not ready");
        check(phone_desk::tailscale_status(json::object())["state"] == "unknown", "Invalid daemon became ready");
        json offline = status;
        offline["Self"]["Online"] = false;
        check(phone_desk::tailscale_status(offline)["state"] == "unready", "Offline node became ready");
        offline["Self"].erase("Online");
        check(phone_desk::tailscale_status(offline)["state"] == "unknown", "Missing online state became ready");
        const json models = {{"data", json::array({{{"id", "C:\\private\\Qwen-test"}}})}};
        const json health = {{"ok", true}, {"busy", true}, {"context_length", 40960}};
        const json model = phone_desk::model_status(8888, models, health);
        check(model["name"] == "Qwen-test", "Private path leaked");
        check(model["state"] == "busy", "Busy model misreported");
        check(phone_desk::model_status(8888, json::object(), health)["state"] == "unknown", "Invalid model became ready");
        check(phone_desk::model_status(8888, models, json::object())["state"] == "unknown", "Absent readiness became ready");
        check(phone_desk::model_status(8888, models, {{"ok", false}, {"busy", true}})["state"] == "unready", "Busy hid failed readiness");
        check(phone_desk::model_status(8888, models, {{"ok", true}, {"busy", "false"}})["state"] == "unknown", "Invalid activity became ready");
        check(phone_desk::model_status(8871, json::object(), {{"ok", true}, {"model", "Qwen-Image"}, {"loaded", "true"}})["state"] == "unknown", "Invalid image residency became ready");
        check(phone_desk::model_status(8000, models, {{"status", "ok"}})["state"] == "ready", "llama health dialect rejected");
        check(phone_desk::model_status(8871, json::object(), {{"ok", true}, {"ready", false}, {"model", "Qwen-Image"}})["state"] == "unready", "Unready image API became ready");
        check(phone_desk::model_status(8871, json::object(), {{"ok", true}, {"model", "Qwen-Image"}, {"loaded", false}})["detail"]
              .get<std::string>().find("unloaded") != std::string::npos, "Idle image API became loaded");
        std::cout << "PASS: Phone Desk authorization, identity, readiness and path redaction\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
