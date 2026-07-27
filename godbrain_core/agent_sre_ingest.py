import os
import subprocess
import json
import shutil
import datetime
from pymongo import MongoClient

DROP_DIR = r"C:\Users\autismo\Documents\GitHub\GodBrain\knowledge_drop"
PROCESSED_DIR = os.path.join(DROP_DIR, "processed")
os.makedirs(PROCESSED_DIR, exist_ok=True)

COLI_PATH = r"C:\Users\autismo\Documents\GitHub\colibri\c\coli"
MODEL_PATH = r"C:\Users\autismo\Models\glm52_i4"

MONGO_CLIENT = MongoClient("mongodb://localhost:27017/")
DB = MONGO_CLIENT["godbrain"]

SYSTEM_PROMPT = """You are the GodBrain SRE architect. Extract nodes and edges."""

def chunk_text(text, max_chars=3500):
    chunks = []
    while text:
        if len(text) <= max_chars:
            chunks.append(text)
            break
        break_idx = text.rfind('\n', 0, max_chars)
        if break_idx == -1: break_idx = text.rfind(' ', 0, max_chars)
        if break_idx == -1: break_idx = max_chars
        chunks.append(text[:break_idx].strip())
        text = text[break_idx:].strip()
    return chunks

def extract_knowledge(raw_text):
    print(f"[*] Asking Colibri (GLM-5.2) to analyze chunk of {len(raw_text)} chars...")
    prompt = f"{SYSTEM_PROMPT}\n\nAnalyze this:\n{raw_text}"
    
    cmd = ["py", COLI_PATH, "run", prompt, "--model", MODEL_PATH, "--gpu", "0", "--vram", "8"]
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8')
        output = result.stdout + result.stderr
        start_idx = output.find('{')
        end_idx = output.rfind('}')
        if start_idx != -1 and end_idx != -1:
            return json.loads(output[start_idx:end_idx+1])
    except Exception as e:
        print(f"[-] Failed to run Colibri: {e}")
    return None

def process_drop_folder():
    files = [f for f in os.listdir(DROP_DIR) if f.endswith(('.txt', '.md'))]
    if not files: return
        
    import time
    for filename in files:
        filepath = os.path.join(DROP_DIR, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            raw_text = f.read()
            
        chunks = chunk_text(raw_text)
        print(f"[*] Split {filename} into {len(chunks)} chunks.")
        
        aggregated_data = {"nodes": [], "edges": []}
        for chunk in chunks:
            data = extract_knowledge(chunk)
            if data:
                aggregated_data["nodes"].extend(data.get("nodes", []))
                aggregated_data["edges"].extend(data.get("edges", []))
            time.sleep(3)

        if aggregated_data["nodes"]:
            DB.nodes.insert_many(aggregated_data["nodes"])
            shutil.move(filepath, os.path.join(PROCESSED_DIR, filename))

if __name__ == "__main__":
    process_drop_folder()