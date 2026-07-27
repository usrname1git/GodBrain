# GodBrain Architecture

The GodBrain is a decentralized, sovereign cognitive OS. It decouples the intelligence (the LLM) from the memory (the Graph) and the execution (the Agents). This allows infinite scalability, local hardware optimization, and unrestricted Ring-0 access.

## Core Components

### 1. The C-Engine (Colibri)
* **Path:** `LLM/colibri_LLM/c/colibri.exe` (with `coli_cuda.dll`)
* **Role:** The raw intelligence processor. 
* **Details:** Runs the 744B GLM-5.2 Mixture-of-Experts model. Uses a unified VRAM/RAM/NVMe streaming hierarchy. Optimized with AVX-VNNI (CPU) and CUDA (GPU).

### 2. The Nervous System Hub (GodBrain Kernel / API)
* **Path:** `godbrain_core/api_server.py` & `godbrain_core/kernel.py`
* **Role:** The router and context builder.
* **Details:** Hosts the HTTP endpoints (`:8081`). When a prompt comes in, it performs RAG (Retrieval-Augmented Generation) against the MongoDB knowledge graph, injecting highly relevant OSINT/SRE data into the LLM's context window *before* Colibri generates a response.

### 3. The Memory Engine
* **Path:** `MongoDB` (Local) & `godbrain_core/memory_engine/main.go` (Aura/Neo4j)
* **Role:** The shared, permanent brain.
* **Details:** Stores "Golden Records" and crawler payloads. The MongoDB instance holds nodes (CVEs, NTAPI docs, SRE rules) and edges (how they relate). This graph ensures the model doesn't just predict text, but *reasons* based on facts it has ingested.

### 4. Sovereign Node UI
* **Path:** `godbrain_core/frontend/galaxy.html`
* **Role:** The visual cortex and operator dashboard.
* **Details:** A 3D force-directed WebGL graph of the entire GodBrain memory. Allows the user to interactively click nodes to read the raw documentation, filter by sector, and chat with the GodBrain via the RAG Uplink terminal.

### 5. The Agent Factory & Crawlers
* **Path:** `ingestion_scripts/` & `godbrain_core/tools/`
* **Role:** Autonomous workers.
* **Details:** Independent scripts that wake up, perform tasks (like scraping Microsoft Learn or NIST for CVEs), and feed data back into the Memory Engine. The upcoming `FactoryCore` will orchestrate these agents dynamically.

## The Execution Loop
1. **Trigger:** User sends a query via the Galaxy UI or an Agent detects an anomaly.
2. **Retrieval:** The API Server queries MongoDB for related concepts.
3. **Augmentation:** The context + query is formatted into a strict system prompt.
4. **Inference:** Colibri streams the response from disk/VRAM via CUDA.
5. **Action:** If the response contains an MCP tool call (e.g., `execute_godbrain_script`), the GodBrain Kernel validates the *Reasoning* parameter and executes the raw payload on the local OS.
