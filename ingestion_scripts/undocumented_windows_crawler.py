import asyncio
import logging
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [UNDOC_WINDOWS_CRAWLER] - %(message)s")
logger = logging.getLogger("UndocWindows")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

# Deep internal knowledge for GodBrain to understand Windows surveillance and bloat
UNDOCUMENTED_VECTORS = [
    {
        "id": "win_appx_srd",
        "title": "AppX StateRepository-Machine.srd",
        "content": "The StateRepository database (StateRepository-Machine.srd) is an SQLite-based tracking mechanism located at %ProgramData%\\Microsoft\\Windows\\AppRepository. It enforces UWP app state, licensing, and telemetry. It locks aggressively. Nuking this requires taking ownership from TrustedInstaller or editing offline via WinPE. Used heavily by Cortana, Edge, and hidden telemetry apps.",
        "tags": ["Windows", "SRE", "AppX", "Database", "Bloat"]
    },
    {
        "id": "win_etw_surveillance",
        "title": "Event Tracing for Windows (ETW) Surveillance",
        "content": "ETW is the lowest-level logging mechanism in Windows, running at Ring-0. Microsoft uses AutoLogger sessions (e.g., Circular Kernel Context Logger, DiagLog, SQMLogger) to stream process execution, network sockets, and file I/O to Microsoft before the user even logs in. To severe ETW, one must neuter Autologger registry keys under HKLM\\SYSTEM\\CurrentControlSet\\Control\\WMI\\Autologger.",
        "tags": ["Windows", "ETW", "Ring-0", "Surveillance", "Kernel"]
    },
    {
        "id": "win_diagtrack",
        "title": "Connected User Experiences and Telemetry (DiagTrack)",
        "content": "DiagTrack is the primary telemetry daemon (svchost.exe -k utcsvc). It reads ETW sessions and uploads encrypted payloads to v10.events.data.microsoft.com. It masks itself as 'Connected User Experiences'. Disabling the service is not enough; its Appraiser scheduled tasks and WMI providers must also be purged.",
        "tags": ["Windows", "DiagTrack", "Telemetry", "Network"]
    },
    {
        "id": "win_boot_surveillance",
        "title": "Early Launch Anti-Malware (ELAM) & Boot Telemetry",
        "content": "Modern Windows employs ELAM drivers and Secure Boot architectures that load telemetry agents before non-system drivers. ACPI and connected standby states are often intercepted to keep network connections alive for telemetry uploads while the device appears 'asleep'. Disabling Modern Standby (CsEnabled=0) forces true S3/S4 sleep, cutting network access.",
        "tags": ["Windows", "ACPI", "Boot", "Surveillance", "Hardware"]
    },
    {
        "id": "win_ntapi_undoc",
        "title": "Undocumented NTAPI & Native System Services",
        "content": "Core OS manipulation requires bypassing Win32 APIs (kernel32.dll) and using Native APIs (ntdll.dll), such as NtSuspendProcess, NtQuerySystemInformation (SystemProcessInformation), and NtSetSystemInformation. These allow GodBrain to manipulate process states and hardware abstractions directly, bypassing standard User Account Control hooks.",
        "tags": ["Windows", "NTAPI", "Kernel", "C++"]
    }
]

def ingest_undocumented_vectors():
    logger.info("Initiating Crawler: Undocumented Windows Internals & Surveillance")
    
    # Ensure root exists
    db.nodes.update_one(
        {"_id": "windows_sre_root"},
        {"$set": {
            "title": "Windows SRE Core",
            "content": "Root node for Windows System Reliability Engineering.",
            "type": "index",
            "tags": ["Windows", "Root"]
        }},
        upsert=True
    )
    
    for vector in UNDOCUMENTED_VECTORS:
        node_id = vector["id"]
        
        db.nodes.update_one(
            {"_id": node_id},
            {"$set": {
                "title": vector['title'],
                "content": vector['content'],
                "type": "windows_document",
                "tags": vector['tags']
            }},
            upsert=True
        )
        
        # Link to root
        db.edges.update_one(
            {"source": "windows_sre_root", "target": node_id},
            {"$set": {"relationship": "contains_knowledge"}},
            upsert=True
        )
        logger.info(f"Ingested & Mapped: {vector['title']}")
        
    # Create internal relationships between the new nodes
    db.edges.update_one({"source": "win_etw_surveillance", "target": "win_diagtrack"}, {"$set": {"relationship": "feeds_data_to"}}, upsert=True)
    db.edges.update_one({"source": "win_boot_surveillance", "target": "win_etw_surveillance"}, {"$set": {"relationship": "initializes"}}, upsert=True)
    db.edges.update_one({"source": "win_ntapi_undoc", "target": "win_etw_surveillance"}, {"$set": {"relationship": "can_manipulate"}}, upsert=True)
    
    logger.info("Undocumented Vectors Ingestion Complete! Graph topology mapped.")

if __name__ == "__main__":
    ingest_undocumented_vectors()