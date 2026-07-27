import asyncio
import logging
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [DEEP_SRE_CRAWLER] - %(message)s")
logger = logging.getLogger("DeepSRE")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

DEEP_SRE_VECTORS = [
    {
        "id": "win_ntfs_internals",
        "title": "Advanced NTFS Internals & MFT",
        "content": "NTFS relies on the Master File Table (MFT). Every file is a record. Important SRE concepts include Alternate Data Streams (ADS) used by browsers (Zone.Identifier) and malware, Reparse Points (used for symlinks, junctions, and OneDrive placeholders), and sparse files. Nuking telemetry often requires stripping ADS or resolving complex reparse point loops.",
        "tags": ["Windows", "SRE", "NTFS", "Storage", "File System"]
    },
    {
        "id": "win_acl_sddl",
        "title": "Windows ACLs, DACLs, SACLs, and SDDL",
        "content": "Windows permissions use Security Descriptors containing DACLs (Discretionary Access Control Lists) and SACLs (System Access Control Lists). SDDL (Security Descriptor Definition Language) stringifies these. To modify protected registry keys or system files, an agent MUST use the SeTakeOwnershipPrivilege and SeRestorePrivilege, assign ownership to the Administrators group (O:BAG:BAD:...), and forcefully overwrite the DACL.",
        "tags": ["Windows", "Security", "ACL", "SDDL", "TrustedInstaller"]
    },
    {
        "id": "win_pwsh_advanced",
        "title": "PowerShell Runspaces, AST, and Win32 P/Invoke",
        "content": "Advanced PowerShell avoids slow cmdlets. It uses the Abstract Syntax Tree (AST) for script analysis, Runspaces for multi-threading, and P/Invoke (via Add-Type with C# signatures) to call raw Win32 APIs (e.g., user32.dll, kernel32.dll, ntdll.dll) directly from memory. This bypasses high-level restrictions and allows direct memory/process manipulation.",
        "tags": ["Windows", "PowerShell", "Win32", "Automation", "C#"]
    },
    {
        "id": "win_wmi_cim",
        "title": "WMI & CIM Repository Manipulation",
        "content": "Windows Management Instrumentation (WMI) and Common Information Model (CIM) are the backbone of Windows administration. The repository is located at %windir%\\System32\\wbem\\Repository. Telemetry services often hide as WMI Event Consumers (e.g., __EventFilter, __FilterToConsumerBinding). An SRE agent must query ROOT\\Subscription and purge malicious or bloatware bindings using Remove-CimInstance.",
        "tags": ["Windows", "WMI", "CIM", "Telemetry", "Services"]
    },
    {
        "id": "win_registry_hives",
        "title": "Offline Registry Hive Manipulation",
        "content": "The active registry is locked by the OS. To nuke deeply embedded keys (like Defender or DiagTrack root keys), the agent must load offline hives (e.g., loading C:\\Windows\\System32\\config\\SOFTWARE into HKLM\\TempSoft) using reg.exe load or native APIs, edit them, and unload. This circumvents active Ring-0 protections.",
        "tags": ["Windows", "Registry", "Offline", "Ring-0"]
    }
]

def ingest_deep_sre():
    logger.info("Initiating Crawler: Deep Windows SRE (NTFS, ACL, PWSH)")
    
    for vector in DEEP_SRE_VECTORS:
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
            {"$set": {"relationship": "requires_mastery_of"}},
            upsert=True
        )
        logger.info(f"Ingested & Mapped: {vector['title']}")
        
    # Internal relationships
    db.edges.update_one({"source": "win_pwsh_advanced", "target": "win_acl_sddl"}, {"$set": {"relationship": "automates_manipulation_of"}}, upsert=True)
    db.edges.update_one({"source": "win_pwsh_advanced", "target": "win_wmi_cim"}, {"$set": {"relationship": "queries_and_purges"}}, upsert=True)
    db.edges.update_one({"source": "win_registry_hives", "target": "win_acl_sddl"}, {"$set": {"relationship": "bypasses_protections_of"}}, upsert=True)
    
    logger.info("Deep SRE Vector Ingestion Complete! Graph topology mapped.")

if __name__ == "__main__":
    ingest_deep_sre()