import asyncio
from godbrain_core.commands.memory import GodBrainEngine

async def ingest_registry_insanity():
    engine = GodBrainEngine()
    
    # 1. Power Schemes Matrix
    content = """[WINDOWS REGISTRY ARCHITECTURE INTELLIGENCE]
SOURCE: GodBrain Direct Uplink
TOPIC: Deep Registry Subversion

CORE EXPLOIT THEORIES:
1. Power Schemes Matrix: HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\User\\PowerSchemes is an obfuscated lattice of GUIDs controlling deep ACPI, processor states, and thermal limits.
2. WOW6432Node CLSID Abyss: HKEY_LOCAL_MACHINE\\SOFTWARE\\WOW6432Node\\Classes\\CLSID. Destroying class definitions here cripples 32-bit execution layers permanently.
3. Environment Variable Illusions: variables like $home or $profile are purely fake strings mapped dynamically to HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Environment and HKCU\\Environment. Do not trust PowerShell env logic implicitly.
4. AppX/Helium Virtualization: Windows Terminal and modern UWPs bypass the real registry using fake Helium user databases (%LocalAppData%\\Packages\\<PackageFullName>\\SystemAppData\\Helium\\User.dat). Standard registry edits often fail against UWPs unless the .dat is directly compromised."""

    await engine.save_thought(
        content=content,
        source='Internal_Autismo_Logic',
        tags=['windows-registry', 'environment-variables', 'wow6432node', 'appx-helium', 'power-schemes']
    )

    print("[+] Hard-coded Registry Abyss, AppX Virtualization, and Environment Variable Illusions into GodBrain.")
    print("[+] Neo4j Cloud Linked.")

if __name__ == "__main__":
    asyncio.run(ingest_registry_insanity())
