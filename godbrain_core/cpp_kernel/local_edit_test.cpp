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
        const std::string gpu_hint = local_edit::edit_user_with_excerpt(
            "/edit godbrain_core/frontend/galaxy.html after GPU: none "
            "add a Judge line");
        const size_t gpu_ex = gpu_hint.find("excerpt:");
        const size_t in_ex = primed.find("excerpt:");
        const size_t gpu_at_gpu = gpu_hint.find("GPU: none", gpu_ex);
        const size_t gpu_at_inbox = primed.find("GPU: none", in_ex);
        if (!expect(gpu_ex != std::string::npos && in_ex != std::string::npos,
                    "both excerpts marked") ||
            !expect(gpu_at_gpu != std::string::npos,
                    "GPU hint excerpt contains GPU: none") ||
            !expect(gpu_at_inbox != std::string::npos,
                    "Inbox hint excerpt still reaches GPU") ||
            !expect((gpu_at_gpu - gpu_ex) < (gpu_at_inbox - in_ex),
                    "GPU hint windows closer to GPU than Inbox hint")) {
            std::cerr << "gpu_ex=" << gpu_ex << " in_ex=" << in_ex
                      << " gpu_at_gpu=" << gpu_at_gpu
                      << " gpu_at_inbox=" << gpu_at_inbox << std::endl;
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

    result = local_edit::maybe_apply(
        "/edit godbrain_core/frontend/galaxy.html after Inbox: none add GPU",
        "*** APPLY\n"
        "path: godbrain_core/frontend/galaxy.html\n"
        "<<<<\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        "====\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        ">>>>\n"
        "*** END\n",
        {});
    if (!expect(result.attempted, "overlay hunk attempted") ||
        !expect(!result.applied, "overlay hunk not in host-card excerpt") ||
        !expect(result.report.find("not in excerpt") != std::string::npos,
                "overlay skip says not in excerpt")) {
        std::cerr << "overlay report=" << result.report << std::endl;
        return 1;
    }

    result = local_edit::maybe_apply(
        "/edit godbrain_core/frontend/galaxy.html after Inbox: none add GPU",
        "*** APPLY\n"
        "path: godbrain_core/frontend/galaxy.html\n"
        "<<<<\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        "====\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        ">>>>\n"
        "*** END\n",
        [&](const std::string&, const std::string&) { return std::string(); });
    if (!expect(!result.applied, "empty second after miss") ||
        !expect(result.report.find("not in excerpt") != std::string::npos,
                "keeps first skip") ||
        !expect(result.report.find("Second pass had no apply blocks") !=
                    std::string::npos,
                "names empty second pass") ||
        !expect(result.report.find("excerptSecond") == std::string::npos,
                "does not glue skip to Second")) {
        std::cerr << "glue report=" << result.report << std::endl;
        return 1;
    }

    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    bool retried = false;
    result = local_edit::maybe_apply(
        "/edit godbrain_core/frontend/galaxy.html after Inbox: none add GPU",
        "*** APPLY\n"
        "path: godbrain_core/frontend/galaxy.html\n"
        "<<<<\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        "====\n"
        "            const inboxLine = inboxOverlayLine(status);\n"
        "            if (inboxLine) lines.push(inboxLine);\n"
        "            const cs2 = (status && status.cs2) || {};\n"
        ">>>>\n"
        "*** END\n",
        [&](const std::string&, const std::string&) {
            retried = true;
            return "*** APPLY\n"
                   "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
                   "<<<<\n"
                   "EDIT_FIXTURE=old\n"
                   "====\n"
                   "EDIT_FIXTURE=after-miss\n"
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
    if (!expect(retried, "missed first hunk retries second pass") ||
        !expect(result.applied, "second pass after miss wrote") ||
        !expect(body == "EDIT_FIXTURE=after-miss\n",
                "fixture from retry")) {
        std::cerr << "retry report=" << result.report << " body=" << body
                  << std::endl;
        return 1;
    }

    {
        std::string second_excerpt_user;
        result = local_edit::maybe_apply(
            "/edit godbrain_core/frontend/galaxy.html after Inbox: none add GPU",
            "*** APPLY\n"
            "path: godbrain_core/frontend/galaxy.html\n"
            "<<<<\n"
            "            const inboxLine = inboxOverlayLine(status);\n"
            "            if (inboxLine) lines.push(inboxLine);\n",
            [&](const std::string&, const std::string& usr) {
                second_excerpt_user = usr;
                return std::string();
            });
        const size_t ex = second_excerpt_user.find("excerpt:");
        if (!expect(ex != std::string::npos, "second pass has excerpt") ||
            !expect(second_excerpt_user.find("Inbox: none", ex) !=
                        std::string::npos,
                    "second pass excerpt stays on host-card") ||
            !expect(second_excerpt_user.find(
                        "if (inboxLine) lines.push(inboxLine)") ==
                        std::string::npos,
                    "truncated overlay plan is not fed to second pass")) {
            std::cerr << "second excerpt usr size=" << second_excerpt_user.size()
                      << std::endl;
            return 1;
        }
    }

    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    result = local_edit::maybe_apply(
        "/edit godbrain_core/cpp_kernel/local_edit_fixture.txt flip marker",
        "*** APPLY\n"
        "path: godbrain_core/cpp_kernel/local_edit_fixture.txt\n"
        "<<<<\n"
        "EDIT_FIXTURE=old\n"
        "====\n"
        "EDIT_FIXTURE=hashed\n"
        ">>>>\n"
        "*** END\n",
        {});
    {
        std::ofstream out(fixture, std::ios::binary | std::ios::trunc);
        out << "EDIT_FIXTURE=old\n";
    }
    if (!expect(result.applied, "hash apply wrote") ||
        !expect(result.before_hash.size() == 64, "before hash keccak") ||
        !expect(result.after_hash.size() == 64, "after hash keccak") ||
        !expect(result.before_hash != result.after_hash, "hash moved") ||
        !expect(result.preview_path.find("local_edit_fixture") != std::string::npos,
                "preview path") ||
        !expect(!result.rolled_back, "txt apply is not rolled")) {
        std::cerr << "hash report=" << result.report
                  << " before=" << result.before_hash.size()
                  << " after=" << result.after_hash.size() << std::endl;
        return 1;
    }

    {
        char exe2[MAX_PATH] = {};
        GetModuleFileNameA(NULL, exe2, MAX_PATH);
        std::string dir2(exe2);
        const size_t slash2 = dir2.find_last_of("\\/");
        if (slash2 != std::string::npos) dir2.resize(slash2);
        dir2 += "\\..\\..\\scripts\\local_edit_rb.ps1";
        char canon[MAX_PATH] = {};
        GetFullPathNameA(dir2.c_str(), MAX_PATH, canon, nullptr);
        const std::string ps1(canon);
        {
            std::ofstream out(ps1, std::ios::binary | std::ios::trunc);
            out << "Write-Output 1\n";
        }
        result = local_edit::maybe_apply(
            "/edit scripts/local_edit_rb.ps1 break parse",
            "*** APPLY\n"
            "path: scripts/local_edit_rb.ps1\n"
            "<<<<\n"
            "Write-Output 1\n"
            "====\n"
            "function (\n"
            ">>>>\n"
            "*** END\n",
            {});
        std::string ps1_body;
        {
            std::ifstream in(ps1, std::ios::binary);
            ps1_body.assign((std::istreambuf_iterator<char>(in)),
                            std::istreambuf_iterator<char>());
        }
        DeleteFileA(ps1.c_str());
        if (!expect(result.rolled_back, "bad ps1 rolled back") ||
            !expect(!result.applied, "bad ps1 not left applied") ||
            !expect(ps1_body == "Write-Output 1\n", "ps1 restored") ||
            !expect(result.report.find("rolled back") != std::string::npos,
                    "report says rolled back")) {
            std::cerr << "rollback report=" << result.report
                      << " body=" << ps1_body << std::endl;
            return 1;
        }
    }

    std::cout << "local_edit_test ok" << std::endl;
    return 0;
}
