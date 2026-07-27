import os
import subprocess
import json
import requests
import sys

sys.stdout.reconfigure(encoding='utf-8')

print("======================================================")
print("[GodBrain] LOCAL SRE EXECUTOR INITIALIZED")
print("======================================================")

def run_ps(command):
    try:
        result = subprocess.run(["powershell", "-NoProfile", "-Command", command], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error running {command}: {e}")
        return ""

def scan_services():
    print("[*] Scanning local Windows Services...")
    # Get all running services with StartType Auto or Manual
    ps_cmd = "Get-Service | Where-Object {$_.Status -eq 'Running'} | Select-Object Name, DisplayName, Status | ConvertTo-Json"
    out = run_ps(ps_cmd)
    if out:
        try:
            return json.loads(out)
        except:
            pass
    return []

def query_godbrain(query_text):
    print(f"[*] Querying GodBrain Graph via Colibri: '{query_text}'")
    try:
        data = json.dumps({"message": query_text}).encode("utf-8")
        req = requests.post("http://127.0.0.1:8081/api/chat", data=data, headers={"Content-Type": "application/json"})
        response = req.json()
        return response.get("response", "")
    except Exception as e:
        return f"Failed to reach GodBrain API: {e}"

def generate_report(services):
    print("\n[+] Generating SRE Optimization Analysis...")
    report = "### GodBrain SRE Active Scan ###\n"
    report += f"Found {len(services)} running services.\n\n"
    
    # Just sample a few telemetry/bloat targets to query the GodBrain
    targets = ["DiagTrack", "SysMain", "WSearch", "ProfSvc"]
    
    for t in targets:
        # Ask Colibri about it
        answer = query_godbrain(f"Should I disable or delete the {t} service to optimize Windows 11?")
        report += f"--- Target: {t} ---\nGodBrain Verdict:\n{answer}\n\n"
        
    return report

if __name__ == "__main__":
    services = scan_services()
    report = generate_report(services)
    
    with open("local_sre_report.txt", "w", encoding="utf-8") as f:
        f.write(report)
        
    print("\n[+] Scan complete. Check 'local_sre_report.txt'.")
