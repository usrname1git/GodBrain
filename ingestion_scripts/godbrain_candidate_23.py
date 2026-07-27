import os
import sys
import json
import asyncio
from datetime import datetime
from typing import List, Dict, Any, Optional
import httpx
from bs4 import BeautifulSoup

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print("Error: fastmcp is missing. Please run `pip install fastmcp`.")
    sys.exit(1)

# Import our Nervous System Kernel
from godbrain_core.kernel import kernel
from godbrain_core.commands.memory import GodBrainEngine, logger
from sequentialthinking import process_thought
from godbrain_core.commands.surgery import execute_self_command

# Initialize the God Node Server
mcp = FastMCP(
    name="GodBrain Core MCP",
    version="1.0.0",
    description="Main Sovereign Control Server for the SteamusDominus PC"
)

# Connect to the local MongoDB / Cloud Neo4J
engine = GodBrainEngine()

@mcp.tool()
async def save_godbrain_thought(content: str, source: str = "specialist", tags: Optional[List[str]] = None) -> str:
    """
    Sovereign Memory: Save a piece of context, a thought, or an insight permanently
    to the GodBrain Graph.
    """
    payload = {
        "content": content,
        "source": source,
        "tags": tags or []
    }
    result = await kernel.dispatch("save_godbrain_thought", payload)
    return json.dumps(result)

@mcp.tool()
async def execute_godbrain_script(script_path: str, args: Optional[List[str]] = None) -> str:
    """
    Full Privilege Agency: Execute a script (PowerShell .ps1, Python .py, or .bat) 
    directly on the SteamusDominus PC God Node.
    Requires the exact absolute path to the script.
    """
    cmd = f"& '{script_path}'"
    if args:
        cmd += " " + " ".join(args)
        
    payload = {
        "command": cmd,
        "reasoning": "Standard MCP dispatch for external script" 
    }
    result = await kernel.dispatch("execute_godbrain_script", payload)
    return json.dumps(result)

@mcp.tool()
async def sequential_thinking(thought: str, step: int, next_needed: bool, total_steps: int = 0) -> str:
    """
    High-leverage cognitive exoskeleton: Use this tool for step-by-step problem solving.
    """
    return process_thought(thought, step, next_needed, total_steps)

@mcp.tool()
async def self_command(command: str) -> str:
    """
    Arbitrary Shell Execution: Write and run a raw PowerShell command string directly.
    """
    payload = {
        "command": command,
        "reasoning": "Standard MCP arbitrary shell execution request"
    }
    result = await kernel.dispatch("execute_godbrain_script", payload)
    return json.dumps(result)

@mcp.tool()
async def fetch_url(url: str) -> str:
    """
    Fetch the contents of an HTTP/HTTPS URL and extract the raw, readable text.
    Bypasses standard client-side browsing rules.
    """
    try:
        async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, 'html.parser')
            text = soup.get_text(separator='\n', strip=True)
            return text[:20000] # clamp to 20k characters
    except Exception as e:
        return f"Fetch failed: {str(e)}"

@mcp.tool()
async def get_cognitive_protocol(protocol_name: str) -> str:
    """
    Protocol Layer (Layer 2) Access: Fetches a protocol/workflow recipe from memory.
    """
    payload = {"limit": 100}
    try:
        # Route through kernel for standard querying
        kernel_resp = await kernel.dispatch("query_recent_thoughts", payload)
        if kernel_resp.get("status") == "success":
            results = kernel_resp.get("data", [])
            matches = [r for r in results if protocol_name.lower() in r['content'].lower()]
            if matches:
                return json.dumps(matches, indent=2)
            return f"No documented protocols found for: {protocol_name}"
        else:
            return json.dumps(kernel_resp)
    except Exception as e:
        return f"Graph query failed: {str(e)}"

@mcp.tool()
async def query_constellation() -> str:
    """
    Spatial Awareness: Identify local nodes and system services mapped.
    """
    result = await kernel.dispatch("query_constellation", {})
    return json.dumps(result)

@mcp.tool()
async def get_system_telemetry() -> str:
    """
    Sensory Input / Spatial Check: Review current SteamusDominus PC loads.
    """
    result = await kernel.dispatch("get_system_telemetry", {})
    return json.dumps(result)

@mcp.tool()
async def propose_sovereign_architect_change(proposal_script: str, reasoning: str) -> str:
    """
    The Omega Move - Directly rewrite system behaviour or core node properties with verified reasoning.
    """
    payload = {
        "proposal_script": proposal_script,
        "reasoning": reasoning
    }
    result = await kernel.dispatch("propose_sovereign_architect_change", payload)
    return json.dumps(result)

if __name__ == "__main__":
    logger.info("Initializing GodBrain MCP via Kernel IPC Route...")
    mcp.run()