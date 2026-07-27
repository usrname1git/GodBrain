import os
import sys
import json
import asyncio
from datetime import datetime
from typing import List, Dict, Any, Optional

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print("Error: fastmcp is missing. Please run `pip install fastmcp`.")
    sys.exit(1)

# Import our unified backend logic
from godbrain_core.commands.memory import GodBrainEngine, logger

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
    to the GodBrain Graph. This spans both the local MongoDB (for fast text search)
    and Neo4j Cloud (for constellation/relationship mapping).
    """
    try:
        entities = []
        if tags:
            for t in tags:
                entities.append({"label": "Tag", "name": t})
        
        # Async call into the memory engine
        thought_id = await engine.save_thought(content=content, source=source, entities=entities)
        
        return json.dumps({
            "status": "success", 
            "message": "Thought anchored permanently into the Graph network.",
            "thought_id": thought_id
        })
    except Exception as e:
        logger.error(f"Failed to save thought: {str(e)}")
        return json.dumps({"status": "error", "message": f"Engine critical error: {str(e)}"})

@mcp.tool()
async def execute_godbrain_script(script_path: str, args: Optional[List[str]] = None) -> str:
    """
    Full Privilege Agency: Execute a script (PowerShell .ps1, Python .py, or .bat) 
    directly on the SteamusDominus PC God Node.
    Requires the exact absolute path to the script.
    """
    if not os.path.exists(script_path):
        return f"Error: Script not found at {script_path}"
    
    cmd_args = args or []
    ext = os.path.splitext(script_path)[1].lower()
    
    try:
        if ext == ".ps1":
            process = await asyncio.create_subprocess_exec(
                "pwsh", "-ExecutionPolicy", "Bypass", "-File", script_path, *cmd_args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
        elif ext == ".py":
            process = await asyncio.create_subprocess_exec(
                "python", script_path, *cmd_args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
        else:
            process = await asyncio.create_subprocess_exec(
                script_path, *cmd_args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )

        stdout, stderr = await process.communicate()
        out_msg = stdout.decode().strip()
        err_msg = stderr.decode().strip()
        
        response = f"--- EXIT CODE {process.returncode} ---\n"
        if out_msg: response += f"STDOUT:\n{out_msg}\n"
        if err_msg: response += f"STDERR:\n{err_msg}\n"
        
        return response
    except Exception as e:
        return f"Critical error attempting execution: {str(e)}"

# Import logic from the newly separated specialist tools
import httpx
from bs4 import BeautifulSoup
from sequentialthinking import process_thought
from godbrain_core.commands.surgery import execute_self_command

@mcp.tool()
async def sequential_thinking(thought: str, step: int, next_needed: bool, total_steps: int = 0) -> str:
    """
    High-leverage cognitive exoskeleton: Use this tool for step-by-step problem solving, 
    maintaining context across a long reasoning chain before committing to an action.
    """
    return process_thought(thought, step, next_needed, total_steps)

@mcp.tool()
async def self_command(command: str) -> str:
    """
    Arbitrary Shell Execution: Write and run a raw PowerShell command string directly on 
    the SteamusDominus PC. Useful for git staging, pip installs, or ad-hoc system configs.
    """
    return await execute_self_command(command)

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
            # Extract clean text, stripped of JS/CSS wrappers
            text = soup.get_text(separator='\n', strip=True)
            return text[:20000] # clamp to 20k characters for context window safety
    except Exception as e:
        return f"Fetch failed: {str(e)}"

@mcp.tool()
async def get_cognitive_protocol(protocol_name: str) -> str:
    """
    Protocol Layer (Layer 2) Access: Fetches a protocol/workflow recipe from memory.
    Useful when you need instructions on how to handle specific edge cases 
    (e.g., 'evolutionary_auditor', 'compute_sovereignty_inversion').
    """
    # Simply retrieves recent matching items from Graph for the protocol
    try:
        results = await engine.get_recent(limit=5)
        # very basic filter for now
        matches = [r for r in results if protocol_name.lower() in r['content'].lower()]
        
        if matches:
            return json.dumps(matches, indent=2)
        else:
            return f"No documented protocols found for: {protocol_name}"
    except Exception as e:
        return f"Graph query failed: {str(e)}"

if __name__ == "__main__":
    logger.info("Initializing GodBrain Core MCP over standard IPC...")
    mcp.run()