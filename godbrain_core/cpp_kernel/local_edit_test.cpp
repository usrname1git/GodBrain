#include <fstream>
#include <iostream>
#include <string>

#include "local_edit.h"
#include <windows.h>

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    const std::string think_then_apply =
        "I will change the starter.\n"
        "*** APPLY\n"
        "path: Start-GodBrain.ps1\n"
        "<<<<\n"
        "old line\n"
        "====\n"
        "new line\n"
        ">>>>\n"
        "*** END\n";
    auto preview = local_edit::preview_apply_blocks(think_then_apply);
    if (!expect(preview.count == 1, "think then apply count") ||
        !expect(preview.first_path == "Start-GodBrain.ps1", "think then apply path") ||
        !expect(preview.first_old == "old line\n", "think then apply old") ||
        !expect(preview.first_new == "new line\n", "think then apply new")) {
        return 1;
    }

    const std::string messy =
        "plan sludge\n"
        "***APPLY\n"
        "path: `godbrain_core/cpp_kernel/main.cpp`\n"
        "<<<<\n"
        "foo\n"
        "====\n"
        "bar\n"
        ">>>>\n"
        "***END\n";
    preview = local_edit::preview_apply_blocks(messy);
    if (!expect(preview.count == 1, "messy count") ||
        !expect(preview.first_path == "godbrain_core\\cpp_kernel\\main.cpp",
                "messy path strips ticks and slashes")) {
        return 1;
    }

    preview = local_edit::preview_apply_blocks("no blocks here");
    if (!expect(preview.count == 0, "empty text has no blocks")) {
        return 1;
    }

    preview = local_edit::preview_apply_blocks(
        "*** APPLY\npath: Start-GodBrain.ps1\nno markers\n*** END\n");
    if (!expect(preview.count == 0, "missing <<<< is not a hunk")) {
        return 1;
    }

    {
        const std::string primed = local_edit::edit_user_with_excerpt(
            "/edit godbrain_core/frontend/galaxy.html after Inbox: none "
            "add a GPU line");
        if (!expect(primed.find("Inbox: none") != std::string::npos,
                    "excerpt includes Inbox glance") ||
            !expect(primed.find("GODBRAIN_RAG_UNTRUSTED") == std::string::npos,
                    "edit prompt has no RAG jail notice") ||
            !expect(primed.find("Heal: none") != std::string::npos,
                    "excerpt window includes Heal glance")) {
            return 1;
        }
    }

    if (!expect(local_edit::looks_like_edit_request("/edit Start-GodBrain.ps1 add a log"),
                "/edit is an edit") ||
        !expect(local_edit::looks_like_edit_request(
                    "/edit godbrain_core/frontend/galaxy.html add inbox"),
                "/edit galaxy.html is an edit") ||
        !expect(local_edit::looks_like_edit_request(
                    "change galaxy.html host card"),
                "html named change is an edit") ||
        !expect(!local_edit::looks_like_edit_request("what is the hostname"),
                "chat is not an edit")) {
        return 1;
    }

    preview = local_edit::preview_apply_blocks(
        "*** APPLY\n"
        "path: godbrain_core/frontend/galaxy.html\n"
        "<<<<\n"
        "old html\n"
        "====\n"
        "new html\n"
        ">>>>\n");
    if (!expect(preview.count == 1, "unclosed END still a hunk") ||
        !expect(preview.first_path == "godbrain_core\\frontend\\galaxy.html",
                "unclosed END keeps galaxy path") ||
        !expect(preview.first_new == "new html\n", "unclosed END new text")) {
        return 1;
    }

    const std::string one_closed =
        "*** APPLY\npath: a.txt\n<<<<\nold\n====\nnew\n>>>>\n*** END\n";
    const std::string one_open =
        "*** APPLY\npath: a.txt\n<<<<\nold\n====\nnew\n";
    const std::string two_second_open =
        one_closed + "*** APPLY\npath: b.txt\n<<<<\nsecond old\n====\n";
    const std::string two_closed =
        one_closed +
        "*** APPLY\npath: b.txt\n<<<<\nsecond old\n====\nsecond new\n>>>>\n";
    if (!expect(!local_edit::apply_still_open(""), "empty is closed") ||
        !expect(!local_edit::apply_still_open("no markers"),
                "prose is closed") ||
        !expect(!local_edit::apply_still_open(one_closed),
                "finished hunk is closed") ||
        !expect(local_edit::apply_still_open(one_open),
                "truncated first hunk is open") ||
        !expect(local_edit::apply_still_open(two_second_open),
                "finished hunk plus truncated second is open") ||
        !expect(!local_edit::apply_still_open(two_closed),
                "two finished hunks are closed")) {
        return 1;
    }

    if (!expect(local_edit::check_profile_for("scripts\\Show-SystemFlex.ps1") ==
                    "powershell-parse-v1",
                "ps1 profile") ||
        !expect(local_edit::check_profile_for("godbrain_core/cpp_kernel/main.cpp") ==
                    "kernel-file-v1",
                "kernel profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\memory_store\\store.go") ==
                    "memory-store-go-v1",
                "go profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\frontend\\galaxy.html") ==
                    "galaxy-html-static-v1",
                "galaxy profile") ||
        !expect(local_edit::check_profile_for("godbrain_core\\cpp_tools\\librarian.cpp") ==
                    "librarian-self-test-v1",
                "librarian profile") ||
        !expect(local_edit::check_profile_for("docs\\architecture\\current.md") ==
                    "local-edit-apply-v1",
                "md stays apply-only")) {
        return 1;
    }

    char exe[MAX_PATH] = {};
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    std::string dir(exe);
    const size_t slash = dir.find_last_of("\\/");
    if (slash != std::string::npos) dir.resize(slash);
    const std::string fixture = dir + "\\local_edit_fixture.txt";
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    const std::string apply =
        "*** APPLY\n"
        "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
        "<<<<\n"
        "EDIT_FIXTURE=old\n"
        "====\n"
        "EDIT_FIXTURE=new\n"
        ">>>>\n"
        "*** END\n";
    auto result = local_edit::maybe_apply(
        "/edit godbrain_core/cpp_kernel/local_edit_fixture.txt flip marker",
        apply,
        {});
    std::string body;
    {
        std::ifstream in(fixture, std::ios::binary);
        body.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    }
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(result.attempted, "apply attempted") ||
        !expect(result.applied, "apply wrote") ||
        !expect(body == "EDIT_FIXTURE=new\n", "fixture became new")) {
        std::cerr << "report=" << result.report << " body=" << body << std::endl;
        return 1;
    }

    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    bool second_called = false;
    const std::string user_hunk =
        "/edit godbrain_core/cpp_kernel/local_edit_fixture.txt flip marker\n"
        "*** APPLY\n"
        "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
        "<<<<\n"
        "EDIT_FIXTURE=old\n"
        "====\n"
        "EDIT_FIXTURE=from-user\n"
        ">>>>\n"
        "*** END\n";
    result = local_edit::maybe_apply(
        user_hunk,
        "*** APPLY\npath: godbrain_core/cpp_kernel/local_edit_fixture.txt\n<<<<\n",
        [&](const std::string&, const std::string&) {
            second_called = true;
            return std::string();
        });
    {
        std::ifstream in(fixture, std::ios::binary);
        body.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    }
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(!second_called, "user APPLY skips second pass") ||
        !expect(result.applied, "user APPLY wrote") ||
        !expect(body == "EDIT_FIXTURE=from-user\n", "fixture from user hunk")) {
        std::cerr << "user hunk report=" << result.report << " body=" << body
                  << std::endl;
        return 1;
    }

    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    std::string second_user;
    result = local_edit::maybe_apply(
        "/edit godbrain_core/frontend/galaxy.html add inbox glance",
        "I will patch the host card.\n",
        [&](const std::string&, const std::string& usr) {
            second_user = usr;
            return "*** APPLY\n"
                   "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
                   "<<<<\n"
                   "EDIT_FIXTURE=old\n"
                   "====\n"
                   "EDIT_FIXTURE=from-second\n"
                   ">>>>\n"
                   "*** END\n";
        });
    {
        std::ifstream in(fixture, std::ios::binary);
        body.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    }
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(second_user.find("galaxy.html") != std::string::npos,
                "second pass names galaxy.html") ||
        !expect(result.applied, "second pass wrote") ||
        !expect(body == "EDIT_FIXTURE=from-second\n",
                "fixture from second pass")) {
        std::cerr << "second report=" << result.report
                  << " usr_has=" << (second_user.size()) << std::endl;
        return 1;
    }

    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\r\n";
    }
    result = local_edit::maybe_apply(
        "/edit godbrain_core/cpp_kernel/local_edit_fixture.txt crlf",
        "*** APPLY\n"
        "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
        "<<<<\n"
        "EDIT_FIXTURE=old\n"
        "====\n"
        "EDIT_FIXTURE=crlf\n"
        ">>>>\n"
        "*** END\n",
        {});
    {
        std::ifstream in(fixture, std::ios::binary);
        body.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    }
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(result.applied, "crlf apply wrote") ||
        !expect(body == "EDIT_FIXTURE=crlf\r\n", "lf hunk matches crlf file")) {
        std::cerr << "crlf report=" << result.report << " body=";
        for (unsigned char ch : body) {
            if (ch == '\r') std::cerr << "<CR>";
            else if (ch == '\n') std::cerr << "<LF>";
            else std::cerr << ch;
        }
        std::cerr << std::endl;
        return 1;
    }

    std::cout << "local_edit_test ok" << std::endl;
    return 0;
}
