#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>

#include "../cpp_kernel/json.hpp"
using json = nlohmann::json;

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

json fetch_recent_cves() {
    std::cout << "[*] Scanning global networks for latest Zero-Days & CVEs...\n";
    
    std::string cmd = "curl -s -A \"GodBrain-OSINT/1.0\" https://cve.circl.lu/api/last";
    std::string out = exec_cmd(cmd);
    
    try {
        json data = json::parse(out);
        // Return top 10
        if (data.is_array() && data.size() > 10) {
            json top10 = json::array();
            for (int i = 0; i < 10; ++i) top10.push_back(data[i]);
            return top10;
        }
        return data;
    } catch (...) {
        std::cout << "[-] JSON Parse Error from CVE DB.\n";
    }
    return json::array();
}

void analyze_and_ingest(const json& cve_data) {
    std::string cve_id = cve_data.value("id", "UNKNOWN_CVE");
    std::string summary = cve_data.value("summary", "");
    std::string cvss;
    if (cve_data.contains("cvss") && !cve_data["cvss"].is_null()) {
        if (cve_data["cvss"].is_number()) {
            cvss = std::to_string(cve_data["cvss"].get<double>());
        } else {
            cvss = cve_data["cvss"].get<std::string>();
        }
    } else {
        cvss = "N/A";
    }

    std::cout << "[*] Analyzing Threat: " << cve_id << " (CVSS: " << cvss << ")\n";

    // Stubbing the LLM invocation here, similar to Python script
    // In production, pipes full_prompt into Colibri engine logic.
    
    // Simulate LLM analyzing and returning JSON
    json mock_llm_result = {
        {"decision", "ACCEPT"},
        {"threat_level", "HIGH"},
        {"affected_component", "Windows Kernel"},
        {"mitigation_strategy", "Apply latest cumulative update. Temporarily disable vulnerable service."},
        {"entities", json::array({
            {{"name", cve_id}, {"label", "Vulnerability"}}
        })}
    };

    if (mock_llm_result["decision"] == "ACCEPT") {
        std::cout << "[!] THREAT SECURED: " << cve_id << " is " << mock_llm_result["threat_level"].get<std::string>() << ". Committing to Memory.\n";
        
        // Simulating writing to Neo4j/MongoDB via GodBrainEngine pipe
        // self.engine.save_thought(...)
    } else {
        std::cout << "[-] Discarding low-value noise: " << cve_id << "\n";
    }
}

int main(int argc, char* argv[]) {
    std::cout << "[+] Autonomous CVE Ingestor Online (C++ Native).\n";
    json cves = fetch_recent_cves();
    
    if (cves.empty()) {
        std::cout << "[-] No CVEs retrieved. Network offline or API rate limited.\n";
        return 1;
    }

    for (const auto& cve : cves) {
        analyze_and_ingest(cve);
    }

    return 0;
}