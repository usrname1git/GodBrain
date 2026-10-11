#include "phone_desk.h"
#include <atomic>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <sddl.h>

using phone_desk::json;
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
void test_owner_recovery(const json& status) {
    using namespace std::chrono;
    const steady_clock::time_point start{};
    phone_desk::OwnerIdentity owner;
    unsigned reads = 0;
    auto ready = [&]() { ++reads; return status; };
    auto unavailable = [&]() -> json { ++reads; throw std::runtime_error("Fixture daemon unavailable"); };
    check(owner.resolve(false, ready, start).empty() && reads == 0, "Spoof caused owner lookup");
    check(owner.resolve(true, unavailable, start).empty() && reads == 1, "Failed owner lookup accepted");
    check(owner.resolve(true, ready, start + seconds(29)).empty() && reads == 1, "Owner retry was not bounded");
    check(owner.resolve(true, [&]() { ++reads; return json::object(); }, start + seconds(30)).empty(),
          "Missing owner became an identity");
    check(owner.resolve(true, ready, start + seconds(60)) == "operator@example.invalid" && reads == 3,
          "Owner did not recover after startup");
    check(owner.resolve(true, unavailable, start + hours(1)) == "operator@example.invalid" && reads == 3,
          "Resolved owner was not pinned");
    check(owner.resolve(false, ready, start + hours(1)).empty() && reads == 3, "Untrusted peer obtained owner");
    phone_desk::OwnerIdentity concurrent;
    std::atomic<unsigned> calls{0}, matches{0};
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 8; ++i) threads.emplace_back([&]() {
        const auto login = concurrent.resolve(true, [&]() {
            ++calls;
            std::this_thread::sleep_for(milliseconds(20));
            return status;
        }, start);
        if (login == "operator@example.invalid") ++matches;
    });
    for (auto& thread : threads) thread.join();
    check(calls == 1 && matches == 8, "Concurrent owner requests duplicated or raced lookup");
}

void test_proxy_lineage() {
    const phone_desk::ProxyProcessIdentity service{100, 50, 0, 1000, L"tailscaled.exe"};
    const phone_desk::ProxyProcessIdentity worker{101, 100, 0, 1001, L"tailscaled.exe"};
    check(phone_desk::valid_proxy_lineage(service, service), "Direct service peer rejected");
    check(phone_desk::valid_proxy_lineage(service, worker), "Immediate service worker rejected");
    check(!phone_desk::valid_proxy_lineage({}, worker), "Absent SCM process accepted");
    check(!phone_desk::valid_proxy_lineage(service, {}), "Absent socket process accepted");
    auto forged = worker;
    forged.parent_pid = 99;
    check(!phone_desk::valid_proxy_lineage(service, forged), "Unrelated same-name worker accepted");
    forged = worker; forged.session = 1;
    check(!phone_desk::valid_proxy_lineage(service, forged), "Interactive same-name worker accepted");
    forged = service; forged.session = 1;
    check(!phone_desk::valid_proxy_lineage(forged, worker), "Interactive service accepted");
    forged = worker; forged.created = 999;
    check(!phone_desk::valid_proxy_lineage(service, forged), "Worker predating service accepted");
    forged = worker; forged.image = L"other.exe";
    check(!phone_desk::valid_proxy_lineage(service, forged), "Wrong worker image accepted");
    forged = service; forged.image = L"other.exe";
    check(!phone_desk::valid_proxy_lineage(forged, worker), "Wrong service image accepted");
    check(phone_desk::same_proxy_process(worker, worker), "Stable worker rejected");
    for (unsigned field = 0; field < 5; ++field) {
        forged = worker;
        if (field == 0) ++forged.pid;
        if (field == 1) ++forged.parent_pid;
        if (field == 2) ++forged.session;
        if (field == 3) ++forged.created;
        if (field == 4) forged.image = L"other.exe";
        check(!phone_desk::same_proxy_process(worker, forged), "Changed/recycled worker accepted");
    }
}

int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--rustdesk-status") {
            std::cout << phone_desk::read_rustdesk_status().dump() << '\n';
            return 0;
        }
        if (argc == 2 && std::string(argv[1]) == "--rustdesk-status-limited") {
            const json normal = phone_desk::read_rustdesk_status();
            HANDLE original = nullptr, restricted = nullptr;
            PSID admin = nullptr, medium = nullptr;
            try {
                check(OpenProcessToken(GetCurrentProcess(),
                      TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ADJUST_DEFAULT | TOKEN_IMPERSONATE, &original),
                      "Process token query failed");
                check(ConvertStringSidToSidW(L"S-1-5-32-544", &admin) &&
                      ConvertStringSidToSidW(L"S-1-16-8192", &medium), "Test SID creation failed");
                SID_AND_ATTRIBUTES disabled{admin, 0};
                check(CreateRestrictedToken(original, DISABLE_MAX_PRIVILEGE, 1, &disabled, 0, nullptr,
                      0, nullptr, &restricted), "Restricted token creation failed");
                TOKEN_MANDATORY_LABEL integrity{{medium, SE_GROUP_INTEGRITY}};
                check(SetTokenInformation(restricted, TokenIntegrityLevel, &integrity,
                      sizeof(integrity) + GetLengthSid(medium)), "Medium-integrity setup failed");
                check(ImpersonateLoggedOnUser(restricted), "Restricted-token impersonation failed");
                const json limited = phone_desk::read_rustdesk_status();
                check(RevertToSelf(), "Restricted-token cleanup failed");
                CloseHandle(restricted); restricted = nullptr;
                CloseHandle(original); original = nullptr;
                LocalFree(admin); admin = nullptr;
                LocalFree(medium); medium = nullptr;
                if (normal["state"] == "ready" || normal["state"] == "unready" || normal["state"] == "running")
                    check(limited["state"] != "unknown" && limited["state"] != "missing",
                          "Limited observation lost installed running service state");
                std::cout << limited.dump() << '\n';
                return 0;
            } catch (...) {
                RevertToSelf();
                if (restricted) CloseHandle(restricted);
                if (original) CloseHandle(original);
                if (admin) LocalFree(admin);
                if (medium) LocalFree(medium);
                throw;
            }
        }
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
        test_proxy_lineage();
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
        test_owner_recovery(status);
        check(phone_desk::owner_login(json::object()).empty(), "Missing owner defaulted");
        check(phone_desk::tailscale_status(status)["state"] == "ready", "Running daemon not ready");
        check(phone_desk::rustdesk_status("running", true)["state"] == "ready", "Observed server not ready");
        check(phone_desk::rustdesk_status("running", false)["state"] == "unready", "Missing server became ready");
        const json limited = phone_desk::rustdesk_status("running", false, "Access denied");
        check(limited["state"] == "running", "Server privilege failure erased known service state");
        check(limited["detail"].get<std::string>().find("Access denied") != std::string::npos, "Probe error was hidden");
        check(phone_desk::rustdesk_status("stopped", true)["state"] == "stopped", "GUI overrode stopped service");
        check(phone_desk::rustdesk_status("missing", false)["state"] == "missing", "Missing service misreported");
        check(phone_desk::tailscale_status(json::object())["state"] == "unknown", "Invalid daemon became ready");
        json offline = status;
        offline["Self"]["Online"] = false;
        check(phone_desk::tailscale_status(offline)["state"] == "unready", "Offline node became ready");
        offline["Self"].erase("Online");
        check(phone_desk::tailscale_status(offline)["state"] == "unknown", "Missing online state became ready");
        json speech = {{"service", "voice"}, {"device", "cpu"}, {"ok", true}, {"components", {
            {"stt", {{"state", "available"}, {"detail", "CPU weights present; not exercised"}}},
            {"tts", {{"state", "ready"}, {"detail", "Last synthesis succeeded"}}},
            {"ocr_cpu", {{"state", "unready"}, {"detail", "Image loader failed"}}}}}};
        const json speech_cards = phone_desk::speech_status(speech);
        check(speech_cards.size() == 3, "Speech cards missing");
        check(speech_cards[0]["state"] == "available", "Availability became verified readiness");
        check(speech_cards[2]["state"] == "unready" && speech_cards[2]["detail"] == "Image loader failed",
              "CPU OCR failure was hidden");
        check(phone_desk::speech_status(json::object())[0]["state"] == "unknown", "Missing speech health became ready");
        speech["components"]["ocr_cpu"]["state"] = true;
        check(phone_desk::speech_status(speech)[2]["state"] == "unknown", "Invalid OCR state became ready");
        speech["components"]["tts"]["detail"] = std::string(401, 'x');
        check(phone_desk::speech_status(speech)[1]["state"] == "unknown", "Oversized speech detail accepted");
        speech["ok"] = "true";
        check(phone_desk::speech_status(speech)[0]["state"] == "unknown", "Truthy speech readiness accepted");
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
        std::cout << "PASS: Phone Desk authorization, proxy lineage, bounded owner recovery, readiness and path redaction\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
