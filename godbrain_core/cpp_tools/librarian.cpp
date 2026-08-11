#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <chrono>
#include <stdexcept>
#include <thread>
#include <algorithm>
#include <memory>
#include <optional>
#include <cmath>

// Include JSON support
#include "../cpp_kernel/json.hpp"
// Include Keccak256 for source hashing
#include "keccak256.hpp"

using json = nlohmann::json;

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
    std::string model_id = "Colibri-Llama-3-8B"; // Configured model, NOT model-reported
    std::string model_hash = "N/A";
    double llm_temperature = 0.1;
    bool dry_run = false;
};

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
                               prompt_config.value("authoring_standards", "") + "\n\n" + 
                               prompt_config.value("knowledge_skill_standards", "")},
                    {"user_transcript", envelope.content},
                    {"temperature", config.llm_temperature}
                };
                
                if (!last_error.empty()) {
                    llm_input["previous_validation_error"] = last_error;
                    llm_input["system"] = llm_input["system"].get<std::string>() + "\n\nWARNING: Your previous attempt failed validation. Please fix this error:\n" + last_error;
                }
                
                std::string full_prompt_json = llm_input.dump();
                
                return execute_llm_call(envelope, full_prompt_json, prompt_version, prompt_hash);
            } catch (const std::exception& e) {
                last_error = e.what();
                std::cerr << "[LIBRARIAN WARN] LLM Extraction attempt " << (attempt + 1) << " failed: " << last_error << std::endl;
                if (attempt == max_retries) throw;
                std::cout << "[LIBRARIAN] Retrying LLM extraction with error feedback..." << std::endl;
            }
        }
        throw std::runtime_error("LLM Extraction failed after retries.");
    }

private:
    DistillationResult execute_llm_call(const SourceEnvelope& envelope, const std::string& input_json, const std::string& prompt_version, const std::string& prompt_hash) {
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

        std::vector<char> cmdline(config.llm_executable_path.begin(), config.llm_executable_path.end());
        cmdline.push_back('\0');

        // Create Job Object to kill the ENTIRE process tree on timeout
        HANDLE hJob = CreateJobObjectA(NULL, NULL);
        if (hJob) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = { 0 };
            jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
        }

        // Enable legacy framed protocol
        SetEnvironmentVariableA("SERVE", "1");

        // CREATE_SUSPENDED ensures no rogue children are spawned before the job object is attached
        BOOL success = CreateProcessA(NULL, cmdline.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, NULL, &si, &pi);
        
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

        // Write full prompt to stdin
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

        // Read stdout and stderr
        std::string output = "";
        std::thread reader([&]() {
            DWORD read; 
            CHAR buf[4096]; 
            while(ReadFile(hOutRd, buf, sizeof(buf)-1, &read, NULL) && read > 0) {
                buf[read] = '\0';
                output.append(buf, read);
            }
        });

        // 4. Timeout constraint (Max 120s for LLM processing)
        DWORD waitRes = WaitForSingleObject(pi.hProcess, 120000);
        if (waitRes == WAIT_TIMEOUT) {
            if (hJob) CloseHandle(hJob); // Kills the entire process tree automatically
            else TerminateProcess(pi.hProcess, 1);
            
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(hOutRd);
            if (reader.joinable()) reader.join();
            throw std::runtime_error("LLM timed out after 120s.");
        }

        DWORD exitCode;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        if (hJob) CloseHandle(hJob); // Clean up job object
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        CloseHandle(hOutRd);
        
        if (reader.joinable()) reader.join();

        if (exitCode != 0) {
            throw std::runtime_error("LLM failed with exit code " + std::to_string(exitCode) + ". Output: " + output);
        }

        // Colibri's legacy protocol returns \x01\x01END\x01\x01, STAT lines, READY lines, etc.
        // Find the first { and last } to extract the JSON.
        size_t json_start = output.find('{');
        size_t json_end = output.rfind('}');
        if (json_start != std::string::npos && json_end != std::string::npos && json_end >= json_start) {
            output = output.substr(json_start, json_end - json_start + 1);
        }

        // 5. Strict JSON Schema Extraction
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
                Claim claim;
                claim.claim_id = c.value("claim_id", "");
                claim.type = c.value("type", "");
                claim.content = c.value("content", "");
                claim.confidence = c.value("confidence", 0.0);
                if (c.contains("evidence_spans") && c["evidence_spans"].is_array()) {
                    for (const auto& s : c["evidence_spans"]) {
                        claim.evidence_spans.push_back(s.get<std::string>());
                    }
                }
                alexandria_payload.claims.push_back(claim);
            }
        }
        
        if (extracted_json.contains("core_concepts") && extracted_json["core_concepts"].is_array()) {
            for (const auto& concept : extracted_json["core_concepts"]) {
                alexandria_payload.core_concepts.push_back(concept.get<std::string>());
            }
        }
        
        if (extracted_json.contains("opsec_candidates") && extracted_json["opsec_candidates"].is_array()) {
            for (const auto& candidate : extracted_json["opsec_candidates"]) {
                alexandria_payload.opsec_candidates.push_back(candidate.get<std::string>());
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

        std::string full_extractor_version = "LLM-Native-1.0 (Prompt: " + prompt_version + ")";
        
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

        std::vector<char> cmdline(go_executable_path.begin(), go_executable_path.end());
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

        DWORD waitRes = WaitForSingleObject(pi.hProcess, 35000); // Wait slightly longer than Go's 30s context
        if (waitRes == WAIT_TIMEOUT) {
            TerminateProcess(pi.hProcess, 1);
            if (reader.joinable()) reader.join();
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(hOutRd);
            throw std::runtime_error("Go memory-store timed out.");
        }
        
        if (reader.joinable()) {
            reader.join();
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
        // Colibri requires prompt template JSON and the executable path
        distiller = std::make_unique<LLMDistillationProvider>(config);
    }
    std::unique_ptr<SchemaValidator> validator = std::make_unique<StrictSchemaValidator>();

    try {
        // 2. Distillation
        DistillationResult result = distiller->distill(envelope);
        
        // Ensure trust_tier is always candidate from the provider
        result.payload.trust_tier = "candidate";
        
        // Ensure Provenance is correct
        result.payload.provenance = Provenance{
            envelope.source_id,
            envelope.source_type,
            envelope.source_hash,
            envelope.language
        };

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
        LibrarianConfig test_config{"", "", "", "Colibri-Llama-3-8B", "N/A", 0.1, true};
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
    
    LibrarianConfig config{
        env_llm ? std::string(env_llm) : "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\godbrain_core\\colibri\\colibri.exe",
        env_prompt ? std::string(env_prompt) : "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\godbrain_core\\cpp_tools\\prompts\\hermes_v1.json",
        env_mongo ? std::string(env_mongo) : "C:\\Users\\autismo\\Documents\\GitHub\\GodBrain\\godbrain_core\\memory_store\\memory-store.exe",
        "Colibri-Llama-3-8B",
        "N/A",
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