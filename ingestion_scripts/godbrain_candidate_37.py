import os
import ast
import asyncio
from pathlib import Path
from godbrain_core.commands.memory import GodBrainEngine

# Quick, highly targeted AST parser for JS/TS/React codebases
# GodBrain reads the structure, not just the text.

class SourceCodeIngestor:
    def __init__(self, target_dir):
        self.target_dir = Path(target_dir)
        self.engine = GodBrainEngine()

    async def ingest_directory(self):
        print(f"[*] Commencing GodBrain AST/String extraction on {self.target_dir}")
        tasks = []
        for root, _, files in os.walk(self.target_dir):
            if 'node_modules' in root or '.git' in root or 'dist' in root or 'build' in root:
                continue

            for file in files:
                if file.endswith(('.js', '.jsx', '.ts', '.tsx')):
                    filepath = Path(root) / file
                    tasks.append(self.process_file(filepath))

        if tasks:
             await asyncio.gather(*tasks)
        print("[+] Ingestion run complete.")

    async def process_file(self, filepath):
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            # For Node.js/React we just grab the raw text and package it with structural metadata
            # We enforce chunk limits for the LLM
            CHUNK_SIZE = 5000
            chunks = [content[i:i + CHUNK_SIZE] for i in range(0, len(content), CHUNK_SIZE)]
            
            for idx, chunk in enumerate(chunks):
                payload = f"""[GODBRAIN SOURCE INGESTION]
FILE: {filepath.name}
PATH: {filepath.relative_to(self.target_dir)}
FRAMEWORK_HEURISTIC: React/Node.js Target
CHUNK: {idx+1}/{len(chunks)}

CODE_PAYLOAD:
{chunk}"""
                
                await self.engine.save_thought(
                    content=payload,
                    source=f"Automated_Source_Scanner:{filepath.name}",
                    tags=['raw-source-code', 'react-node-ingestion', 'target-analysis']
                )
            
            print(f"  [+] Ingested: {filepath.relative_to(self.target_dir)}")

        except Exception as e:
            print(f"  [!] Failed to read {filepath}: {e}")

if __name__ == "__main__":
    import sys
    # Example usage: python source_ingestor.py C:\Path\To\Some\React\App
    target = sys.argv[1] if len(sys.argv) > 1 else "./dummy_react_app"
    asyncio.run(SourceCodeIngestor(target).ingest_directory())