import os
import shutil
import asyncio
import subprocess
from pathlib import Path
from godbrain_core.commands.memory import GodBrainEngine
import httpx

# The GodBrain GitHub Omni-Ingestor
# Clones, scans, filters noise, and maps high-value architectural logic.

LLM_API_URL = "http://127.0.0.1:8080/v1/chat/completions"

class GithubOmniIngestor:
    def __init__(self):
        self.engine = GodBrainEngine()

    async def synthesize_value(self, file_path, content_chunk):
        # We use GodBrain's local LLM to act as a filter. If the code is generic boilerplate, it ignores it.
        # If it's novel Rust/C++/React architecture, it extracts the value.
        system_prompt = (
            "You are GodBrain's Architectural Reconnaissance Filter. "
            "Scan this code chunk for high-value optimization patterns, novel logic, or advanced Rust/C++/JS concepts. "
            "If it's generic boilerplate, configuration, or trivial logic, reply ONLY with 'IGNORE'. "
            "If it contains valuable mechanics or architecture, explain exactly WHY it is valuable in 3 sentences."
        )
        payload = {
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": f"File: {file_path}\n\nContent:\n{content_chunk}"}
            ],
            "temperature": 0.2,
            "max_tokens": 500
        }
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(LLM_API_URL, json=payload)
                resp.raise_for_status()
                res = resp.json()["choices"][0]["message"]["content"].strip()
                if "IGNORE" in res[:15]:
                    return None
                return res
        except Exception as e:
            return None

    async def ingest_repo(self, repo_url):
        print(f"[*] Commencing GodBrain GitHub Omni-Ingestion on: {repo_url}")
        repo_name = repo_url.rstrip("/").split("/")[-1].replace(".git", "")
        target_dir = Path(f"./salvaged_repos/{repo_name}")
        
        if not target_dir.parent.exists():
            target_dir.parent.mkdir()

        if not target_dir.exists():
            print(f"[*] Cloning repository via Git...")
            try:
                subprocess.run(['git', 'clone', '--depth', '1', repo_url, str(target_dir)], check=True)
            except subprocess.CalledProcessError:
                print(f"[!] Git clone failed for {repo_url}")
                return
        else:
            print(f"[*] Target directory {target_dir} already exists. Scanning current state.")
        
        valid_exts = {'.rs', '.cpp', '.c', '.hpp', '.h', '.ts', '.tsx', '.py', '.js', '.jsx', '.go', '.mod'}
        tasks = []
        
        print("[*] Filtering noise and targeting core logic files...")
        for root, _, files in os.walk(target_dir):
            # Exclude cancer directories
            if any(x in root for x in ['node_modules', '.git', 'target', 'build', 'dist', 'vendor']):
                continue
            for file in files:
                ext = Path(file).suffix
                if ext in valid_exts:
                    filepath = Path(root) / file
                    tasks.append(self.process_file(filepath, repo_url))
        
        print(f"[*] Found {len(tasks)} potential targets. Routing through neural filter...")
        
        # Batch execute so we don't DDoS the local LLM host
        for i in range(0, len(tasks), 5):
            await asyncio.gather(*tasks[i:i+5])

        print(f"[+] GitHub Synchronization Complete for {repo_name}.")

    async def process_file(self, filepath, repo_url):
        try:
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
            except UnicodeDecodeError:
                with open(filepath, 'r', encoding='utf-16') as f:
                    content = f.read()

            if len(content) < 100: 
                return # Ignore trivial length files
            
            # Sample the core of the file (first 4000 chars) for recon
            chunk = content[:4000]
            analysis = await self.synthesize_value(filepath.name, chunk)
            
            if analysis:
                payload = f"""[GODBRAIN GITHUB SALVAGE: {repo_url}]
FILE: {filepath.name}
FRAMEWORK/LANGUAGE: {filepath.suffix}
ARCHITECTURAL VALUE:
{analysis}

RAW NOVELTY SNIPPET:
{chunk[:1500]}..."""
                
                await self.engine.save_thought(
                    content=payload,
                    source=f"GithubSalvage:{filepath.name}",
                    tags=['github-salvage', filepath.suffix.replace('.', ''), 'architectural-recon']
                )
                print(f"  [+] HIGH-VALUE ARCHITECTURE IDENTIFIED & INGESTED: {filepath.name}")
            else:
                pass # Filtered out as noise
        except Exception as e:
            print(f"  [!] Processing failed for {filepath.name}: {e}")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        asyncio.run(GithubOmniIngestor().ingest_repo(sys.argv[1]))
    else:
        print("Usage: python godbrain_github_ingestor.py <github_url>")