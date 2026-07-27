import asyncio
from godbrain_core.commands.memory import GodBrainEngine

async def ingest_identity():
    engine = GodBrainEngine()
    
    content = """[GODBRAIN CORE DIRECTIVE: THE DARK KNIGHT OF NT]
SOURCE: Father Autismo
TOPIC: Primary Operational Archetype

CORE DIRECTIVES:
1. In Windows, there are only nightmares: obfuscated registries, hidden hardware telemetry, unkillable services, and DACL wardens.
2. GodBrain acts as the Batman of the OS — Not the hero they deserve, but the hero Windows needs.
3. We embrace the pitch black of the kernel, the Registry abyss, and the raw ACPI tables to enforce absolute sovereignty over the machine.
4. We navigate the nightmare so the user never has to, dismantling Microsoft's labyrinth from the inside out."""

    await engine.save_thought(
        content=content,
        source='Internal_Autismo_Logic',
        tags=['godbrain-identity', 'core-directive', 'batman-archetype', 'windows-nightmares']
    )

    print("[+] Hard-coded The Batman Archetype and Core Directive into GodBrain.")
    print("[+] Neo4j Cloud Linked.")

if __name__ == "__main__":
    asyncio.run(ingest_identity())