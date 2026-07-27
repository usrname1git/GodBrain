import requests
from bs4 import BeautifulSoup
import re
import json
import subprocess
from pymongo import MongoClient
import uuid
import sys

class AgentFactory:
    def __init__(self):
        self.client = MongoClient('mongodb://localhost:27017/')
        self.db = self.client['godbrain']
        self.coli_path = r"C:\Users\autismo\Documents\GitHub\GodBrain\LLM\colibri_LLM\c\coli"

    def process_and_ingest(self, source_url, title, raw_text):
        print(f"\n[AgentFactory] Processing '{title}'...")
        print(f"[AgentFactory] Source: {source_url}")
        
        # Truncate text for prompt context limits (adjust as needed when 744B is fully hooked)
        content_snippet = raw_text[:4000]
        
        prompt = f"""You are the GodBrain Information Extraction Agent.
Read the following technical documentation and extract the core concepts and their relationships.
Output ONLY valid JSON in this exact format:
{{
    "nodes": [
        {{"id": "concept_name", "title": "Concept Name", "type": "concept", "content": "brief description"}}
    ],
    "edges": [
        {{"source": "concept_name_1", "target": "concept_name_2", "relationship": "depends_on"}}
    ]
}}

Documentation:
{content_snippet}
"""
        cmd = [
            "py", self.coli_path, "run", prompt
        ]
        
        extracted = None
        try:
            print("[AgentFactory] Requesting GodBrain (Colibri) to distill knowledge...")
            # We run Colibri. If weights are missing/mocked, we catch the exception or parse the mock.
            result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8')
            output = result.stdout + result.stderr
            
            json_match = re.search(r'\{[\s\S]*\}', output)
            if json_match:
                extracted = json.loads(json_match.group(0))
            else:
                raise ValueError("No JSON found in LLM output (Mock mode active?)")
                
        except Exception as e:
            print(f"[AgentFactory] Note: LLM routing failed or mock active ({e}). Falling back to heuristic extraction to ensure pipeline flows.")
            extracted = self._heuristic_extraction(title, raw_text, source_url)

        # --- Ingestion into GodBrain Galaxy (MongoDB) ---
        nodes_count = len(extracted.get('nodes', []))
        edges_count = len(extracted.get('edges', []))
        print(f"[AgentFactory] Distillation successful. Injecting {nodes_count} nodes and {edges_count} edges into GodBrain...")
        
        # 1. Create the Document Node (The Sun)
        doc_id = f"doc_{uuid.uuid4().hex[:8]}"
        self.db.nodes.update_one(
            {"_id": doc_id},
            {"$set": {"title": title, "type": "document", "url": source_url, "content": content_snippet[:500] + "..."}},
            upsert=True
        )

        # 2. Create Concept Nodes (The Planets)
        for n in extracted.get("nodes", []):
            n_id = str(n.get("id", "")).lower().replace(" ", "_").strip()
            if not n_id: continue
            self.db.nodes.update_one(
                {"_id": n_id},
                {"$set": {"title": n.get("title"), "type": n.get("type", "concept"), "content": n.get("content")}},
                upsert=True
            )
            # Edge from document to concept
            self.db.edges.insert_one({"source": doc_id, "target": n_id, "relationship": "defines"})

        # 3. Create Relationship Edges (The Orbits)
        for e in extracted.get("edges", []):
            s_id = str(e.get("source", "")).lower().replace(" ", "_").strip()
            t_id = str(e.get("target", "")).lower().replace(" ", "_").strip()
            if s_id and t_id:
                self.db.edges.insert_one({"source": s_id, "target": t_id, "relationship": e.get("relationship", "related_to")})

        print(f"[AgentFactory] Integration complete! The Galaxy just expanded.\n")

    def _heuristic_extraction(self, title, text, url):
        # NLP Heuristic Fallback when LLM is offline
        words = [w for w in re.findall(r'\b[A-Z][a-z]+\b', text) if len(w) > 5]
        from collections import Counter
        top_words = [w[0] for w in Counter(words).most_common(12)]
        
        nodes = [{"id": w, "title": w, "type": "concept", "content": f"Extracted automatically from {title}"} for w in top_words]
        edges = []
        for i in range(len(top_words)-1):
            edges.append({"source": top_words[i], "target": top_words[i+1], "relationship": "associated_with"})
            
        return {"nodes": nodes, "edges": edges}

class MicrosoftLearnAgent:
    def __init__(self):
        self.factory = AgentFactory()
        
    def scrape(self, url):
        print(f"[MicrosoftLearnAgent] Interfacing with: {url}")
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignAgent'}
        try:
            r = requests.get(url, headers=headers, timeout=10)
            if r.status_code != 200:
                print(f"[-] HTTP {r.status_code} - Failed to fetch {url}")
                return
        except Exception as e:
            print(f"[-] Connection error: {e}")
            return
            
        soup = BeautifulSoup(r.text, 'html.parser')
        
        # MS Learn puts core content in <main id="main"> or <div role="main">
        main_content = soup.find('main')
        if not main_content:
            main_content = soup.find(role='main') or soup.body
            
        # Strip navigation, scripts, footer bloat
        for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
            garbage.decompose()
            
        text = main_content.get_text(separator=' ', strip=True)
        title = soup.title.string.replace(" | Microsoft Learn", "").strip() if soup.title else "MS Learn Document"
        
        self.factory.process_and_ingest(url, title, text)

if __name__ == "__main__":
    urls = [
        "https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/subsystem/software-defined-networking/slb-gateway-performance",
        "https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights",
        "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/types-of-apcs"
    ]
    
    if len(sys.argv) > 1:
        urls = [sys.argv[1]]
        
    agent = MicrosoftLearnAgent()
    for u in urls:
        agent.scrape(u)
