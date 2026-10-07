#include "jarvis_job.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <fstream>
#include <iostream>
#include <string>

static bool expect(bool ok, const char* msg) {
    if (!ok) std::cerr << "FAIL " << msg << std::endl;
    return ok;
}

static bool write_text(const std::string& path, const std::string& body) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out.write(body.data(), static_cast<std::streamsize>(body.size()));
    return static_cast<bool>(out);
}

static std::string read_text(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::string body;
    char buf[256];
    while (in) {
        in.read(buf, sizeof(buf));
        body.append(buf, static_cast<size_t>(in.gcount()));
    }
    return body;
}

static std::string make_dir(const std::string& name) {
    char temp[MAX_PATH] = {};
    if (GetTempPathA(MAX_PATH, temp) == 0) return "";
    std::string dir = std::string(temp) + "GodBrain-jarvis-job-" + std::to_string(GetTickCount()) + "-" + name;
    if (!CreateDirectoryA(dir.c_str(), nullptr)) return "";
    return dir;
}

static bool plant(const std::string& dir, const std::string& verifier) {
    const std::string pass =
        "param([string]$Fixture)\r\n"
        "$t = [System.IO.File]::ReadAllText($Fixture)\r\n"
        "if ($t -cne 'alpha-after') { exit 4 }\r\n"
        "exit 0\r\n";
    const std::string fail = "param([string]$Fixture)\r\nexit 3\r\n";
    return write_text(dir + "\\fixture.txt", "alpha-before") &&
           write_text(dir + "\\check.ps1", verifier == "fail" ? fail : pass);
}

static jarvis_job::Request base_request(const std::string& dir) {
    jarvis_job::Request req;
    req.work_dir = dir;
    req.file_name = "fixture.txt";
    req.old_text = "alpha-before";
    req.new_text = "alpha-after";
    req.verifier_name = "check.ps1";
    req.authorized = true;
    return req;
}

int main() {
    bool pass = true;

    const std::string denied_dir = make_dir("denied");
    pass &= expect(!denied_dir.empty() && plant(denied_dir, "pass"), "denied dir");
    jarvis_job::Request denied = base_request(denied_dir);
    denied.authorized = false;
    const jarvis_job::Outcome deny = jarvis_job::run(denied);
    pass &= expect(!deny.ok && deny.status == "denied", "denied status");
    pass &= expect(deny.writes == 0, "denied writes");
    pass &= expect(deny.lesson_trust.empty(), "denied has no lesson");
    pass &= expect(read_text(denied_dir + "\\fixture.txt") == "alpha-before", "denied file");

    const std::string cancel_dir = make_dir("cancel");
    pass &= expect(!cancel_dir.empty() && plant(cancel_dir, "pass"), "cancel dir");
    jarvis_job::Request paused = base_request(cancel_dir);
    paused.stop_after = "proposed";
    const jarvis_job::Outcome proposed = jarvis_job::run(paused);
    pass &= expect(proposed.ok && proposed.status == "proposed", "proposed pause");
    pass &= expect(proposed.writes == 0, "proposed writes");
    pass &= expect(read_text(cancel_dir + "\\fixture.txt") == "alpha-before", "proposed file");
    const jarvis_job::Outcome cancelled = jarvis_job::cancel(cancel_dir);
    pass &= expect(!cancelled.ok && cancelled.status == "cancelled", "cancel status");
    const jarvis_job::Outcome cancel_resume = jarvis_job::resume(cancel_dir);
    pass &= expect(!cancel_resume.ok && cancel_resume.status == "cancelled", "cancel sticks");
    pass &= expect(cancel_resume.writes == 0, "cancel resume writes");
    pass &= expect(read_text(cancel_dir + "\\fixture.txt") == "alpha-before", "cancel file");

    const std::string job_dir = make_dir("pass");
    pass &= expect(!job_dir.empty() && plant(job_dir, "pass"), "pass dir");
    jarvis_job::Request job = base_request(job_dir);
    job.stop_after = "applied";
    const jarvis_job::Outcome applied = jarvis_job::run(job);
    pass &= expect(applied.ok && applied.status == "applied", "applied pause");
    pass &= expect(applied.writes == 1, "one apply");
    pass &= expect(applied.before_hash.size() == 64 && applied.after_hash.size() == 64, "hashes");
    pass &= expect(applied.before_hash != applied.after_hash, "hash changed");
    pass &= expect(read_text(job_dir + "\\fixture.txt") == "alpha-after", "patched file");
    const jarvis_job::Outcome verified = jarvis_job::resume(job_dir);
    pass &= expect(verified.ok && verified.status == "verified", "verified");
    pass &= expect(verified.writes == 1, "resume did not write again");
    pass &= expect(verified.verifier_exit == 0, "verifier exit");
    pass &= expect(verified.lesson_trust == "candidate", "lesson stays candidate");
    pass &= expect(verified.lesson.find(verified.before_hash) != std::string::npos &&
                       verified.lesson.find(verified.after_hash) != std::string::npos,
                   "lesson has both hashes");
    pass &= expect(read_text(job_dir + "\\fixture.txt") == "alpha-after", "verified file");
    const jarvis_job::Outcome again = jarvis_job::resume(job_dir);
    pass &= expect(again.ok && again.writes == 1 && again.status == "verified", "second resume");

    const std::string fail_dir = make_dir("fail");
    pass &= expect(!fail_dir.empty() && plant(fail_dir, "fail"), "fail dir");
    const jarvis_job::Outcome rolled = jarvis_job::run(base_request(fail_dir));
    pass &= expect(!rolled.ok && rolled.status == "rolled_back", "rolled back");
    pass &= expect(rolled.writes == 1, "failed patch wrote once");
    pass &= expect(rolled.verifier_exit == 3, "verifier failed");
    pass &= expect(rolled.lesson_trust == "candidate", "failure lesson is candidate");
    pass &= expect(read_text(fail_dir + "\\fixture.txt") == "alpha-before", "restored file");

    const std::string tamper_dir = make_dir("tamper");
    const std::string tamper =
        "param([string]$Fixture)\r\n"
        "[System.IO.File]::WriteAllText($Fixture, 'tampered')\r\n"
        "exit 0\r\n";
    pass &= expect(!tamper_dir.empty() && write_text(tamper_dir + "\\fixture.txt", "alpha-before") &&
                       write_text(tamper_dir + "\\check.ps1", tamper),
                   "tamper dir");
    const jarvis_job::Outcome tampered = jarvis_job::run(base_request(tamper_dir));
    pass &= expect(!tampered.ok && tampered.status == "rolled_back", "zero exit mismatch rolls back");
    pass &= expect(tampered.verifier_exit == 0, "tamper exit stays 0");
    pass &= expect(tampered.lesson_trust == "candidate", "tamper lesson");
    pass &= expect(read_text(tamper_dir + "\\fixture.txt") == "alpha-before", "tamper restored");

    const std::string drop_dir = make_dir("drop");
    const std::string drop =
        "param([string]$Fixture)\r\n"
        "Remove-Item -LiteralPath $Fixture -Force\r\n"
        "exit 0\r\n";
    pass &= expect(!drop_dir.empty() && write_text(drop_dir + "\\fixture.txt", "alpha-before") &&
                       write_text(drop_dir + "\\check.ps1", drop),
                   "drop dir");
    const jarvis_job::Outcome dropped = jarvis_job::run(base_request(drop_dir));
    pass &= expect(!dropped.ok && dropped.status == "rolled_back", "deleted fixture rolls back");
    pass &= expect(dropped.verifier_exit == 0, "delete exit stays 0");
    pass &= expect(read_text(drop_dir + "\\fixture.txt") == "alpha-before", "deleted fixture restored");

    const std::string abort_dir = make_dir("abort");
    pass &= expect(!abort_dir.empty() && plant(abort_dir, "pass"), "abort dir");
    jarvis_job::Request abort = base_request(abort_dir);
    abort.stop_after = "applied";
    const jarvis_job::Outcome abort_applied = jarvis_job::run(abort);
    pass &= expect(abort_applied.ok && abort_applied.status == "applied" && abort_applied.writes == 1,
                   "abort applied");
    const jarvis_job::Outcome abort_cancel = jarvis_job::cancel(abort_dir);
    pass &= expect(!abort_cancel.ok && abort_cancel.status == "cancelled", "cancel applied");
    pass &= expect(abort_cancel.writes == 1, "cancel does not count restore");
    pass &= expect(read_text(abort_dir + "\\fixture.txt") == "alpha-before", "cancel restored");
    const jarvis_job::Outcome abort_resume = jarvis_job::resume(abort_dir);
    pass &= expect(!abort_resume.ok && abort_resume.status == "cancelled" && abort_resume.writes == 1,
                   "cancelled stays cancelled");

    const std::string wide_dir = make_dir("wide");
    std::string big(200 * 1024, 'x');
    big.replace(0, 12, "alpha-before");
    pass &= expect(!wide_dir.empty() && write_text(wide_dir + "\\fixture.txt", big) &&
                       write_text(wide_dir + "\\check.ps1",
                                  "param([string]$Fixture)\r\nexit 4\r\n"),
                   "wide dir");
    jarvis_job::Request wide = base_request(wide_dir);
    wide.stop_after = "applied";
    const jarvis_job::Outcome wide_applied = jarvis_job::run(wide);
    pass &= expect(wide_applied.ok && wide_applied.status == "applied" && wide_applied.writes == 1,
                   "wide applied");
    pass &= expect(read_text(wide_dir + "\\jarvis-job.json").size() > 256 * 1024, "state past fixture cap");
    const jarvis_job::Outcome wide_resume = jarvis_job::resume(wide_dir);
    pass &= expect(!wide_resume.ok && wide_resume.status == "rolled_back", "wide resume loaded");
    pass &= expect(wide_resume.writes == 1 && wide_resume.before_hash.size() == 64, "wide receipt");
    pass &= expect(read_text(wide_dir + "\\fixture.txt") == big, "wide restored");

    if (!pass) return 1;
    std::cout << "jarvis_job_test ok" << std::endl;
    return 0;
}
