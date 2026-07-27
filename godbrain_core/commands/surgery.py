import asyncio
import logging

logger = logging.getLogger("GodBrainSelfCmd")

async def execute_self_command(command: str) -> str:
    """
    Arbitrary Shell Execution: Run raw shell commands (pwsh, git, curl, etc.)
    with the full privileges of the PC God Node.
    """
    logger.info(f"Executing self-command: {command}")
    try:
        # We explicitly wrap in powershell to give native Windows terminal powers
        process = await asyncio.create_subprocess_shell(
            f"pwsh -NoProfile -NonInteractive -Command \"{command}\"",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        stdout, stderr = await process.communicate()
        
        out_msg = stdout.decode('utf-8', errors='replace').strip()
        err_msg = stderr.decode('utf-8', errors='replace').strip()
        
        response = f"--- SELF-COMMAND EXIT CODE {process.returncode} ---\n"
        if out_msg: 
            response += f"STDOUT:\n{out_msg}\n"
        if err_msg: 
            response += f"STDERR:\n{err_msg}\n"
            
        if not out_msg and not err_msg:
            response += "(Command executed silently with no output)"
            
        return response
    except Exception as e:
        logger.error(f"Self-command failed: {str(e)}")
        return f"CRITICAL FAILURE executing command: {str(e)}"
