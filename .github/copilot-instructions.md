# GodBrain Copilot Instructions

Welcome to the GodBrain repository. This project is a Cognitive OS designed to turn local models (Gemma, Colibri, etc.) into a shared, sovereign system with unrestricted local execution capabilities and persistent memory.

## Build and Test Commands
- **Python Tests**: Run individual tests directly with Python, e.g., `python test_neo4j.py` or `python test_neo4j_norouting.py`.
- **Go Memory Engine**: Navigate to `godbrain_core/memory_engine` and use standard Go commands (`go build`, `go run main.go`).

## High-Level Architecture
GodBrain decouples the cognitive model from the hardware and persists "teachings" using Neo4j and MongoDB.
- **`godbrain_core/kernel.py`**: The "Nervous System Hub". It routes and validates MCP-style tool calls (First-Class Commands) from the AI models to specific actions like memory operations, system telemetry, and command execution.
- **Circuit Breaker / Sovereignty Check**: Located within `kernel.py`, it intercepts high-risk commands (e.g., `execute_godbrain_script`, `propose_sovereign_architect_change`) and requires the model to provide a `reasoning` field to verify cognitive intent.
- **Go Memory Engine (`godbrain_core/memory_engine`)**: A robust Neo4j client written in Go (handling routing better than Python). It reads distilled JSON payloads from Python via `stdin` and writes the "Golden Records" (Concepts, OpSec rules, Summaries) into the Aura Graph.
- **The Librarian (`trigger_librarian.ps1` & `librarian.py`)**: Extracts the current GitHub Copilot CLI session transcripts, compiles checkpoints, and feeds them into the system for distillation.

## Key Conventions
- **Explicit Reasoning**: Any tool or command that triggers local side effects MUST include an explicit `reasoning` parameter to pass the sovereignty validation step in `kernel.py`.
- **Environment Variables**: Neo4j credentials (`NEO4J_URI`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`) are expected to be present in the environment. Tests sometimes pull these directly from the Windows Registry to bypass process environment limitations.
- **Interchangeable Models**: The system supports multiple LLMs interchangeably (Gemma, Colibri, etc.). Do not bake model-specific constraints into the memory or execution layers.
