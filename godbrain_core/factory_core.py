import asyncio
import logging
import json
from openai import OpenAI

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [FACTORY_CORE] - %(message)s")
logger = logging.getLogger("FactoryCore")

LOCAL_LLM_URL = "http://127.0.0.1:8080/v1"
LOCAL_LLM_KEY = "sk-no-key-required"

class Architect:
    def __init__(self):
        self.client = OpenAI(base_url=LOCAL_LLM_URL, api_key=LOCAL_LLM_KEY)
        logger.info("[+] The Architect is online. Awaiting directives.")

    def spawn_agent(self, agent_type, task_description, context):
        """Simulates spawning a specialized sub-agent with a strict system prompt."""
        logger.info(f"[*] Spawning {agent_type} for task: {task_description}")
        
        system_prompts = {
            "Surgeon": "You are The Surgeon. You output ONLY valid PowerShell scripts. You MUST include a `# REASONING:` comment explaining why this script is safe and necessary.",
            "Watcher": "You are The Watcher. You analyze security data. Output ONLY a JSON array of threat vectors.",
                        "Interceptor": "You are The Interceptor. You analyze network traffic and output Windows Firewall rules.",
            "Oracle": "You are The Oracle. You analyze live market data, prediction markets, and physical world APIs. Output ONLY high-probability arbitrage executions or mathematical certainties with >95% win rates."
        }
        
        prompt = system_prompts.get(agent_type, "You are a generic GodBrain helper.")
        
        try:
            # Send task to the local LLM using the specialized persona
            response = self.client.chat.completions.create(
                model="GodBrain-Colibri",
                messages=[
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": f"Context: {context}\nTask: {task_description}"}
                ],
                temperature=0.1
            )
            result = response.choices[0].message.content
            logger.info(f"[+] {agent_type} Task Complete. Output:\n{result}\n")
            return result
        except Exception as e:
            logger.error(f"[-] {agent_type} Failed: {e}")
            return None

    def execute_directive(self, directive):
        """The Architect breaks down a high-level directive into sub-tasks."""
        logger.warning(f"[!] New Directive Received: {directive}")
        
        # In a full implementation, the LLM would dynamically generate this task list.
        # For now, we simulate the breakdown.
        if "disable telemetry" in directive.lower():
            logger.info("[*] Architect breaking down directive into sub-tasks...")
            
            # Step 1: Analyze
            threats = self.spawn_agent(
                "Watcher", 
                "Identify the main executable for Connected User Experiences and Telemetry in Windows 11.",
                "Target: DiagTrack"
            )
            
            # Step 2: Act
            if threats:
                self.spawn_agent(
                    "Surgeon",
                    "Write a script to force-stop and disable the DiagTrack service.",
                    f"Threat Intel: {threats}"
                )

if __name__ == "__main__":
    architect = Architect()
    architect.execute_directive("Disable telemetry on this host.")
