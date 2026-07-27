import asyncio
import logging
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [REGISTRY_BEST_PRACTICES] - %(message)s")
logger = logging.getLogger("RegistryBestPractices")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']
collection = db['knowledge_graph']

REGISTRY_BEST_PRACTICES_VECTORS = [
    {
        "id": "win_reg_security_baseline",
        "title": "Windows Registry Security & LSA Baselines",
        "content": "A highly secure Windows environment requires specific registry states. HKLM\\SYSTEM\\CurrentControlSet\\Control\\Lsa: 'RunAsPPL'=1 (enables LSA protection to prevent credential dumping like Mimikatz). HKLM\\SYSTEM\\CurrentControlSet\\Control\\SecurityProviders\\WDigest: 'UseLogonCredential'=0 (forces cleartext passwords out of RAM). HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System: 'EnableLUA'=1 (UAC must be on, even if silently elevating, to keep integrity levels intact).",
        "tags": ["Windows", "Registry", "Security", "LSA", "Best Practices"]
    },
    {
        "id": "win_reg_telemetry_nuke",
        "title": "Optimal Telemetry & Privacy Registry Configuration",
        "content": "To achieve a true zero-telemetry state, these registry keys are optimal: HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection: 'AllowTelemetry'=0. HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search: 'AllowCortana'=0, 'DisableWebSearch'=1, 'ConnectedSearchUseWeb'=0. HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo: 'Enabled'=0. This stops Windows from phoning home and disables web-integrated search bloat.",
        "tags": ["Windows", "Registry", "Telemetry", "Privacy", "Optimal"]
    },
    {
        "id": "win_reg_malware_hooks",
        "title": "Identifying Malicious Registry Hooks (IFEO & AppInit)",
        "content": "When auditing the registry, the system must check for malicious hooks. HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options (IFEO): If a 'Debugger' value exists for an executable (e.g., sethc.exe or utilman.exe), it's likely a privilege escalation backdoor. HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Windows: 'AppInit_DLLs' should be empty; if populated, it injects DLLs into every user-mode process. 'LoadAppInit_DLLs' should be 0.",
        "tags": ["Windows", "Registry", "Malware", "Hooks", "SRE", "Verification"]
    },
    {
        "id": "win_reg_performance_network",
        "title": "Optimal Performance & Network Registry Tweaks",
        "content": "For maximum network and system performance (gaming/server), the optimal states are: HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile: 'NetworkThrottlingIndex'=0xffffffff (disables throttling) and 'SystemResponsiveness'=0. For TCP: HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces\\<Adapter>: 'TcpAckFrequency'=1 and 'TCPNoDelay'=1 (disables Nagle's algorithm for lowest latency).",
        "tags": ["Windows", "Registry", "Performance", "Network", "Optimal"]
    }
]

def run_ingestion():
    logger.info("Initializing Windows Registry Best Practices Ingestion...")
    for vector in REGISTRY_BEST_PRACTICES_VECTORS:
        collection.update_one(
            {"id": vector["id"]},
            {"$set": vector},
            upsert=True
        )
        logger.info(f"Ingested Registry Best Practice: {vector['title']}")
    logger.info("Registry Best Practices ingestion complete.")

if __name__ == "__main__":
    run_ingestion()
