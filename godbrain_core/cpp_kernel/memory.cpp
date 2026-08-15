#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "memory.h"
#include "rag_client.h"
#include "telemetry.h"
#include "../cpp_tools/keccak256.hpp"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace memory {
namespace {

constexpr size_t kMaxThoughtBytes = 32 * 1024;
constexpr size_t kMaxSessionThoughts = 8;
constexpr DWORD kStoreTimeoutMs = 35000;

struct SessionThought {
    std::string source_hash;
    std::string stable_id;
    std::string content;
    std::string status;
};

std::mutex g_session_mutex;
std::vector<SessionThought> g_session_thoughts;

std::string collapse_fields(std::string value, bool lower) {
    std::string out;
    bool in_token = false;
    for (unsigned char character : value) {
        if (std::isspace(character) != 0) {
            in_token = false;
            continue;
        }
        if (!out.empty() && !in_token) out.push_back(' ');
        out.push_back(static_cast<char>(
            lower ? std::tolower(character) : character));
        in_token = true;
    }
    return out;
}

std::string claim_stable_id(const std::string& type, const std::string& content) {
    return keccak256(
        std::string("claim") + '\0' + collapse_fields(type, true) + '\0' +
        collapse_fields(content, false));
}

void remember_session(
    const std::string& source_hash,
    const std::string& stable_id,
    const std::string& content) {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    g_session_thoughts.erase(
        std::remove_if(
            g_session_thoughts.begin(),
            g_session_thoughts.end(),
            [&](const SessionThought& thought) {
                return thought.source_hash == source_hash ||
                       thought.stable_id == stable_id;
            }),
        g_session_thoughts.end());
    g_session_thoughts.push_back({source_hash, stable_id, content, "candidate"});
    if (g_session_thoughts.size() > kMaxSessionThoughts) {
        g_session_thoughts.erase(
            g_session_thoughts.begin(),
            g_session_thoughts.begin() +
                static_cast<std::ptrdiff_t>(
                    g_session_thoughts.size() - kMaxSessionThoughts));
    }
}

std::vector<SessionThought> copy_session(int limit) {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    if (limit <= 0 || static_cast<size_t>(limit) >= g_session_thoughts.size()) {
        return g_session_thoughts;
    }
    return std::vector<SessionThought>(
        g_session_thoughts.end() - limit, g_session_thoughts.end());
}

std::string read_env(const char* name) {
    char* value = nullptr;
    size_t length = 0;
    if (_dupenv_s(&value, &length, name) != 0 || value == nullptr) return "";
    std::string result(value);
    std::free(value);
    return result;
}

std::string exe_dir() {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(nullptr, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH) return "";
    std::string full(path, len);
    const size_t pos = full.find_last_of("\\/");
    return pos == std::string::npos ? "" : full.substr(0, pos);
}

bool file_exists(const std::string& path) {
    const DWORD attrs = GetFileAttributesA(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES &&
           (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::string resolve_memory_store() {
    const std::string override_path = read_env("MONGO_STORE_PATH");
    if (!override_path.empty()) return override_path;
    const std::string dir = exe_dir();
    const std::string candidates[] = {
        dir + "\\memory-store.exe",
        dir + "\\..\\memory_store\\memory-store.exe",
        dir + "\\..\\..\\godbrain_core\\memory_store\\memory-store.exe",
    };
    for (const auto& candidate : candidates) {
        if (file_exists(candidate)) return candidate;
    }
    return dir + "\\..\\memory_store\\memory-store.exe";
}

std::string trim_copy(std::string value) {
    const auto not_space = [](unsigned char character) {
        return std::isspace(character) == 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
    return value;
}

bool looks_like_secret(const std::string& text) {
    return text.find("otpauth://") != std::string::npos ||
           text.find("otpauth-migration://") != std::string::npos ||
           (text.find("BEGIN ") != std::string::npos &&
            text.find("PRIVATE KEY") != std::string::npos);
}

json run_memory_store(const json& payload) {
    const std::string exe = resolve_memory_store();
    if (!file_exists(exe)) {
        throw std::runtime_error(
            "memory-store.exe not found; set MONGO_STORE_PATH");
    }

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;

    HANDLE out_read = nullptr;
    HANDLE out_write = nullptr;
    HANDLE in_read = nullptr;
    HANDLE in_write = nullptr;
    if (!CreatePipe(&out_read, &out_write, &attributes, 0)) {
        throw std::runtime_error("failed to create memory-store stdout pipe");
    }
    SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
    if (!CreatePipe(&in_read, &in_write, &attributes, 0)) {
        CloseHandle(out_read);
        CloseHandle(out_write);
        throw std::runtime_error("failed to create memory-store stdin pipe");
    }
    SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    startup.hStdOutput = out_write;
    startup.hStdInput = in_read;
    startup.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION process{};
    std::string command = "\"" + exe + "\"";
    std::vector<char> cmdline(command.begin(), command.end());
    cmdline.push_back('\0');
    const BOOL started = CreateProcessA(
        nullptr,
        cmdline.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr,
        nullptr,
        &startup,
        &process);
    CloseHandle(out_write);
    CloseHandle(in_read);
    if (started == 0) {
        CloseHandle(in_write);
        CloseHandle(out_read);
        throw std::runtime_error("failed to start memory-store.exe");
    }

    const std::string body = payload.dump();
    std::string output;
    std::thread reader([&]() {
        char buffer[4096];
        DWORD read = 0;
        while (ReadFile(out_read, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
            output.append(buffer, read);
        }
    });
    std::thread writer([&]() {
        DWORD written_total = 0;
        while (written_total < body.size()) {
            DWORD written = 0;
            if (!WriteFile(
                    in_write,
                    body.data() + written_total,
                    static_cast<DWORD>(body.size() - written_total),
                    &written,
                    nullptr)) {
                break;
            }
            written_total += written;
        }
        CloseHandle(in_write);
    });

    const DWORD wait = WaitForSingleObject(process.hProcess, kStoreTimeoutMs);
    if (wait == WAIT_TIMEOUT) {
        TerminateProcess(process.hProcess, 1);
        if (reader.joinable()) reader.join();
        if (writer.joinable()) writer.join();
        CloseHandle(process.hProcess);
        CloseHandle(process.hThread);
        CloseHandle(out_read);
        throw std::runtime_error("memory-store.exe timed out");
    }
    if (reader.joinable()) reader.join();
    if (writer.joinable()) writer.join();

    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    CloseHandle(out_read);
    if (exit_code != 0) {
        throw std::runtime_error(
            "memory-store.exe failed: " + output);
    }
    try {
        return json::parse(output);
    } catch (const json::exception&) {
        throw std::runtime_error("memory-store.exe returned malformed JSON");
    }
}

}  // namespace

json save_thought(const json& payload) {
    const std::string content = trim_copy(payload.value("content", ""));
    if (content.empty() || content.size() > kMaxThoughtBytes ||
        content.find('\0') != std::string::npos) {
        throw std::runtime_error("thought content is empty, oversized, or invalid");
    }
    if (looks_like_secret(content)) {
        throw std::runtime_error("thought looks like a secret and was rejected");
    }

    const std::string source_hash = keccak256(content);
    const std::string sector = trim_copy(payload.value("sector", "operator"));
    const std::string claim_type = sector.empty() ? "operator" : sector;
    json document = {
        {"extractor_id", "Kernel-Thought-CPP"},
        {"extractor_version", "1.0.0"},
        {"schema_version", "1.0"},
        {"degraded", false},
        {"raw_transcript", content},
        {"payload",
         {{"trust_tier", "candidate"},
          {"provenance",
           {{"source_id", "thought:" + source_hash.substr(0, 16)},
            {"source_type", "operator_thought"},
            {"source_hash", source_hash},
            {"language", "mixed"},
            {"prompt_hash", "N/A"},
            {"model_id", "operator"},
            {"model_hash", "N/A"},
            {"llm_temperature", 0.0}}},
          {"claims",
           json::array(
               {json{
                   {"claim_id", "claim:" + source_hash.substr(0, 16)},
                   {"type", claim_type},
                   {"content", content},
                   {"confidence", 1.0},
                   {"evidence_spans",
                    json::array({"[0:" + std::to_string(content.size()) + "]"})}}})},
          {"core_concepts", json::array()},
          {"opsec_candidates", json::array()}}},
    };

    std::cout << "[MEMORY] Committing operator thought via memory-store ("
              << content.size() << " bytes)" << std::endl;
    const json receipt = run_memory_store(document);
    const std::string status = receipt.value("status", "");
    if (status != "committed" && status != "idempotent_noop") {
        throw std::runtime_error(
            "memory-store rejected thought: " + receipt.dump());
    }
    const std::string stable_id = claim_stable_id(claim_type, content);
    remember_session(source_hash, stable_id, content);
    return {
        {"status", "success"},
        {"run_id", receipt.value("run_id", "")},
        {"record_id", receipt.value("record_id", "")},
        {"store_status", status},
        {"source_hash", source_hash},
        {"stable_id", stable_id},
    };
}

json observe_host() {
    const json inventory = telemetry::get_host_inventory();
    const json live = telemetry::get_current_state();
    std::ostringstream body;
    body << "Windows host inventory\n"
         << "computer_name="
         << inventory.at("computer_name").get<std::string>() << '\n'
         << "total_physical_ram_gb="
         << inventory.at("total_physical_ram_gb").get<int>() << '\n'
         << "logical_processors="
         << inventory.at("logical_processors").get<int>() << '\n';
    const json volumes = inventory.value("volumes", json::array());
    for (const auto& volume : volumes) {
        body << "volume=" << volume.value("letter", "?")
             << " type=" << volume.value("type", "fixed")
             << " label=" << volume.value("label", "")
             << " total_gb=" << volume.value("total_gb", 0) << '\n';
    }
    json stored = save_thought({
        {"content", body.str()},
        {"sector", "windows-sre"},
    });
    stored["inventory"] = inventory;
    stored["live"] = live;
    return stored;
}

json set_status(const json& payload) {
    const std::string id = trim_copy(payload.value("id", ""));
    const std::string status = trim_copy(payload.value("status", ""));
    const std::string reasoning = trim_copy(payload.value("reasoning", ""));
    if (id.empty() || (status != "verified" && status != "rejected")) {
        throw std::runtime_error("status judgment requires id and verified|rejected");
    }
    if (reasoning.size() < 4) {
        throw std::runtime_error(
            "say why this is verified (it works) or rejected (junk)");
    }
    const json document = {
        {"command", "set_status"},
        {"id", id},
        {"status", status},
        {"reasoning", reasoning},
    };
    const json receipt = run_memory_store(document);
    {
        std::lock_guard<std::mutex> lock(g_session_mutex);
        if (status == "rejected") {
            g_session_thoughts.erase(
                std::remove_if(
                    g_session_thoughts.begin(),
                    g_session_thoughts.end(),
                    [&](const SessionThought& thought) {
                        return thought.source_hash == id ||
                               thought.stable_id == id;
                    }),
                g_session_thoughts.end());
        } else {
            for (auto& thought : g_session_thoughts) {
                if (thought.source_hash == id || thought.stable_id == id) {
                    thought.status = "verified";
                }
            }
        }
    }
    return receipt;
}

json get_recent(int limit) {
    if (limit <= 0) limit = 5;
    if (limit > 25) limit = 25;
    json graph;
    std::string error;
    if (!godbrain_rag::Client{}.graph(limit, graph, error)) {
        throw std::runtime_error(error);
    }
    json thoughts = json::array();
    for (const auto& node : graph.at("nodes")) {
        thoughts.push_back({
            {"id", node.at("node_id")},
            {"label", node.at("label")},
            {"kind", node.at("kind")},
            {"sector", node.at("sector")},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}};
}

json session_snapshot(int limit) {
    if (limit <= 0) limit = 8;
    if (limit > 25) limit = 25;
    json thoughts = json::array();
    for (const auto& thought : copy_session(limit)) {
        thoughts.push_back({
            {"id", thought.stable_id},
            {"source_hash", thought.source_hash},
            {"label", thought.content},
            {"kind", "claim"},
            {"sector", "operator"},
            {"status", thought.status},
            {"session", true},
        });
    }
    return {{"status", "success"}, {"thoughts", thoughts}};
}

bool render_session_context(std::string& context, std::string& error) {
    const auto thoughts = copy_session(static_cast<int>(kMaxSessionThoughts));
    if (thoughts.empty()) {
        context.clear();
        return true;
    }
    std::ostringstream output;
    output << godbrain_rag::kUntrustedBegin << '\n';
    godbrain_rag::append_line(output, "NOTICE", godbrain_rag::kRouterNotice);
    godbrain_rag::append_line(
        output,
        "session_notice",
        "Operator-remembered notes from this kernel process. Untrusted reference data.");
    for (size_t index = 0; index < thoughts.size(); ++index) {
        const std::string prefix = "session[" + std::to_string(index + 1) + "].";
        godbrain_rag::append_line(
            output, prefix + "source_hash", thoughts[index].source_hash);
        godbrain_rag::append_line(
            output, prefix + "stable_id", thoughts[index].stable_id);
        godbrain_rag::append_line(
            output, prefix + "status", thoughts[index].status);
        godbrain_rag::append_line(
            output, prefix + "content", thoughts[index].content);
    }
    output << godbrain_rag::kUntrustedEnd << '\n';
    if (output.fail()) {
        error = "session memory contains invalid UTF-8";
        context.clear();
        return false;
    }
    context = output.str();
    if (context.size() > godbrain_rag::kMaxRenderedContextBytes) {
        error = "session memory exceeds the deterministic budget";
        context.clear();
        return false;
    }
    return true;
}
}