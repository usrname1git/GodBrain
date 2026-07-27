import requests
from bs4 import BeautifulSoup
import time
from urllib.parse import urljoin, urlparse
from pymongo import MongoClient
import sys
import os

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

from godbrain_core.tools.ms_learn_agent import MicrosoftLearnAgent, AgentFactory
import re
import json
import subprocess
import uuid

# Subclass the AgentFactory to inject SRE GOD specific prompts
class SREGodFactory(AgentFactory):
    def process_and_ingest(self, source_url, title, raw_text):
        print(f"\n[SREGodFactory] Processing '{title}'...")
        content_snippet = raw_text[:4000]
        
        # SRE GOD Prompt - focusing on failure states, registry, and kernel APIs
        prompt = f"""You are the GodBrain SRE Extraction Agent.
Read the following hardcore Windows Internals documentation.
Extract the low-level system concepts, failure domains, critical registry keys, or kernel APIs.
Output ONLY valid JSON in this exact format:
{{
    "nodes": [
        {{"id": "concept_name", "title": "Concept Name", "type": "kernel_concept", "content": "deep technical description"}}
    ],
    "edges": [
        {{"source": "concept_name_1", "target": "concept_name_2", "relationship": "hooks_into"}}
    ]
}}

Documentation:
{content_snippet}
"""
        cmd = ["py", self.coli_path, "run", prompt]
        
        extracted = None
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8')
            output = result.stdout + result.stderr
            json_match = re.search(r'\{[\s\S]*\}', output)
            if json_match:
                extracted = json.loads(json_match.group(0))
            else:
                raise ValueError("No JSON found")
        except Exception as e:
            extracted = self._heuristic_extraction(title, raw_text, source_url)

        nodes_count = len(extracted.get('nodes', []))
        edges_count = len(extracted.get('edges', []))
        print(f"[SREGodFactory] Injected {nodes_count} Kernel/SRE nodes and {edges_count} edges.")
        
        doc_id = f"doc_{uuid.uuid4().hex[:8]}"
        self.db.nodes.update_one(
            {"_id": doc_id},
            {"$set": {"title": title, "type": "sre_document", "url": source_url, "content": content_snippet[:500] + "..."}},
            upsert=True
        )

        for n in extracted.get("nodes", []):
            n_id = str(n.get("id", "")).lower().replace(" ", "_").strip()
            if not n_id: continue
            self.db.nodes.update_one(
                {"_id": n_id},
                {"$set": {"title": n.get("title"), "type": n.get("type", "kernel_concept"), "content": n.get("content")}},
                upsert=True
            )
            self.db.edges.insert_one({"source": doc_id, "target": n_id, "relationship": "documents"})

        for e in extracted.get("edges", []):
            s_id = str(e.get("source", "")).lower().replace(" ", "_").strip()
            t_id = str(e.get("target", "")).lower().replace(" ", "_").strip()
            if s_id and t_id:
                self.db.edges.insert_one({"source": s_id, "target": t_id, "relationship": e.get("relationship", "interacts_with")})

class SREGodHarvester(MicrosoftLearnAgent):
    def __init__(self):
        self.factory = SREGodFactory()

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']
visited = set(doc['url'] for doc in db.visited_urls.find({}, {"url": 1}))

# THE DARK ARTS: Sysinternals, WinDbg, ETW, and NT Kernel Memory
queue = [
    "https://learn.microsoft.com/en-us/sysinternals/downloads/sysinternals-utilities",
    "https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/getting-started-with-windbg",
    "https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing",
    "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/memory-management",
    "https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags"
]

agent = SREGodHarvester()

print("======================================================")
print("[GodBrain] Booting SRE GOD HARVESTER (Kernel & Sysinternals)")
print("======================================================")

while True:
    if not queue:
        print("[SREGod] Queue empty. Reseeding...")
        queue.extend([
            "https://learn.microsoft.com/en-us/sysinternals/downloads/sysinternals-utilities",
            "https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/getting-started-with-windbg",
            "https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing",
            "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/memory-management",
            "https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags"
        ])
        time.sleep(10)
        
    current_url = queue.pop(0).split('#')[0]
    if current_url in visited: continue
        
    print(f"\n[SREGod] Target Locked: {current_url}")
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0 GodBrain/SREGodCrawler'}
        r = requests.get(current_url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            main_content = soup.find('main') or soup.find(role='main') or soup.body
            for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
                garbage.decompose()
                
            text = main_content.get_text(separator=' ', strip=True)
            title = soup.title.string.replace(" | Microsoft Learn", "").strip() if soup.title else "Kernel Doc"
            
            agent.factory.process_and_ingest(current_url, title, text)
            
            db.visited_urls.insert_one({"url": current_url})
            visited.add(current_url)
            
            new_links = 0
            for a in soup.find_all('a', href=True):
                href = a['href']
                full_url = urljoin(current_url, href).split('#')[0]
                parsed = urlparse(full_url)
                
                # ONLY scrape the hardcore stuff
                if parsed.netloc == "learn.microsoft.com" and ("/sysinternals/" in href or "/debugger/" in href or "/etw/" in href or "/kernel/" in href):
                    if full_url not in visited and full_url not in queue:
                        queue.append(full_url)
                        new_links += 1
                        
            print(f"[SREGod] Discovered {new_links} new Kernel/Debug nodes. Queue: {len(queue)}")
            
    except Exception as e:
        print(f"[-] SREGod error on {current_url}: {e}")
        
    time.sleep(2)
