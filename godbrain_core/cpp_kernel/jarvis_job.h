#pragma once

#include <string>

// One offline fixture job. It does not call the mouth, Mongo, or the live kernel.
namespace jarvis_job {

struct Request {
    std::string work_dir;
    std::string file_name;
    std::string old_text;
    std::string new_text;
    std::string verifier_name;
    bool authorized = false;
    // Empty runs through verify. "proposed" or "applied" saves and returns.
    std::string stop_after;
};

struct Outcome {
    bool ok = false;
    std::string status;
    std::string id;
    std::string before_hash;
    std::string after_hash;
    int writes = 0;
    int verifier_exit = -1;
    std::string lesson_trust;
    std::string lesson;
};

Outcome run(const Request& request);
Outcome resume(const std::string& work_dir);
Outcome cancel(const std::string& work_dir);

}  // namespace jarvis_job
