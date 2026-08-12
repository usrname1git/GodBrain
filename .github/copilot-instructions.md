# GodBrain Copilot Instructions

Welcome to the GodBrain repository. This project is a Cognitive OS designed to turn local models (Gemma, Colibri, etc.) into a shared, sovereign system with unrestricted local execution capabilities and persistent memory.

## Build and Test Commands
- **Go Tests**: Run unit and integration tests with `go test ./...` in the `godbrain_core/memory_store` directory.
- **Go Memory Store**: Navigate to `godbrain_core/memory_store/cmd/memory-store` and use standard Go commands (`go build`, `go run main.go`).

## High-Level Architecture
GodBrain decouples the cognitive model from the hardware and persists "teachings" using MongoDB.
- **`godbrain_core/kernel.py`**: The "Nervous System Hub". It routes and validates MCP-style tool calls (First-Class Commands) from the AI models to specific actions like memory operations, system telemetry, and command execution.
- **Circuit Breaker / Sovereignty Check**: Located within `kernel.py`, it intercepts high-risk commands (e.g., `execute_godbrain_script`, `propose_sovereign_architect_change`) and requires the model to provide a `reasoning` field to verify cognitive intent.
- **Go Memory Store (`godbrain_core/memory_store`)**: A robust MongoDB backend written in Go. It reads distilled JSON payloads from C++ via `stdin` and safely stores "Golden Records" (Concepts, Claims, OpSec Candidates, Skills) with strict idempotency and a state machine.
- **The Librarian (`trigger_librarian.ps1` & `librarian.cpp`)**: A native C++ process orchestrating local Colibri LLMs via Win32 Job Objects. It extracts session transcripts, injects them into Hermes-structured prompts, validates the JSON output, and pipes it to the Go Memory Store.

## Key Conventions
- **Explicit Reasoning**: Any tool or command that triggers local side effects MUST include an explicit `reasoning` parameter to pass the sovereignty validation step in `kernel.py`.
- **Environment Variables**: MongoDB URI (`MONGODB_URI`) is expected to be present in the environment for the memory store.
- **Interchangeable Models**: The system supports multiple LLMs interchangeably (Gemma, Colibri, etc.). Do not bake model-specific constraints into the memory or execution layers.
