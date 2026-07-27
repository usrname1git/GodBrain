import asyncio
import json
from godbrain_core.kernel import kernel

async def main():
    print("[*] Simulating LLM Request: Introspection (MongoDB Memory Query)...")
    
    payload = {
        "limit": 3,
        "reasoning": "Need to recall recent actions to orient myself."
    }
    
    # Send directly to the Kernel Dispatcher
    result = await kernel.dispatch("query_recent_thoughts", payload)
    
    print("\n[*] Kernel Response (MongoDB Dump):")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    asyncio.run(main())