import json
import asyncio
import httpx
import subprocess
from datetime import datetime
from godbrain_core.kernel import kernel

LLM_API_URL = "http://127.0.0.1:8080/v1/chat/completions"

def get_windows_errors():
    """Scrapes recent System and Application errors using PowerShell."""
    ps_script = (
        "Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2} -MaxEvents 15 -ErrorAction SilentlyContinue "
        "| Select-Object TimeCreated, Id, ProviderName, Message | ConvertTo-Json"
    )
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_script],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except Exception as e:
        print(f"[-] Failed to fetch Event Logs: {e}")
        return None

async def consult_oracle(log_data: str) -> str:
    """Sends the logs to SuperGem for deep diagnostic reasoning."""
    system_prompt = (
        "You are the GodBrain Sentinel, a legendary Oracle of Windows OS Internals. "
        "You diagnose deep system corruptions, DCOM permission errors, and registry failures that SFC/DISM cannot fix. "
        "Review the provided Windows Event Logs. "
        "1. Diagnose the root cause of the most critical recurring error. "
        "2. Propose a hyper-specific, surgical PowerShell script to fix it. Use 'wsudo -T pwsh -NoProfile -Command' if TrustedInstaller elevation is needed for registry ACLs or locked files. "
        "Keep the explanation concise and the code exact."
    )
    
    payload = {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Analyze these errors and draft a surgical fix:\n\n{log_data}"}
        ],
        "temperature": 0.2, # Low temp for precise, surgical logic
        "max_tokens": 1500
    }
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(LLM_API_URL, json=payload)
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"Oracle disconnected: {e}"

async def run_sentinel():
    print("[*] GodBrain Sentinel Waking Up...")
    print("[*] Scraping bleeding-edge System and Application errors...")
    
    logs = get_windows_errors()
    if not logs or len(logs) < 10:
        print("[+] OS appears exceptionally clean. No critical recent errors found.")
        return

    print(f"[*] Found recent critical errors. Piping to SuperGem for Surgical Diagnostics...")
    diagnosis = await consult_oracle(logs)
    
    print("\n================== SENTINEL DIAGNOSIS ==================")
    print(diagnosis)
    print("========================================================\n")
    
    print("[*] Committing Diagnosis to GodBrain Memory Graph...")
    payload = {
        "content": f"[SENTINEL DIAGNOSIS]\nLogs:\n{logs[:500]}...\n\nOracle Fix:\n{diagnosis}",
        "source": "Sentinel_Oracle",
        "tags": ["system-healing", "registry-surgery", "diagnostic"]
    }
    await kernel.dispatch("save_godbrain_thought", payload)
    
    # Save the script locally for review
    with open("pending_surgery.md", "w", encoding="utf-8") as f:
        f.write(diagnosis)
    
    print("[+] Surgery drafted and saved to 'pending_surgery.md'. Awaiting Commander validation.")

if __name__ == "__main__":
    asyncio.run(run_sentinel())