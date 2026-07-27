import asyncio
import logging
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [REGISTRY_BASELINE_CRAWLER] - %(message)s")
logger = logging.getLogger("RegistryBaseline")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']
collection = db['knowledge_graph']

REGISTRY_BASELINE_VECTORS = [
    {
        "id": "win_reg_hive_architecture",
        "title": "Windows Registry Hive Architecture & Disk Locations",
        "content": "The Windows Registry is not a single file, but a collection of binary 'hive' files loaded into memory. HKLM\\SYSTEM, HKLM\\SOFTWARE, HKLM\\SECURITY, and HKLM\\SAM live in C:\\Windows\\System32\\config\\. HKCU lives in C:\\Users\\<user>\\ntuser.dat. HKU\\<SID>_Classes lives in UsrClass.dat. On a fresh install, these files define the absolute default state of the OS, services, and policies.",
        "tags": ["Windows", "Registry", "Architecture", "Baseline", "Hive"]
    },
    {
        "id": "win_reg_critical_baselines",
        "title": "Fresh Install High-Value Registry Baselines",
        "content": "Critical keys to verify against a fresh install: 1. HKLM\\SYSTEM\\CurrentControlSet\\Services (defines all default drivers/services; unexpected services or modified Start=3 to Start=4 indicate tampering). 2. HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run (empty or minimal on fresh install). 3. HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon (Userinit must be userinit.exe, Shell must be explorer.exe). Deviations here indicate malware, corruption, or undocumented OS changes.",
        "tags": ["Windows", "Registry", "Baseline", "Persistence", "Security"]
    },
    {
        "id": "win_reg_offline_repair",
        "title": "Offline Registry Hive Manipulation",
        "content": "If a system won't boot due to registry corruption or locked Ring-0 keys blocking telemetry nuking, boot into Windows RE or use another OS instance. Navigate to C:\\Windows\\System32\\config\\. Manually load the offline hive using 'reg load HKLM\\TempHive C:\\Windows\\System32\\config\\SYSTEM'. Apply SDDL ownership changes or value deletions, then commit with 'reg unload HKLM\\TempHive'. This completely bypasses active OS kernel protections and TrustedInstaller locks.",
        "tags": ["Windows", "Registry", "SRE", "Offline", "Bypass"]
    },
    {
        "id": "win_reg_wmi_cim_persistence",
        "title": "WMI & CIM Registry Persistence",
        "content": "Advanced Windows configurations and telemetry often hide in WMI repositories rather than standard registry keys, specifically as Event Consumers (__EventFilter). However, the WMI repository definition is linked to registry configs under HKLM\\SOFTWARE\\Microsoft\\WBEM. Rebuilding a corrupt WMI repository requires stopping the winmgmt service, renaming C:\\Windows\\System32\\wbem\\repository, and running 'mofcomp' on standard MOF files.",
        "tags": ["Windows", "Registry", "WMI", "CIM", "SRE"]
    }
]

def run_ingestion():
    logger.info("Initializing Windows Registry Baseline Ingestion...")
    for vector in REGISTRY_BASELINE_VECTORS:
        collection.update_one(
            {"id": vector["id"]},
            {"$set": vector},
            upsert=True
        )
        logger.info(f"Ingested Registry Baseline Concept: {vector['title']}")
    logger.info("Registry Baseline ingestion complete.")

if __name__ == "__main__":
    run_ingestion()
