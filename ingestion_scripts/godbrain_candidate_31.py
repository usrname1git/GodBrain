import os
import shutil
import asyncio
import httpx
from datetime import datetime
from godbrain_core.commands.vision import UniversalIngestionEngine
from godbrain_core.commands.memory import GodBrainEngine

# Folders
RAW_DROP_DIR = r"C:\Users\autismo\GodBrain_Raw_Drop"
PROCESSED_DIR = os.path.join(RAW_DROP_DIR, "processed")

# LLM Local Connect (llama-server default port)
LLM_API_URL = "http://127.0.0.1:8080/v1/chat/completions"

async def synthesize(content_chunk: str) -> str:
    """Pipelines the newly ingested knowledge through SuperGem for synthesis."""
    system_prompt = (
        "You are the Synthesizer module of the GodBrain OS. "
        "You are reading raw, newly ingested data from the user's brain drop. "
        "Extract the core technical concepts, ignore spam/filler, and return ONLY a dense, "
        "valuable summary of knowledge. If actionable protocols or scripts can be derived, list them."
    )
    
    payload = {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Synthesize this new knowledge:\n\n{content_chunk}"}
        ],
        "temperature": 0.4,
        "max_tokens": 1000
    }
    
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(LLM_API_URL, json=payload)
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"].strip()
    except Exception as e:
        print(f"[-] Synthesizer LLM pipeline failed: {e}")
        return "LLM Synthesis Failed - Offline or Timeout."

async def run_synthesizer_loop():
    engine = GodBrainEngine()
    ingestor = UniversalIngestionEngine()
    
    files_to_process = [f for f in os.listdir(RAW_DROP_DIR) if os.path.isfile(os.path.join(RAW_DROP_DIR, f))]
    
    if not files_to_process:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Synthesizer Loop: No new files in {RAW_DROP_DIR}")
        return

    print(f"\n[*] Synthesizer Waking Up. Found {len(files_to_process)} raw drops.")
    
    for filename in files_to_process:
        filepath = os.path.join(RAW_DROP_DIR, filename)
        print(f"  -> Ingesting: {filename}")
        
        # 1. OCR / Text Extraction
        raw_text = ingestor._extract_text(filepath)
        
        if not raw_text:
            print(f"     [!] Empty extraction. Moving to processed.")
            shutil.move(filepath, os.path.join(PROCESSED_DIR, filename))
            continue
            
        # 2. Raw Capture to Database
        await engine.save_thought(
            content=f"[RAW FILE: {filename}]\n{raw_text}",
            source="Synthesizer_Raw",
            tags=["raw-drop"]
        )
        
        # 3. SuperGem Cognitive Synthesis
        print(f"  -> Sending to SuperGem for Synthesis...")
        synthesis = await synthesize(raw_text[:8000]) # Cap to 8k context heavily
        
        # 4. Save Final Distilled Knowledge 
        await engine.save_thought(
            content=f"[SYNTHESIS: {filename}]\n{synthesis}",
            source="SuperGem_Synthesizer",
            tags=["distilled-knowledge", "auto-learning"]
        )
        print(f"     [+] Synthesis Captured to GodBrain Graph.")
        
        # 5. Cleanup
        shutil.move(filepath, os.path.join(PROCESSED_DIR, filename))

    print("[*] Synthesizer Loop Complete. Returning to sleep.\n")

if __name__ == "__main__":
    asyncio.run(run_synthesizer_loop())