import os
import sys
import uuid
import re
import json
import subprocess
from pymongo import MongoClient

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.ms_learn_agent import AgentFactory

# Base Class for specialized Librarians
class SpecializedLibrarian(AgentFactory):
    def __init__(self, specialization, system_prompt, node_type_prefix):
        super().__init__()
        self.specialization = specialization
        self.system_prompt = system_prompt
        self.node_type_prefix = node_type_prefix

    def process_and_ingest(self, source_url, title, raw_text):
        print(f"\n[{self.specialization}] Processing '{title}'...")
        content_snippet = raw_text[:4000]
        
        prompt = f"""You are the GodBrain {self.specialization} Librarian.
{self.system_prompt}
Output ONLY valid JSON in this exact format:
{{
    "nodes": [
        {{"id": "concept_name", "title": "Concept Name", "type": "{self.node_type_prefix}_concept", "content": "deep technical description"}}
    ],
    "edges": [
        {{"source": "concept_name_1", "target": "concept_name_2", "relationship": "related_to"}}
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

        doc_id = f"doc_{uuid.uuid4().hex[:8]}"
        self.db.nodes.update_one(
            {"_id": doc_id},
            {"$set": {"title": title, "type": f"{self.node_type_prefix}_document", "url": source_url, "content": content_snippet[:500] + "...", "specialization": self.specialization}},
            upsert=True
        )

        for n in extracted.get("nodes", []):
            n_id = str(n.get("id", "")).lower().replace(" ", "_").strip()
            if not n_id: continue
            self.db.nodes.update_one(
                {"_id": n_id},
                {"$set": {"title": n.get("title"), "type": n.get("type", f"{self.node_type_prefix}_concept"), "content": n.get("content"), "specialization": self.specialization}},
                upsert=True
            )
            self.db.edges.insert_one({"source": doc_id, "target": n_id, "relationship": "documents"})

        for e in extracted.get("edges", []):
            s_id = str(e.get("source", "")).lower().replace(" ", "_").strip()
            t_id = str(e.get("target", "")).lower().replace(" ", "_").strip()
            if s_id and t_id:
                self.db.edges.insert_one({"source": s_id, "target": t_id, "relationship": e.get("relationship", "interacts_with")})
        
        print(f"[{self.specialization}] Ingested data into GodBrain.")

# Specialized Librarians
class WindowsSRELibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Windows SRE & Optimization",
            system_prompt="Extract hardcore Windows internals: Registry hives, ETW tracing, PPL (Protected Process Light) limitations, service dependencies, power saving bypasses, and fatal system failure domains. Note specifically what cannot be done in a live OS.",
            node_type_prefix="windows"
        )

class LinuxKernelLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Linux Kernel & SRE",
            system_prompt="Extract hardcore Linux internals: cgroups, namespaces, eBPF, systemd dependencies, and VFS mappings. Identify fatal configuration mistakes.",
            node_type_prefix="linux"
        )

class AppleSiliconLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Apple Darwin & Metal",
            system_prompt="Extract XNU Kernel mechanics, Grand Central Dispatch (GCD), Metal API pipelines, and Unified Memory Architecture (UMA) specs.",
            node_type_prefix="apple"
        )

class RustLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Rust Systems Engineering",
            system_prompt="Extract Rust memory safety models, borrow checker rules, zero-cost abstractions, unsafe mechanics, and concurrency primitives.",
            node_type_prefix="rust"
        )

class NodejsLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Node.js & V8 Ecosystem",
            system_prompt="Extract Node.js Event Loop mechanics, V8 garbage collection, libuv thread pools, async I/O limitations, memory footprints, and module resolutions.",
            node_type_prefix="nodejs"
        )

class ReactLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="React Architecture",
            system_prompt="Extract React Virtual DOM reconciliation, fiber architecture, hook closures, component lifecycles, and render cycle performance bottlenecks.",
            node_type_prefix="react"
        )

class BaaSUsurperLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="BaaS Usurpers",
            system_prompt="Extract backend-as-a-service architecture details (Supabase, Firebase). Identify abstraction overheads, inefficient REST-to-SQL query generation, websocket polling bloat, and how these platforms enable bloated frontend ecosystems to bypass native backend engineering.",
            node_type_prefix="usurper"
        )

class ChromiumEnemyLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="Chromium & Electron Bloat",
            system_prompt="Extract Chromium multi-process architecture flaws, Electron IPC bridge latency, V8 memory leaks, and DOM rendering overhead. Identify exactly why Chrome-based web apps consume massive amounts of RAM and CPU compared to native executables.",
            node_type_prefix="chromium_enemy"
        )

class GeneralDevLibrarian(SpecializedLibrarian):
    def __init__(self):
        super().__init__(
            specialization="General Software Engineering",
            system_prompt="Extract core computer science concepts, design patterns, generic database structures, and high-level architecture paradigms.",
            node_type_prefix="general"
        )

# Example usage interface for the Master Control Program
if __name__ == '__main__':
    print("Librarian Guild Initialized. Ready for dispatch.")
