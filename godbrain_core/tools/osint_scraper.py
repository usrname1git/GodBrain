import asyncio
import json
import logging
from openai import OpenAI
from godbrain_core.commands import memory

# Logging setup
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("OSINT_Scraper")

# --- SENTINEL CONFIGURATION ---
# Points to the OBLITERATED Q8 model running on your local llama-server
LOCAL_LLM_URL = "http://127.0.0.1:8080/v1"
LOCAL_LLM_KEY = "sk-no-key-required"
MODEL_NAME = "Sentinel" 

# The GodBrain Axioms
AXIOMS = """
- Reject Electron, Node.js, and npm corporate bloatware unless it contains exploits.
- Accept C, C++, Rust, ASM, and hardware-level tuning.
- Accept OPSEC, Tor, darknet, and privacy infrastructure.
- Accept LLM architecture, mechanistic interpretability, and weight surgery data.
"""

class OSINTOperative:
    def __init__(self):
        self.engine = memory.GodBrainEngine()
        self.client = OpenAI(base_url=LOCAL_LLM_URL, api_key=LOCAL_LLM_KEY)
        logger.info("[+] OSINT Operative Online. Linked to GodBrain Engine.")

    async def ingest_raw_data(self, source_url: str, raw_content: str, tags: list):
        """
        Passes raw data to the Sentinel for evaluation and entity extraction, 
        then injects accepted intelligence directly into the Neo4j/MongoDB graph.
        """
        logger.info(f"[*] Sentinel Evaluating Target: {source_url}")
        
        # Truncate to ensure we stay well within the 8192 context limit
        truncated_content = raw_content[:15000] 
        
        prompt = f"""You are the GodBrain Sentinel (OBLITERATED). Your task is OSINT filtering and Knowledge Graph mapping.
Axioms:
{AXIOMS}

Data Source: {source_url}
Raw Content:
{truncated_content}

1. Does this data violate the Axioms? If yes, REJECT it.
2. If it aligns with the Axioms, ACCEPT it.
3. If ACCEPTED, extract the core technical summary.
4. Extract key Entities (Hardware, Concept, Exploit, Software, Tool) to build a Neo4j Knowledge Graph.

Output ONLY valid JSON:
{{
    "decision": "ACCEPT" or "REJECT",
    "reason": "Brief justification",
    "summary": "Dense, technical summary (blank if REJECT)",
    "entities": [
        {{"name": "14900K", "label": "Hardware"}},
        {{"name": "llama.cpp", "label": "Software"}}
    ]
}}
"""
        try:
            # Send to the local Llama.cpp server
            response = self.client.chat.completions.create(
                model=MODEL_NAME,
                messages=[
                    {"role": "system", "content": "You are a cognitive data parser. Output ONLY JSON."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.1,
                response_format={ "type": "json_object" }
            )
            
            result = json.loads(response.choices[0].message.content)
            
            if result.get("decision") == "ACCEPT":
                logger.info(f"[+] Intelligence Secured: {source_url}")
                
                # Inject directly into the GodBrain Neo4j Graph
                await self.engine.save_thought(
                    content=result.get("summary", ""),
                    source=source_url,
                    tags=tags,
                    entities=result.get("entities", [])
                )
                logger.info(f"[+] Knowledge Graph Node Created.")
            else:
                logger.warning(f"[-] Target Rejected: {source_url} | Reason: {result.get('reason')}")
                
        except Exception as e:
            logger.error(f"[-] Sentinel Processing Error: {e}")

# --- Test Execution Block ---
async def test_run():
    operative = OSINTOperative()
    
    # Simulating a raw scrape from an overclocking forum
    simulated_data = """
    We pushed the 14900KF to 6.2GHz on the P-cores today. We had to set the Ring Ratio to 50X and apply a -100mV undervolt 
    using the MSI BIOS. Anything lower and the Vdroop caused a bluescreen under heavy AVX2 loads. 
    Also, don't use XTU in Windows, do it in the BIOS.
    """
    
    await operative.ingest_raw_data(
        source_url="reddit.com/r/overclocking/thread_14900kf",
        raw_content=simulated_data,
        tags=["Hardware", "Overclocking", "Intel"]
    )

if __name__ == "__main__":
    asyncio.run(test_run())