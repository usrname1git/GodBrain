import asyncio
import json
from godbrain_core.kernel import kernel

async def main():
    print("[*] Simulating LLM Request: Saving a thought to GodBrain (Neo4j Sync Test)...")
    
    payload = {
        "content": "The SuperGem instance is officially online and graph memory is functioning.",
        "source": "Sovereign Architect",
        "tags": ["graph-sync", "SuperGem"]
    }
    
    # Send directly to the Kernel Dispatcher
    result = await kernel.dispatch("save_godbrain_thought", payload)
    
    print("\n[*] Kernel Response:")
    print(json.dumps(result, indent=2))
    
    # Let the background Neo4j async task complete before the script exits
    await asyncio.sleep(2)

if __name__ == "__main__":
    asyncio.run(main())