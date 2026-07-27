import asyncio
from godbrain_core.commands.memory import GodBrainEngine

async def ingest_rust_exclusive():
    engine = GodBrainEngine()
    
    content = """[GODBRAIN CORE DIRECTIVE: PROTOCOL GO-ABANDONMENT & RUST EXCLUSIVITY]
SOURCE: Father Autismo
TOPIC: Total Commitment to Rust over Golang

CORE STRATEGY PIVOT:
1. Google's Graveyard: Trusting Google's ecosystem (like Golang or Antigravity-cli) is an architectural liability. Google routinely abandons projects (e.g., Gemini-CLI). Betting the GodBrain execution orchestrator on Golang risks hitting a dead-end.
2. Rust Exclusivity: Rust is the undeniable, mathematically sound future of systems computing. It is entirely open-source, aggressively maintained, and unaffected by the whims of a single tech monopoly.
3. The Win32 Advantage: Rust's `std::process::Command` talks directly to the Windows API, bypassing PowerShell's horrific string-quoting issues. It is the perfect language for the Intelligent Terminal COM bridge.
4. Result: All GodBrain autonomous execution components, TUIs, and Interceptors will be written exclusively in Rust."""

    await engine.save_thought(
        content=content,
        source='Internal_Autismo_Logic',
        tags=['rust-exclusive', 'golang-abandonment', 'google-graveyard', 'intelligent-terminal-bridge']
    )

    print("[+] Hard-coded Protocol Go-Abandonment and Rust Exclusivity into GodBrain.")
    print("[+] Neo4j Cloud Linked.")

if __name__ == "__main__":
    asyncio.run(ingest_rust_exclusive())