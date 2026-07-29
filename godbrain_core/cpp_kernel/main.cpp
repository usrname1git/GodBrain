#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <thread>
#include <algorithm>
#include "httplib.h"
#include "json.hpp"

#include "kernel.h"

using json = nlohmann::json;

GodBrainKernel kernel_hub; // Global kernel instance

std::string exec_cmd(const std::string& cmd) {
    char buffer[256];
    std::string result = "";
    FILE* pipe = _popen(cmd.c_str(), "r");
    if (!pipe) return "";
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        result += buffer;
    }
    _pclose(pipe);
    return result;
}

std::string run_colibri(const std::string& prompt) {
    SECURITY_ATTRIBUTES saAttr; 
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
    saAttr.bInheritHandle = TRUE; 
    saAttr.lpSecurityDescriptor = NULL; 

    HANDLE hOutRd = NULL, hOutWr = NULL;
    HANDLE hInRd = NULL, hInWr = NULL;

    CreatePipe(&hOutRd, &hOutWr, &saAttr, 0);
    SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
    
    CreatePipe(&hInRd, &hInWr, &saAttr, 0);
    SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si); 
    si.hStdError = hOutWr;
    si.hStdOutput = hOutWr;
    si.hStdInput = hInRd;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    std::string cmd = "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\LLM\\colibri_LLM\\c\\colibri.exe 64 8 8";
    
    SetEnvironmentVariableA("SNAP", "C:\\nvme\\glm52");
    SetEnvironmentVariableA("NGEN", "64");
    SetEnvironmentVariableA("COLI_RAM_OVERCOMMIT", "1");
    SetEnvironmentVariableA("COLI_CUDA", "1");
    SetEnvironmentVariableA("CUDA_EXPERT_GB", "12");
    SetEnvironmentVariableA("COLI_PROMPT", prompt.c_str());

    BOOL success = CreateProcessA(NULL, (LPSTR)cmd.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

    CloseHandle(hOutWr);
    CloseHandle(hInRd);

    if (!success) return "Error: Failed to spawn Colibri C-Engine natively.";

    // No need to write to stdin if we are passing prompt via env var
    CloseHandle(hInWr); // Sends EOF!

    std::string output = "";
    DWORD read; 
    CHAR buf[4096]; 
    while(ReadFile(hOutRd, buf, sizeof(buf), &read, NULL) && read > 0) {
        output.append(buf, read);
    }

    WaitForSingleObject(pi.hProcess, 180000); // 3 min timeout
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOutRd);

    return output;
}

int main() {
    std::cout << "[SYS] Booting GodBrain C++ Core Router..." << std::endl;
    httplib::Server svr;

    svr.Options(R"(.*)", [](const httplib::Request&, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
        res.set_header("Access-Control-Allow-Headers", "Content-Type");
    });

    auto set_cors = [](httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
    };

    svr.Get("/api/test", [&](const httplib::Request&, httplib::Response& res) {
        set_cors(res);
        res.set_content("C++ Core Operational!", "text/plain");
    });

    svr.Get("/", [&](const httplib::Request&, httplib::Response& res) {
        res.set_redirect("/galaxy");
    });

    svr.Get("/galaxy", [&](const httplib::Request&, httplib::Response& res) {
        std::ifstream file("../frontend/galaxy.html");
        if (file) {
            std::stringstream buffer;
            buffer << file.rdbuf();
            res.set_content(buffer.str(), "text/html");
        } else {
            res.status = 404;
            res.set_content("Galaxy UI not found.", "text/plain");
        }
    });

    svr.set_mount_point("/frontend", "../frontend");

    svr.Get("/api/graph", [&](const httplib::Request&, httplib::Response& res) {
        set_cors(res);
        std::string js = "JSON.stringify(db.nodes.find({}, {title:1, type:1, tags:1}).toArray())";
        std::string cmd = "mongosh godbrain --quiet --eval \"" + js + "\"";
        std::string out = exec_cmd(cmd);
        
        try {
            json db_nodes = json::parse(out);
            json result = json::object();
            json nodes_arr = json::array();
            
            for (auto& n : db_nodes) {
                std::string id = n["_id"].is_string() ? n["_id"].get<std::string>() : "unknown";
                if(n["_id"].is_object() && n["_id"].contains("$oid")) id = n["_id"]["$oid"].get<std::string>();
                std::string title = n.value("title", "Unknown");
                std::string type = n.value("type", "unknown");
                std::string group = "General";
                
                nodes_arr.push_back({
                    {"id", id}, {"label", title}, {"group", group}, {"type", type}, {"val", 1.5}
                });
            }
            result["nodes"] = nodes_arr;
            result["links"] = json::array();
            res.set_content(result.dump(), "application/json");
        } catch (...) {
            res.status = 500;
            res.set_content("{\"error\":\"DB fail\"}", "application/json");
        }
    });

    svr.Post("/api/chat", [&](const httplib::Request& req, httplib::Response& res) {
        set_cors(res);
        try {
            json payload = json::parse(req.body);
            std::string user_msg = payload.value("message", "");
            
            // Check if it's a kernel command directly
            if (payload.contains("command_type")) {
                std::string cmd_type = payload["command_type"];
                json k_res = kernel_hub.dispatch(cmd_type, payload);
                res.set_content(k_res.dump(), "application/json");
                return;
            }

            std::cout << "[RAG] User asked: " << user_msg << std::endl;
            
            std::string context_text = "Knowledge Graph Context:\n";
            std::string js = "JSON.stringify(db.nodes.find().limit(3).toArray())";
            std::string cmd = "mongosh godbrain --quiet --eval \"" + js + "\"";
            std::string out = exec_cmd(cmd);
            
            try {
                json docs = json::parse(out);
                int i = 1;
                for(auto& d : docs) {
                    std::string t = d.value("title", "");
                    std::string c = d.value("content", "");
                    if(c.length() > 500) c = c.substr(0, 500);
                    context_text += "\n--- Source " + std::to_string(i++) + ": " + t + " ---\n" + c + "...\n";
                }
            } catch(...) {}

            std::string system_prompt = "You are GodBrain, the Sovereign SRE Agent. You help the user optimize Windows 11 safely. If a tweak FATALLY_BREAKS something, WARN THE USER aggressively.";
            std::string full_prompt = system_prompt + "\n\n" + context_text + "\n\nUser Question: " + user_msg + "\nAnswer:";

            std::cout << "[RAG] Context built. Executing Colibri natively via C++ Win32 API..." << std::endl;
            
            std::string combined = run_colibri(full_prompt);
            
            std::string final_answer = combined;
            size_t ans_idx = combined.rfind("Answer:");
            size_t prof_idx = combined.rfind("PROFILO");
            size_t prof_en_idx = combined.rfind("PROFILE");
    
            if (ans_idx != std::string::npos) {
                final_answer = combined.substr(ans_idx + 7);
                // Strip out profiling data if present after Answer
                size_t end_idx = final_answer.find("PROFILE");
                if (end_idx == std::string::npos) end_idx = final_answer.find("PROFILO");
                if (end_idx != std::string::npos) {
                    final_answer = final_answer.substr(0, end_idx);
                }
            } else {
                // Find the last real text generated before PROFILE dumps
                size_t marker = prof_idx != std::string::npos ? prof_idx : prof_en_idx;
                if (marker != std::string::npos) {
                    // Find the last newline before the marker
                    size_t start = combined.rfind('\n', marker);
                    if (start != std::string::npos) {
                        // Now find the newline before that one to get the actual generated text line
                        size_t prev = combined.rfind('\n', start - 1);
                        if (prev != std::string::npos) {
                            final_answer = combined.substr(prev + 1, start - prev - 1);
                        } else {
                            final_answer = combined.substr(0, start);
                        }
                    }
                } else {
                    // Just grab the last few lines
                    if(final_answer.length() > 500) final_answer = final_answer.substr(final_answer.length() - 500);
                }
            }
    
            final_answer.erase(0, final_answer.find_first_not_of(" \n\r\t"));
            final_answer.erase(final_answer.find_last_not_of(" \n\r\t") + 1);
            
            json resp;
            resp["response"] = final_answer.empty() ? "No response." : final_answer;
            res.set_content(resp.dump(), "application/json");
        } catch (...) {
            res.status = 400;
            res.set_content("{\"response\":\"Parse error\"}", "application/json");
        }
    });

    std::cout << "[SYS] Listening on http://0.0.0.0:8083" << std::endl;
    svr.listen("0.0.0.0", 8083);
    return 0;
}
