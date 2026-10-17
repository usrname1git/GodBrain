#pragma once

#include "research_curation.h"
#include <iphlpapi.h>
#include <optional>
#include <vector>
#include <windows.h>

#pragma comment(lib, "iphlpapi.lib")

namespace godbrain_research_mouth {
using json = nlohmann::json;

inline void require_idle(httplib::Client& client) {
    const auto health = client.Get("/health?fail_on_no_slot=1");
    if (!health || health->status != 200)
        throw std::runtime_error("local research mouth is not healthy");
    const auto status = godbrain_research::strict_json(health->body, 16 * 1024);
    if (!status.is_object() || (!status.contains("ok") && !status.contains("status")) ||
        (status.contains("ok") && status.at("ok") != true) ||
        (status.contains("status") && status.at("status") != "ok" &&
         status.at("status") != "ready") ||
        (status.contains("busy") && (!status.at("busy").is_boolean() || status.at("busy") == true)))
        throw std::runtime_error("local research mouth is busy or unreadable");
}

inline std::string model_identity(httplib::Client& client) {
    const auto response = client.Get("/v1/models");
    if (!response || response->status != 200)
        throw std::runtime_error("local research model identity is unavailable");
    const auto models = godbrain_research::strict_json(response->body, 16 * 1024);
    if (!models.is_object() || !models.contains("data") || !models.at("data").is_array() ||
        models.at("data").size() != 1 ||
        !godbrain_rag::valid_string(models.at("data").at(0).at("id"), 512, true))
        throw std::runtime_error("local research model identity is ambiguous");
    return models.at("data").at(0).at("id").get<std::string>();
}

inline std::string process_identity(int port) {
    DWORD size = 0;
    if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) !=
        ERROR_INSUFFICIENT_BUFFER)
        throw std::runtime_error("cannot size local mouth owner table");
    std::vector<unsigned char> bytes;
    DWORD code = ERROR_INSUFFICIENT_BUFFER;
    for (int attempt = 0; attempt < 3 && code == ERROR_INSUFFICIENT_BUFFER; ++attempt) {
        bytes.resize(size);
        code = GetExtendedTcpTable(bytes.data(), &size, FALSE, AF_INET,
                                   TCP_TABLE_OWNER_PID_LISTENER, 0);
    }
    if (code != NO_ERROR) throw std::runtime_error("cannot read local mouth owner table");
    const auto* table = reinterpret_cast<const MIB_TCPTABLE_OWNER_PID*>(bytes.data());
    DWORD pid = 0;
    for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const auto& row = table->table[i];
        if (ntohs(static_cast<u_short>(row.dwLocalPort)) != port) continue;
        if (row.dwLocalAddr != htonl(INADDR_LOOPBACK) && row.dwLocalAddr != INADDR_ANY) continue;
        if (pid != 0 && pid != row.dwOwningPid)
            throw std::runtime_error("ambiguous local mouth owner");
        pid = row.dwOwningPid;
    }
    if (pid == 0) throw std::runtime_error("local mouth has no listener");
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) throw std::runtime_error("cannot inspect local mouth process");
    FILETIME created{}, exited{}, kernel{}, user{};
    const bool ok = GetProcessTimes(process, &created, &exited, &kernel, &user) != FALSE;
    CloseHandle(process);
    if (!ok) throw std::runtime_error("cannot read local mouth instance identity");
    return std::to_string(pid) + ":" + std::to_string(created.dwHighDateTime) + ":" +
           std::to_string(created.dwLowDateTime);
}

struct Runner {
    int port = 0;
    std::string model;
    std::string instance;

    std::string identity() const { return std::to_string(port) + ":" + instance + ":" + model; }

    std::string infer(json body) const {
        if (process_identity(port) != instance)
            throw std::runtime_error("local mouth instance changed");
        httplib::Client client("127.0.0.1", port);
        client.set_connection_timeout(2, 0);
        client.set_read_timeout(3, 0);
        client.set_write_timeout(5, 0);
        require_idle(client);
        if (model_identity(client) != model)
            throw std::runtime_error("local curation model changed before inference");
        body["model"] = model;
        client.set_read_timeout(45, 0);
        const auto response = client.Post("/v1/chat/completions", body.dump(), "application/json");
        client.set_read_timeout(3, 0);
        if (!response || response->status != 200)
            throw std::runtime_error("local curation inference unavailable");
        const auto result = godbrain_research::strict_json(response->body, 64 * 1024);
        if (!result.is_object() || !result.contains("choices") ||
            !result.at("choices").is_array() || result.at("choices").size() != 1)
            throw std::runtime_error("invalid local curation completion");
        const auto& choice = result.at("choices").at(0);
        const auto& message = choice.at("message");
        if (choice.at("finish_reason") != "stop" ||
            !godbrain_rag::valid_string(message.at("content"), 8192, true) ||
            (message.contains("tool_calls") && !message.at("tool_calls").is_null() &&
             message.at("tool_calls") != json::array()))
            throw std::runtime_error("local curation did not produce a complete tool-free answer");
        if (process_identity(port) != instance || model_identity(client) != model)
            throw std::runtime_error("local mouth restarted during inference");
        return message.at("content").get<std::string>();
    }
};

inline Runner connect(int port) {
    if (port != 8000 && port != 8888)
        throw std::runtime_error("research mouth must use an existing local model port");
    Runner runner{port, "", process_identity(port)};
    httplib::Client client("127.0.0.1", port);
    client.set_connection_timeout(2, 0);
    client.set_read_timeout(3, 0);
    require_idle(client);
    runner.model = model_identity(client);
    if (process_identity(port) != runner.instance)
        throw std::runtime_error("local research mouth changed during probing");
    return runner;
}
} // namespace godbrain_research_mouth
