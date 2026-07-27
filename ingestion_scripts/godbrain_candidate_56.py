import asyncio
import json
from godbrain_core.kernel import kernel

async def main():
    print("[*] Simulating LLM Request: Spatial Awareness (Constellation Query)...")
    
    payload = {
        "reasoning": "Need to map the workspace environment and verify spatial indexing."
    }
    
    # Send directly to the Kernel Dispatcher
    result = await kernel.dispatch("query_constellation", payload)
    
    print("\n[*] Kernel Response:")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    asyncio.run(main())