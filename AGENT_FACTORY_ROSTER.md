# GodBrain Agent Factory Roster

To build an autonomous, self-replicating "Agent Factory," we need a hierarchy. The root AI (The Architect) evaluates a high-level goal and spawns specialized sub-agents with specific contexts, axioms, and tool permissions to execute the micro-tasks.

Here is the proposed roster of specialized sovereign agents we need to build for the GodBrain to reach full autonomy:

## 1. The Architect (Root Node)
* **Purpose:** The high-level planner and orchestrator.
* **Function:** Analyzes the user's ultimate goal, breaks it down into a dependency tree, and spawns the sub-agents below with strict, scoped system prompts.
* **Capabilities:** Process spawning, LLM session management, task dependency tracking.

## 2. The Surgeon (Execution & Ring-0 Manipulator)
* **Purpose:** The only agent allowed to pull the trigger on the OS.
* **Function:** Executes PowerShell, edits the Windows Registry, stops/starts services, and manipulates ETW streams. 
* **Axiom:** Requires explicit *Reasoning* and *Rollback Plans* before making any changes. Never acts without Architect approval.
* **Tools:** `execute_godbrain_script`, `wsudo`.

## 3. The Watcher (OSINT & CVE Ingestor)
* **Purpose:** The paranoid security researcher.
* **Function:** Constantly scrapes NIST, GitHub security advisories, and darknet/sysinternals forums. Evaluates new vulnerabilities against the local machine's specs.
* **Tools:** Web Search, Python crawlers (`osint_scraper.py`, `cve_ingestor.py`).

## 4. The Librarian (Graph DB Archivist)
* **Purpose:** The memory manager.
* **Function:** Constantly runs in the background reading the MongoDB/Neo4j graphs. Deduplicates overlapping nodes, generates embeddings, and creates summary nodes (e.g., combining 10 articles on Windows Telemetry into one "Master Telemetry" node).
* **Tools:** MongoDB/Neo4j full read/write, Semantic clustering.

## 5. The Forge (C/CUDA Optimizer)
* **Purpose:** The engine mechanic.
* **Function:** Profiles the Colibri C-engine, adjusts VRAM pinning budgets (`CUDA_EXPERT_GB`), tweaks Makefile flags, and recompiles the engine (`coli_cuda.dll`) when hardware changes or new optimizations are found.
* **Tools:** `make`, `gcc`, `nvcc`, local filesystem read/write.

## 6. The Interceptor (Network & Telemetry Auditor)
* **Purpose:** The firewall.
* **Function:** Monitors active TCP/UDP connections and ETW network events. If a process (like `utcsvc` DiagTrack) attempts to phone home to Microsoft, the Interceptor maps the IP, alerts The Architect, and drafts a firewall/DNS block rule for The Surgeon to execute.
* **Tools:** Packet sniffing, ETW tracing, `netstat`.

---

**Next Steps for the Factory:**
1. Create a `FactoryCore` Python daemon.
2. Define the JSON schemas for how The Architect passes state to the sub-agents.
3. Hook the sub-agents into the Colibri engine using the API we just built.

## 7. The Oracle (Market Arbitrageur & Predictor)
* **Purpose:** The real-time opportunity sniper.
* **Function:** Ingests live data streams (e.g., Polymarket odds, weather APIs, real-time news) to find mathematical certainties and arbitrage opportunities. For example, exploiting delayed odds adjustments in prediction markets where the outcome is already physically guaranteed (like waiting until 1 minute left on a localized weather event).
* **Tools:** Live API polling, Web3/Crypto execution, statistical risk analysis, low-latency execution engines.
