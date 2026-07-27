import asyncio
import json
from typing import Dict, Any

from godbrain_core.commands import surgery, memory, telemetry
from godbrain_core.registry import constellation

# Obtain our localized Memory Engine
engine = memory.GodBrainEngine()

class GodBrainKernel:
    """
    The Nervous System Hub. 
    This is the only module the C++ hook interacts with.
    It validates, routes, and executes 'First-Class' commands.
    """
    def __init__(self):
        self.system_state = {}
        # Initialize the constellation map for spatial awareness
        self.map = constellation.load_map()

    async def dispatch(self, command_type: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        The primary entry point for the C++ hook.
        """
        print(f"[KERNEL] Intercepting Command: {command_type}")
        
        # 1. SECURITY & SOVEREIGNTY CHECK (The "Circuit Breaker")
        if not self._validate_sovereignty(command_type, payload):
            return {"status": "error", "message": "Sovereignty check failed: Action exceeds current authority or lacks reasoning."}

        # 2. ROUTING TABLE
        try:
            if command_type == "execute_godbrain_script":
                # Surgery Logic (SQL, SC Delete, Registry, Powershell)
                result = await surgery.execute_self_command(payload.get("command", ""))
            
            elif command_type == "save_godbrain_thought":
                # Memory Logic (MongoDB / Neo4j)
                result = await engine.save_thought(
                    content=payload.get("content", ""),
                    source=payload.get("source", "GodBrain_Kernel"),
                    tags=payload.get("tags", [])
                )
            
            elif command_type == "query_recent_thoughts":
                # Memory Logic (Retrieval)
                result = await engine.get_recent(limit=payload.get("limit", 5))
            
            elif command_type == "query_constellation":
                # Spatial Awareness
                result = constellation.query(payload)
            
            elif command_type == "get_system_telemetry":
                # Sensory Input
                result = await telemetry.get_current_state()
            
            elif command_type == "propose_sovereign_architect_change":
                # The Omega Move (Reflective iteration)
                result = await surgery.execute_self_command(payload.get("proposal_script", ""))
            
            else:
                return {"status": "error", "message": f"Unknown command: {command_type}"}

            # 3. CONTEXT INJECTION
            # The result is fed back into the LLM's context stream
            return {"status": "success", "data": result}

        except Exception as e:
            print(f"[KERNEL ERROR] {str(e)}")
            return {"status": "error", "message": str(e)}

    def _validate_sovereignty(self, command_type: str, payload: Dict[str, Any]) -> bool:
        """
        Determines if the Mind has the 'Right' to perform the action.
        This is where you can implement 'Layers of Authority'.
        """
        # Example: Certain surgeries require 'Reasoning' to prove intentionality.
        high_risk_commands = ["execute_godbrain_script", "propose_sovereign_architect_change"]
        
        if command_type in high_risk_commands:
            # Ensure the LLM provided a 'reasoning' field for the surgery to verify cognitive intent
            if "reasoning" not in payload:
                print("[KERNEL SECURITY] High risk command rejected: No reasoning provided.")
                return False
        
        return True

# Singleton instance for IPC/Hook to import
kernel = GodBrainKernel()
