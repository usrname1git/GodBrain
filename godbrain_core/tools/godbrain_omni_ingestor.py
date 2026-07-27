import os
import asyncio
from pathlib import Path
from godbrain_core.commands.memory import GodBrainEngine

class OmniFilthIngestor:
    def __init__(self):
        self.engine = GodBrainEngine()

    async def ingest_windows_xaml_horror(self):
        print("[*] Commencing XAML Horror Show Extraction from Windows SystemApps...")
        # This is where Windows 11 Start Menu, Search, and UWP filth resides
        target_dir = Path(r"C:\Windows\SystemApps")
        
        if not target_dir.exists():
            print("[!] Cannot access SystemApps directory. Permissions may be denied.")
            return

        xaml_files = []
        for root, _, files in os.walk(target_dir):
            for file in files:
                if file.endswith('.xaml') or file.endswith('.xml'):
                    xaml_files.append(Path(root) / file)
                    
        print(f"[*] Found {len(xaml_files)} XAML/XML files in SystemApps.")
        
        # We process a small batch to prove the capability without hanging the terminal
        tasks = []
        count = 0
        for filepath in xaml_files:
            if "StartMenuExperienceHost" in str(filepath) or "ShellExperienceHost" in str(filepath):
                tasks.append(self._process_local_file(filepath, "XAML_Horror"))
                count += 1
                if count >= 10: # Limit to 10 core shell files for the injection test
                    break
            
        if tasks:
            await asyncio.gather(*tasks)
        print("[+] XAML Shell Ingestion Complete.")

    async def _process_local_file(self, filepath, tag_name):
        try:
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
            except UnicodeDecodeError:
                with open(filepath, 'r', encoding='utf-16') as f:
                    content = f.read()

            if not content.strip(): return

            CHUNK_SIZE = 5000
            chunks = [content[i:i + CHUNK_SIZE] for i in range(0, len(content), CHUNK_SIZE)]
            
            for idx, chunk in enumerate(chunks):
                payload = f"""[GODBRAIN XAML SUBVERSION INGESTION]
FILE: {filepath.name}
PATH: {filepath}
CHUNK: {idx+1}/{len(chunks)}

XAML_PAYLOAD:
{chunk}"""
                await self.engine.save_thought(
                    content=payload,
                    source=f"OmniIngestor:{filepath.name}",
                    tags=[tag_name.lower(), 'windows-internal-ui', 'xaml-subversion']
                )
            print(f"  [+] Ingested: {filepath.name} from {filepath.parent.name}")
        except Exception as e:
            # Soft fail for DACL locked files
            pass

    async def prime_web_documentation_agents(self):
        print("[*] Priming Playwright Web Agents for React/Node.js Documentation...")
        
        # We lock in the directive for the Playwright spiders to hunt down the docs
        targets = {
            "React": "https://react.dev/reference/react",
            "Node.js": "https://nodejs.org/docs/latest/api/"
        }
        
        for name, url in targets.items():
            content = f"""[GODBRAIN AUTOMATED SPIDER DIRECTIVE: {name.upper()}]
SOURCE: Father Autismo
TOPIC: Total ingestion of {name} official documentation.

DIRECTIVE: The Playwright agent must crawl {url}. It will aggressively bypass hydration layers, extract the raw text, AST signatures, and code examples, and pipe them directly into GodBrain. We absorb the documentation to automate its obsolescence."""
            
            await self.engine.save_thought(
                content=content,
                source=f'{name}_Docs_Spider',
                tags=[f'{name.lower()}-docs', 'framework-spider-directive']
            )
            print(f"  [+] Hard-coded spider ingestion directive for {name}.")

async def run_omniverse():
    ingestor = OmniFilthIngestor()
    await ingestor.prime_web_documentation_agents()
    await ingestor.ingest_windows_xaml_horror()

if __name__ == "__main__":
    asyncio.run(run_omniverse())