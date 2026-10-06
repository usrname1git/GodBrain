#include "phone_desk.h"
#include <iostream>
#include <stdexcept>

using phone_desk::json;
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
int main() {
    try {
        httplib::Request request;
        request.remote_addr = "127.0.0.1";
        request.method = "GET";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Anonymous request accepted");
        request.headers.emplace("Tailscale-User-Login", "operator@example.invalid");
        check(phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Owner Serve identity rejected");
        check(!phone_desk::authorized(request, "", "operator@example.invalid"), "Unconfigured server accepted");
        check(!phone_desk::authorized(request, " \t", "operator@example.invalid"), "Blank token accepted");
        request.body = R"({"command_type":"fixture"})";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Control body accepted");
        request.body.clear();
        request.headers.emplace("Content-Length", "0");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Body framing accepted");
        request.headers.erase("Content-Length");
        request.headers.emplace("Transfer-Encoding", "chunked");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Chunked body accepted");
        request.headers.erase("Transfer-Encoding");
        request.params.emplace("command_type", "fixture");
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Control query accepted");
        request.params.clear();
        request.method = "POST";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Mutation verb accepted");
        request.method = "GET";
        check(!phone_desk::authorized(request, "fixture", "other@example.invalid"), "Shared device identity accepted");
        request.remote_addr = "100.64.0.1";
        check(!phone_desk::authorized(request, "fixture", "operator@example.invalid"), "Direct remote spoof accepted");
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
