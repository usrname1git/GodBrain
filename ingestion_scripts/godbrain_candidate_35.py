import asyncio
import sys
import json
from godbrain_core.kernel import kernel

async def main():
    print("[*] Simulating LLM Request to Nervous System...")
    
    payload = {
        "command": "echo 'GodBrain Nervous System is LIVE' > godbrain_heartbeat.txt",
        "reasoning": "Verifying the dispatcher works!"
    }
    
    print(f"[*] Sending Payload: {json.dumps(payload, indent=2)}")
    
    # Send directly to the Kernel Dispatcher (just like the MCP does)
    result = await kernel.dispatch("execute_godbrain_script", payload)
    
    print("\n[*] Kernel Response:")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    asyncio.run(main())