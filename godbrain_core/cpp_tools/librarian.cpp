#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <chrono>
#include <stdexcept>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include <memory>
#include <optional>
#include <cmath>
#include <cstring>
#include <sstream>

// Include JSON support
#include "../cpp_kernel/json.hpp"
#include "../cpp_kernel/httplib.h"
// Include Keccak256 for source hashing
#include "keccak256.hpp"

using json = nlohmann::json;

static std::string get_exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

static std::vector<char> child_environment_with(const std::string& name, const std::string& value) {
    LPCH raw_environment = GetEnvironmentStringsA();
    if (!raw_environment) {
        throw std::runtime_error("Failed to read process environment");
    }

    std::vector<std::string> entries;
    for (LPCH current = raw_environment; *current; current += std::strlen(current) + 1) {
        std::string entry(current);
        size_t separator = entry.find('=', entry.front() == '=' ? 1 : 0);
        if (separator != std::string::npos &&
            _stricmp(entry.substr(0, separator).c_str(), name.c_str()) == 0) {
            continue;
        }
        entries.push_back(std::move(entry));
    }
    FreeEnvironmentStringsA(raw_environment);

    entries.push_back(name + "=" + value);
    std::sort(entries.begin(), entries.end(), [](const std::string& left, const std::string& right) {
        return _stricmp(left.c_str(), right.c_str()) < 0;
    });

    std::vector<char> block;
    for (const auto& entry : entries) {
        block.insert(block.end(), entry.begin(), entry.end());
        block.push_back('\0');
    }
    block.push_back('\0');
    return block;
}

std::string get_iso_timestamp() {
    auto now = std::chrono::system_clock::now();
    std::time_t now_c = std::chrono::system_clock::to_time_t(now);
    struct tm parts;
    gmtime_s(&parts, &now_c);
    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &parts);
    return std::string(buf);
}

struct LibrarianConfig {
    std::string llm_executable_path;
    std::string prompt_template_path;
    std::string mongo_store_path;
    std::string model_id = "mouth";
    std::string model_hash = "N/A";
    std::string mouth_host = "127.0.0.1";
    int mouth_port = 8000;
    double llm_temperature = 0.1;
    bool dry_run = false;
};

static std::string env_or(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return (value && *value) ? std::string(value) : fallback;
}

static bool spawn_colibri_allowed() {
    const std::string v = env_or("GODBRAIN_LIBRARIAN_SPAWN", "");
    return v == "1" || _stricmp(v.c_str(), "true") == 0;
}

static std::string load_mouth_model_id() {
    const std::string override = env_or("GODBRAIN_LIBRARIAN_MODEL", "");
    if (!override.empty()) return override;
    const std::string path = get_exe_dir() + "\\..\\..\\logs\\mouth.txt";
    std::ifstream in(path, std::ios::binary);
    if (!in) return "mouth";
    std::string line;
    std::getline(in, line);
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n' ||
                             line.back() == ' ')) {
        line.pop_back();
    }
    if (line.empty()) return "mouth";
    const auto space = line.find(' ');
    return space == std::string::npos ? line : line.substr(space + 1);
}

static bool mouth_http_up(const std::string& host, int port) {
    httplib::Client client(host, port);
    client.set_connection_timeout(0, 300000);
    client.set_read_timeout(2, 0);
    if (const auto probe = client.Get("/health")) {
        return probe->status == 200;
    }
    return false;
}

static std::string extract_json_object(const std::string& text) {
    const size_t json_start = text.find('{');
    const size_t json_end = text.rfind('}');
    if (json_start == std::string::npos || json_end == std::string::npos ||
        json_end < json_start) {
        throw std::runtime_error("LLM output had no JSON object");
    }
    return text.substr(json_start, json_end - json_start + 1);
}

static std::string chat_complete(
    const std::string& host,
    int port,
    const std::string& model,
    const std::string& system,
    const std::string& user,
    double temperature) {
    httplib::Client client(host, port);
    client.set_connection_timeout(2, 0);
    client.set_read_timeout(180, 0);
    client.set_write_timeout(10, 0);
    json body = {
        {"model", model},
        {"stream", false},
        {"temperature", temperature},
        {"max_tokens", 768},
        {"chat_template_kwargs", json{{"enable_thinking", false}}},
        {"messages",
         json::array(
             {json{{"role", "system"}, {"content", system}},
              json{{"role", "user"}, {"content", user}}})},
    };
    const auto response =
        client.Post("/v1/chat/completions", body.dump(), "application/json");
    if (!response) {
        throw std::runtime_error("mouth HTTP did not finish on " + host + ":" +
                                 std::to_string(port));
    }
    if (response->status != 200) {
        throw std::runtime_error("mouth HTTP " + std::to_string(response->status) +
                                 ": " + response->body.substr(0, 240));
    }
    const json parsed = json::parse(response->body);
    const auto& choice = parsed.at("choices").at(0);
    const json msg = choice.value("message", json::object());
    std::string content = msg.value("content", "");
    const std::string think = msg.value("reasoning_content", "");
    if (content.find('{') == std::string::npos && think.find('{') != std::string::npos) {
        content = think;
    }
    if (content.empty()) {
        content = think;
    }
    if (content.empty()) {
        throw std::runtime_error("mouth returned empty content");
    }
    return content;
}

// --- DOMAIN MODELS ---

struct SourceEnvelope {
    std::string source_id;
    std::string content;
    std::string source_type;
    std::string source_hash;
    std::string language;

    SourceEnvelope(std::string id, std::string text, std::string type, std::string lang = "mixed")
        : source_id(std::move(id)), content(std::move(text)), source_type(std::move(type)), language(std::move(lang)) {
        source_hash = keccak256(content);
    }
};

struct Provenance {
    std::string source_id;
    std::string source_type;
    std::string source_hash;
    std::string language;
    std::string prompt_hash;
    std::string model_id;
    std::string model_hash;
    double llm_temperature;
    
    json to_json() const {
        return {
            {"source_id", source_id}, 
            {"source_type", source_type}, 
            {"source_hash", source_hash}, 
            {"language", language},
            {"prompt_hash", prompt_hash},
            {"model_id", model_id},
            {"model_hash", model_hash},
            {"llm_temperature", llm_temperature}
        };
    }
};

struct Claim {
    std::string claim_id;
    std::string type;
    std::string content;
    double confidence;
    std::vector<std::string> evidence_spans;

    json to_json() const {
        return {{"claim_id", claim_id}, {"type", type}, {"content", content}, {"confidence", confidence}, {"evidence_spans", evidence_spans}};
    }
};

struct AlexandriaPayload {
    std::string trust_tier;
    Provenance provenance;
    std::vector<Claim> claims;
    std::vector<std::string> core_concepts;
    std::vector<std::string> opsec_candidates;

    json to_json() const {
        json claims_arr = json::array();
        for (const auto& c : claims) claims_arr.push_back(c.to_json());
        
        return {
            {"trust_tier", trust_tier},
            {"provenance", provenance.to_json()},
            {"claims", claims_arr},
            {"core_concepts", core_concepts},
            {"opsec_candidates", opsec_candidates}
        };
    }
};

struct DistillationResult {
    std::string extractor_version;
    std::string schema_version;
    bool degraded; // True if fallback was used
    AlexandriaPayload payload;
};

struct StoreReceipt {
    std::string record_id;
    std::string version;
    bool created_new;
    std::string timestamp;
};

// --- INTERFACES ---

class DistillationProvider {
public:
    virtual DistillationResult distill(const SourceEnvelope& envelope) = 0;
    virtual ~DistillationProvider() = default;
};

class SchemaValidator {
public:
    virtual void validate(const DistillationResult& result) const = 0;
    virtual ~SchemaValidator() = default;
};

class MemoryStore {
public:
    virtual StoreReceipt upsert(const SourceEnvelope& envelope, const DistillationResult& result) = 0;
    virtual ~MemoryStore() = default;
};

// --- IMPLEMENTATIONS ---

class FallbackDistillationProvider : public DistillationProvider {
public:
    DistillationResult distill(const SourceEnvelope& envelope) override {
        std::cout << "[LIBRARIAN] Executing fallback input-dependent distillation (DEGRADED MODE)..." << std::endl;
        
        std::vector<std::string> concepts;
        if (envelope.content.find("C++") != std::string::npos) concepts.push_back("C++ Integration");
        if (envelope.content.find("Hermes") != std::string::npos) concepts.push_back("Hermes Skill Model");
        if (concepts.empty()) concepts.push_back("General Discussion");

        std::string summary = envelope.content.substr(0, std::min<size_t>(envelope.content.length(), 200));

        Claim fallback_claim{
            "claim_fallback_001",
            "factual",
            summary,
            0.5,
            {"[0:200]"}
        };

        Provenance prov{envelope.source_id, envelope.source_type, envelope.source_hash, envelope.language, "N/A", "Fallback", "N/A", 0.0};
        
        AlexandriaPayload payload{
            "raw_candidate",
            prov,
            {fallback_claim},
            concepts,
            {} // opsec_candidates
        };

        return DistillationResult{
            "Librarian-CPP-Fallback-1.2",
            "1.0",
            true, // degraded = true
            std::move(payload)
        };
    }
};

class LLMDistillationProvider : public DistillationProvider {
private:
    LibrarianConfig config;

public:
    LLMDistillationProvider(LibrarianConfig cfg) : config(std::move(cfg)) {}

    DistillationResult distill(const SourceEnvelope& envelope) override {
        std::cout << "[LIBRARIAN] Executing LLM distillation (Provider: LLM-Native-1.0)..." << std::endl;
        
        // 1. Load Versioned Prompt Template
        std::ifstream prompt_file(config.prompt_template_path);
        if (!prompt_file.is_open()) {
            throw std::runtime_error("Failed to open prompt template file: " + config.prompt_template_path);
        }
        std::string prompt_file_content((std::istreambuf_iterator<char>(prompt_file)), std::istreambuf_iterator<char>());
        std::string prompt_hash = keccak256(prompt_file_content);
        
        json prompt_config = json::parse(prompt_file_content);
        std::string prompt_version = prompt_config.value("prompt_version", "unknown");

        int max_retries = 1;
        std::string last_error = "";
        
        for (int attempt = 0; attempt <= max_retries; ++attempt) {
            try {
                // 2. Build the exact prompt structure using JSON escaping (no string concat for user data!)
                json llm_input = {
                    {"system", prompt_config.value("system_prompt", "") + "\n\n" +
                               prompt_config.value("source_hygiene", "") + "\n\n" +
                               prompt_config.value("research_protocol", "") + "\n\n" +
                               prompt_config.value("authoring_standards", "") + "\n\n" +
                               prompt_config.value("knowledge_skill_standards", "")},
                    {"user_transcript", envelope.content},
                    {"temperature", config.llm_temperature}
                };
                
                if (!last_error.empty()) {
                    llm_input["previous_validation_error"] = last_error;
                    llm_input["system"] = llm_input["system"].get<std::string>() + "\n\nWARNING: Your previous attempt failed validation. Please fix this error:\n" + last_error;
                }
                
                // Mouth path: short extract prompt. The full Hermes skill
                // bible is ~2k tokens and IMA'd Gemma 12B Q4 on this 4080.
                const std::string system =
                    "You are Librarian-CPP. Extract at most 6 specific claims "
                    "from the transcript. Output one JSON object only. "
                    "schema_version 1.0, extractor Librarian-CPP, "
                    "trust_tier raw_candidate, provenance "
                    "{source_type session_transcript, language mixed}, "
                    "claims[{claim_id, type factual|architecture|"
                    "contradiction|open_question, content, confidence, "
                    "evidence_spans}], core_concepts[], opsec_candidates[], "
                    "skills_extracted[]. Empty arrays if none. "
                    "Close every brace. No markdown. No thinking.";
                const std::string user =
                    std::string("Transcript (raw, immutable). First character "
                                "must be '{'.\n\n") +
                    envelope.content;
                return execute_llm_call(
                    envelope, system, user, llm_input.dump(), prompt_version,
                    prompt_hash);
            } catch (const std::exception& e) {
                last_error = e.what();
                std::cerr << "[LIBRARIAN WARN] LLM Extraction attempt " << (attempt + 1) << " failed: " << last_error << std::endl;
                const bool mouth_dead =
                    last_error.find("did not finish") != std::string::npos ||
                    last_error.find("mouth is down") != std::string::npos;
                if (mouth_dead || attempt == max_retries) throw;
                std::cout << "[LIBRARIAN] Retrying LLM extraction with error feedback..." << std::endl;
            }
        }
        throw std::runtime_error("LLM Extraction failed after retries.");
    }

private:
    DistillationResult execute_llm_call(
        const SourceEnvelope& envelope,
        const std::string& system,
        const std::string& user,
        const std::string& framed_json,
        const std::string& prompt_version,
        const std::string& prompt_hash) {
        std::string output;
        if (mouth_http_up(config.mouth_host, config.mouth_port)) {
            std::cout << "[LIBRARIAN] Distilling via mouth HTTP "
                      << config.mouth_host << ":" << config.mouth_port
                      << " model=" << config.model_id << std::endl;
            output = chat_complete(
                config.mouth_host, config.mouth_port, config.model_id, system,
                user, config.llm_temperature);
        } else if (!spawn_colibri_allowed()) {
            throw std::runtime_error(
                "mouth is down on " + config.mouth_host + ":" +
                std::to_string(config.mouth_port) +
                ". Will not cold-spawn Colibri. Start llama-server or coli serve.");
        } else {
            output = execute_colibri_spawn(framed_json);
        }
        return parse_distillation(envelope, output, prompt_version, prompt_hash);
    }

    std::string execute_colibri_spawn(const std::string& input_json) {
        SECURITY_ATTRIBUTES saAttr; 
        saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
        saAttr.bInheritHandle = TRUE; 
        saAttr.lpSecurityDescriptor = NULL; 

        HANDLE hOutRd = NULL, hOutWr = NULL;
        HANDLE hInRd = NULL, hInWr = NULL;

        if (!CreatePipe(&hOutRd, &hOutWr, &saAttr, 0)) throw std::runtime_error("Failed to create stdout pipe");
        SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
        
        if (!CreatePipe(&hInRd, &hInWr, &saAttr, 0)) {
            CloseHandle(hOutRd); CloseHandle(hOutWr);
            throw std::runtime_error("Failed to create stdin pipe");
        }
        SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOA si;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si); 
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE); // Keep stderr separate to avoid JSON corruption
        si.hStdOutput = hOutWr;
        si.hStdInput = hInRd;
        si.dwFlags |= STARTF_USESTDHANDLES;

        PROCESS_INFORMATION pi;
        ZeroMemory(&pi, sizeof(pi));

        // Create Job Object to kill the ENTIRE process tree on timeout
        HANDLE hJob = CreateJobObjectA(NULL, NULL);
        if (hJob) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = { 0 };
            jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
        }

        // Enable the legacy framed protocol only for the Colibri child.
        std::vector<char> child_environment = child_environment_with("SERVE", "1");

        // CREATE_SUSPENDED ensures no rogue children are spawned before the job object is attached
        std::string cmdline_str = "\"" + config.llm_executable_path + "\"";
        std::vector<char> cmdline(cmdline_str.begin(), cmdline_str.end());
        cmdline.push_back('\0');

        BOOL success = CreateProcessA(NULL, cmdline.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, child_environment.data(), NULL, &si, &pi);
        
        if (!success) {
            CloseHandle(hInWr); CloseHandle(hOutRd); CloseHandle(hOutWr); CloseHandle(hInRd);
            if (hJob) CloseHandle(hJob);
            throw std::runtime_error("Failed to start LLM executable");
        }

        if (hJob) {
            if (!AssignProcessToJobObject(hJob, pi.hProcess)) {
                TerminateProcess(pi.hProcess, 1);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                CloseHandle(hInWr); CloseHandle(hOutRd); CloseHandle(hOutWr); CloseHandle(hInRd);
                CloseHandle(hJob);
                throw std::runtime_error("Failed to assign LLM process to Job Object");
            }
        }
        
        ResumeThread(pi.hThread);
        
        CloseHandle(hOutWr);
        CloseHandle(hInRd);

        // Use Colibri Legacy Framed Protocol: \x02PROMPT <bytes> <max_tokens> <temperature> <top_p>\n<prompt>\n
        std::stringstream req;
        req << "\x02PROMPT " << input_json.length() << " 4096 " << config.llm_temperature << " 0.9 0\n" << input_json << "\n";
        std::string framed_payload = req.str();

        // Read stdout and stderr in a separate thread BEFORE writing to prevent pipe deadlock
        std::string output = "";
        std::mutex output_mutex;
        std::condition_variable ready_cv;
        bool is_ready = false;
        
        std::thread reader([&]() {
            DWORD read; 
            CHAR buf[4096]; 
            while(ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
                buf[read] = '\0';
                {
                    std::lock_guard<std::mutex> lock(output_mutex);
                    output.append(buf, read);
                    if (!is_ready && output.find("READY") != std::string::npos) {
                        is_ready = true;
                        ready_cv.notify_one();
                    }
                }
            }
        });

        // Wait for READY
        {
            std::unique_lock<std::mutex> lock(output_mutex);
            if (!ready_cv.wait_for(lock, std::chrono::seconds(30), [&]{ return is_ready; })) {
                lock.unlock(); // Prevent deadlock with reader thread
                if (hJob) CloseHandle(hJob); else TerminateProcess(pi.hProcess, 1);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                if (reader.joinable()) reader.join();
                CloseHandle(hOutRd); CloseHandle(hInWr);
                throw std::runtime_error("LLM timed out waiting for READY.");
            }
        }

        // Write full prompt to stdin in a separate thread to prevent deadlocking if process hangs on boot
        std::thread writer([&]() {
            DWORD totalWritten = 0;
            DWORD toWrite = framed_payload.length();
            const char* ptr = framed_payload.c_str();
            while (totalWritten < toWrite) {
                DWORD written = 0;
                if (!WriteFile(hInWr, ptr + totalWritten, toWrite - totalWritten, &written, NULL)) {
                    break;
                }
                totalWritten += written;
            }
            CloseHandle(hInWr);
        });

        // 4. Timeout constraint (Max 120s for LLM processing)
        DWORD waitRes = WaitForSingleObject(pi.hProcess, 120000);
        if (waitRes == WAIT_TIMEOUT) {
            if (hJob) CloseHandle(hJob); // Kills the entire process tree automatically
            else TerminateProcess(pi.hProcess, 1);
            
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
            
            if (reader.joinable()) reader.join(); // Join before closing hOutRd
            CloseHandle(hOutRd);
            
            if (writer.joinable()) {
                CancelSynchronousIo(writer.native_handle()); // Abort WriteFile if stuck
                writer.join();
            }
            
            throw std::runtime_error("LLM timed out after 120s.");
        }

        DWORD exitCode;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        if (hJob) CloseHandle(hJob); // Clean up job object
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        
        if (reader.joinable()) reader.join(); // Join before closing hOutRd
        CloseHandle(hOutRd);
        
        if (writer.joinable()) writer.join();

        if (exitCode != 0) {
            throw std::runtime_error("LLM failed with exit code " + std::to_string(exitCode) + ". Output: " + output);
        }
        return output;
    }

    static std::string json_as_string(const json& value) {
        if (value.is_string()) return value.get<std::string>();
        if (value.is_number() || value.is_boolean()) return value.dump();
        if (value.is_null()) return "";
        return value.dump();
    }

    DistillationResult parse_distillation(
        const SourceEnvelope& envelope,
        std::string output,
        const std::string& prompt_version,
        const std::string& prompt_hash) {
        output = extract_json_object(output);

        json extracted_json;
        try {
            extracted_json = json::parse(output);
        } catch (const std::exception& e) {
            throw std::runtime_error("Failed to parse LLM JSON: " + std::string(e.what()) + "\nOutput: " + output);
        }

        AlexandriaPayload alexandria_payload;
        alexandria_payload.trust_tier = "raw_candidate";
        
        if (extracted_json.contains("claims") && extracted_json["claims"].is_array()) {
            for (const auto& c : extracted_json["claims"]) {
                if (!c.is_object()) continue;
                Claim claim;
                claim.claim_id = c.contains("claim_id") ? json_as_string(c["claim_id"]) : "";
                claim.type = c.contains("type") ? json_as_string(c["type"]) : "";
                claim.content = c.contains("content") ? json_as_string(c["content"]) : "";
                if (c.contains("confidence") && c["confidence"].is_number()) {
                    claim.confidence = c["confidence"].get<double>();
                } else {
                    claim.confidence = 0.0;
                }
                if (c.contains("evidence_spans") && c["evidence_spans"].is_array()) {
                    for (const auto& s : c["evidence_spans"]) {
                        const std::string span = json_as_string(s);
                        if (!span.empty()) claim.evidence_spans.push_back(span);
                    }
                }
                alexandria_payload.claims.push_back(claim);
            }
        }
        
        if (extracted_json.contains("core_concepts") && extracted_json["core_concepts"].is_array()) {
            for (const auto& concept : extracted_json["core_concepts"]) {
                const std::string s = json_as_string(concept);
                if (!s.empty()) alexandria_payload.core_concepts.push_back(s);
            }
        }
        
        if (extracted_json.contains("opsec_candidates") && extracted_json["opsec_candidates"].is_array()) {
            for (const auto& candidate : extracted_json["opsec_candidates"]) {
                const std::string s = json_as_string(candidate);
                if (!s.empty()) alexandria_payload.opsec_candidates.push_back(s);
            }
        }
        
        // Attach provenance
        alexandria_payload.provenance = Provenance{
            envelope.source_id,
            envelope.source_type,
            envelope.source_hash,
            envelope.language,
            prompt_hash,
            config.model_id,
            config.model_hash,
            config.llm_temperature
        };

        std::string full_extractor_version =
            "Librarian-CPP-1.0 (Prompt: " + prompt_version + ")";
        
        return DistillationResult{
            full_extractor_version,
            "1.0",
            false, // Not degraded
            std::move(alexandria_payload)
        };
    }
};

class StrictSchemaValidator : public SchemaValidator {
public:
    void validate(const DistillationResult& result) const override {
        if (result.payload.claims.empty()) {
            std::cout << "[LIBRARIAN WARN] Payload has no claims." << std::endl;
        }
        for (const auto& claim : result.payload.claims) {
            if (claim.content.empty()) {
                throw std::runtime_error("Schema validation failed: Claim content is empty.");
            }
            if (!std::isfinite(claim.confidence) || claim.confidence < 0.0 || claim.confidence > 1.0) {
                throw std::runtime_error("Schema validation failed: Claim confidence out of bounds or NaN.");
            }
            // TODO: Proper UTF-8 validation and cross-checking evidence_spans against chunk lengths
        }
        std::cout << "[LIBRARIAN] Schema validation passed." << std::endl;
    }
};

class InMemoryMemoryStore : public MemoryStore {
public:
    StoreReceipt upsert(const SourceEnvelope& envelope, const DistillationResult& result) override {
        std::cout << "[LIBRARIAN] InMemory Store (Self-Test) - Mocking successful upsert for: " 
                  << envelope.source_hash << std::endl;
        
        return StoreReceipt{
            "mem_obj_" + envelope.source_hash.substr(0, 8),
            "v1",
            true,
            get_iso_timestamp()
        };
    }
};

class GoSubprocessMemoryStore : public MemoryStore {
private:
    std::string go_executable_path;
public:
    GoSubprocessMemoryStore(const std::string& path) : go_executable_path(path) {}

    StoreReceipt upsert(const SourceEnvelope& envelope, const DistillationResult& result) override {
        std::cout << "[LIBRARIAN] Sending payload to Go Memory Store..." << std::endl;
        
        SECURITY_ATTRIBUTES saAttr; 
        saAttr.nLength = sizeof(SECURITY_ATTRIBUTES); 
        saAttr.bInheritHandle = TRUE; 
        saAttr.lpSecurityDescriptor = NULL; 

        HANDLE hOutRd = NULL, hOutWr = NULL;
        HANDLE hInRd = NULL, hInWr = NULL;

        if (!CreatePipe(&hOutRd, &hOutWr, &saAttr, 0)) throw std::runtime_error("Failed to create stdout pipe");
        SetHandleInformation(hOutRd, HANDLE_FLAG_INHERIT, 0);
        
        if (!CreatePipe(&hInRd, &hInWr, &saAttr, 0)) {
            CloseHandle(hOutRd); CloseHandle(hOutWr);
            throw std::runtime_error("Failed to create stdin pipe");
        }
        SetHandleInformation(hInWr, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOA si;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si); 
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE); // Let Go write stderr to our stderr
        si.hStdOutput = hOutWr;
        si.hStdInput = hInRd;
        si.dwFlags |= STARTF_USESTDHANDLES;

        PROCESS_INFORMATION pi;
        ZeroMemory(&pi, sizeof(pi));

        std::string go_cmdline_str = "\"" + go_executable_path + "\"";
        std::vector<char> cmdline(go_cmdline_str.begin(), go_cmdline_str.end());
        cmdline.push_back('\0');

        BOOL success = CreateProcessA(NULL, cmdline.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);

        CloseHandle(hOutWr);
        CloseHandle(hInRd);

        if (!success) {
            CloseHandle(hInWr); CloseHandle(hOutRd);
            throw std::runtime_error("Failed to start Go memory-store executable");
        }

        // Build DistillationPayload JSON matching Go's expected input
        json full_payload = {
            {"extractor_id", "Librarian-CPP"},
            {"extractor_version", result.extractor_version},
            {"schema_version", result.schema_version},
            {"degraded", result.degraded},
            {"payload", result.payload.to_json()},
            {"raw_transcript", envelope.content}
        };

        std::string payload_str = full_payload.dump();
        
        std::string output = "";
        
        std::thread reader([&]() {
            DWORD read; 
            CHAR buf[4096]; 
            while(ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
                buf[read] = '\0';
                output.append(buf, read);
            }
        });

        std::thread writer([&]() {
            DWORD totalWritten = 0;
            DWORD toWrite = payload_str.length();
            const char* ptr = payload_str.c_str();
            while (totalWritten < toWrite) {
                DWORD written = 0;
                if (!WriteFile(hInWr, ptr + totalWritten, toWrite - totalWritten, &written, NULL)) {
                    std::cerr << "[LIBRARIAN ERR] Failed to write to Go process pipe." << std::endl;
                    break;
                }
                totalWritten += written;
            }
            CloseHandle(hInWr); // Send EOF to Go
        });

        DWORD waitRes = WaitForSingleObject(pi.hProcess, 35000); // Wait slightly longer than Go's 30s context
        if (waitRes == WAIT_TIMEOUT) {
            TerminateProcess(pi.hProcess, 1);
            if (reader.joinable()) reader.join();
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(hOutRd);
            if (writer.joinable()) {
                CancelSynchronousIo(writer.native_handle());
                writer.join();
            }
            throw std::runtime_error("Go memory-store timed out.");
        }
        
        if (reader.joinable()) {
            reader.join();
        }
        if (writer.joinable()) {
            writer.join();
        }
        
        DWORD exitCode;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        CloseHandle(hOutRd);

        if (exitCode != 0) {
            // It failed. Output might contain ErrorEnvelope.
            throw std::runtime_error("Go memory-store failed with exit code " + std::to_string(exitCode) + ". Output: " + output);
        }

        // Parse Receipt
        try {
            json receipt_json = json::parse(output);
            return StoreReceipt{
                receipt_json.value("record_id", ""),
                receipt_json.value("version", ""),
                false, // not tracking created_new directly here for now
                receipt_json.value("timestamp", "")
            };
        } catch (const std::exception& e) {
            throw std::runtime_error("Failed to parse StoreReceipt from Go output: " + std::string(e.what()) + "\nOutput was: " + output);
        }
    }
};

bool commit_to_brain(const std::string& session_id, const std::string& raw_transcript, std::unique_ptr<MemoryStore> store, const LibrarianConfig& config) {
    std::cout << "[LIBRARIAN] Archiving session " << session_id << "..." << std::endl;
    
    // 1. Source Envelope
    SourceEnvelope envelope(session_id, raw_transcript, "session_transcript");
    std::cout << "[LIBRARIAN] Source SHA-3 (Keccak256): " << envelope.source_hash << std::endl;

    // Instantiate pipeline
    std::unique_ptr<DistillationProvider> distiller;
    if (config.dry_run) {
        distiller = std::make_unique<FallbackDistillationProvider>(); // Use fallback during testing/dry-run
    } else {
        distiller = std::make_unique<LLMDistillationProvider>(config);
    }
    std::unique_ptr<SchemaValidator> validator = std::make_unique<StrictSchemaValidator>();

    try {
        // 2. Distillation
        DistillationResult result = distiller->distill(envelope);
        
        // Ensure trust_tier is always candidate from the provider
        result.payload.trust_tier = "candidate";
        
        // Ensure Provenance is correct but don't overwrite audit fields if set by provider
        result.payload.provenance.source_id = envelope.source_id;
        result.payload.provenance.source_type = envelope.source_type;
        result.payload.provenance.source_hash = envelope.source_hash;
        result.payload.provenance.language = envelope.language;

        // 3. Schema Validation
        validator->validate(result);
        
        // 4. Policy / Redaction (TODO)

        // 5. MemoryStore Upsert
        StoreReceipt receipt = store->upsert(envelope, result);
        
        std::cout << "[LIBRARIAN] Successfully committed to brain. Receipt ID: " << receipt.record_id << std::endl;
        return true;

    } catch (const std::exception& e) {
        std::cerr << "[LIBRARIAN ERR] Pipeline failed: " << e.what() << std::endl;
        return false;
    }
}

void test_keccak256() {
    std::string hash_empty = keccak256("");
    // Official Ethereum Keccak-256 hash for empty string is c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    if (hash_empty != "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470") {
        throw std::runtime_error("Keccak256 validation failed! Expected c5d24601... for empty string, got " + hash_empty);
    }
    
    std::string hash_abc = keccak256("abc");
    if (hash_abc != "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45") {
        throw std::runtime_error("Keccak256 validation failed! Expected 4e03657a... for 'abc', got " + hash_abc);
    }
}

int main(int argc, char* argv[]) {
    // 9. Verify Keccak-256
    try {
        test_keccak256();
    } catch (const std::exception& e) {
        std::cerr << "[LIBRARIAN ERR] " << e.what() << std::endl;
        return 1;
    }
    if (argc >= 2 && std::string(argv[1]) == "--self-test") {
        LibrarianConfig test_config{
            "", "", "", "mouth", "N/A", "127.0.0.1", 8000, 0.1, true};
        bool success = commit_to_brain("session_test_alexandria", "User: We need a C++ Librarian with provenance. AI: Executing native protocol.", std::make_unique<InMemoryMemoryStore>(), test_config);
        return success ? 0 : 1;
    }
    
    int arg_idx = 1;
    bool dry_run = false;
    if (argc >= 2 && std::string(argv[1]) == "--dry-run") {
        dry_run = true;
        arg_idx++;
    }

    if (argc < arg_idx + 2) {
        std::cerr << "Usage: librarian.exe [--dry-run] <session_id> <transcript_text_or_file>" << std::endl;
        std::cerr << "       librarian.exe --self-test" << std::endl;
        return 1;
    }

    std::string session_id = argv[arg_idx];
    std::string input = argv[arg_idx + 1];
    
    // Read config path from environment or default
    const char* env_llm = std::getenv("LLM_RUNNER_PATH");
    const char* env_prompt = std::getenv("PROMPT_TEMPLATE_PATH");
    const char* env_mongo = std::getenv("MONGO_STORE_PATH");
    
    std::string exe_dir = get_exe_dir();
    
    int mouth_port = 8000;
    try {
        mouth_port = std::stoi(env_or("GODBRAIN_MOUTH_PORT", "8000"));
    } catch (...) {
        mouth_port = 8000;
    }
    LibrarianConfig config{
        env_llm ? std::string(env_llm) : exe_dir + "\\..\\..\\LLM\\colibri_LLM\\c\\colibri.exe",
        env_prompt ? std::string(env_prompt) : exe_dir + "\\prompts\\hermes_v1.json",
        env_mongo ? std::string(env_mongo) : exe_dir + "\\..\\memory_store\\memory-store.exe",
        load_mouth_model_id(),
        "N/A",
        env_or("GODBRAIN_MOUTH_HOST", "127.0.0.1"),
        mouth_port,
        0.1,
        dry_run
    };
    
    // Check if input is a file and read it, with 10MB limit
    std::string transcript;
    DWORD fileAttr = GetFileAttributesA(input.c_str());
    if (fileAttr != INVALID_FILE_ATTRIBUTES && !(fileAttr & FILE_ATTRIBUTE_DIRECTORY)) {
        std::ifstream file(input, std::ios::binary | std::ios::ate);
        if (file) {
            std::streamsize size = file.tellg();
            if (size > 10 * 1024 * 1024) {
                std::cerr << "[LIBRARIAN ERR] File too large (max 10MB)." << std::endl;
                return 1;
            }
            file.seekg(0, std::ios::beg);
            transcript.resize(size);
            if (file.read(&transcript[0], size)) {
                std::cout << "[LIBRARIAN] Loaded transcript from file: " << input << " (" << size << " bytes)" << std::endl;
            } else {
                transcript = input; // fallback if read fails somehow
            }
        } else {
            transcript = input; // fallback to string
        }
    } else {
        transcript = input;
    }

    std::unique_ptr<MemoryStore> store;
    if (config.dry_run) {
        store = std::make_unique<InMemoryMemoryStore>();
    } else {
        store = std::make_unique<GoSubprocessMemoryStore>(config.mongo_store_path);
    }

    bool success = commit_to_brain(session_id, transcript, std::move(store), config);
    return success ? 0 : 1;
}