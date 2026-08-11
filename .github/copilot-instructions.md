# GodBrain Copilot Instructions

Welcome to the GodBrain repository. This project is a Cognitive OS designed to turn local models (Gemma, Colibri, etc.) into a shared, sovereign system with unrestricted local execution capabilities and persistent memory.

## Build and Test Commands
- **Python Tests**: Run individual tests directly with Python, e.g., `python test_neo4j.py` or `python test_neo4j_norouting.py`.
- **Go Memory Engine**: Navigate to `godbrain_core/memory_engine` and use standard Go commands (`go build`, `go run main.go`).
- **Root Go Router** (`main.go`): Buildable from the repo root with `go build .` (module `godbrain`, `go.mod`/`go.sum` at the repo root).
- **C++ Kernel** (`godbrain_core/cpp_kernel`): Build `main.cpp`/`kernel.cpp` (and friends) with MSVC (`cl /std:c++17 /EHsc ...`) or an equivalent compiler.

## High-Level Architecture
GodBrain decouples the cognitive model from the hardware and persists "teachings" using Neo4j and MongoDB.
- **`godbrain_core/cpp_kernel/kernel.cpp` + `main.cpp`**: The "Nervous System Hub" (native C++, not Python). It routes and validates MCP-style tool calls (First-Class Commands) from the AI models to specific actions like memory operations, system telemetry, and command execution, and hosts the HTTP API.
- **Circuit Breaker / Sovereignty Check**: Located in `godbrain_core/cpp_kernel/kernel.cpp` (`GodBrainKernel::validate_sovereignty`), it intercepts high-risk commands (e.g., `execute_godbrain_script`, `propose_sovereign_architect_change`) and requires the model to provide a non-empty `reasoning` field to verify cognitive intent.
- **Go Memory Engine (`godbrain_core/memory_engine`)**: A robust Neo4j client written in Go (handling routing better than Python). It reads distilled JSON payloads via `stdin` and writes the "Golden Records" (Concepts, OpSec rules, Summaries) into the Aura Graph.
- **The Librarian (`trigger_librarian.ps1` & `godbrain_core/cpp_tools/librarian.cpp`)**: Extracts the current GitHub Copilot CLI session transcripts, compiles checkpoints, and feeds them into the native C++ Librarian binary (`librarian.exe <session_id> --file <transcript_path>`) for distillation, which in turn forwards the golden record to the Go Memory Engine.

## Key Conventions
- **Explicit Reasoning**: Any tool or command that triggers local side effects MUST include a non-empty `reasoning` parameter to pass the sovereignty validation step in `godbrain_core/cpp_kernel/kernel.cpp`.
- **API Authentication**: The C++ Kernel HTTP API (`godbrain_core/cpp_kernel`, `:8083`) binds to `127.0.0.1` only and only accepts CORS requests from trusted loopback UI origins (`localhost`/`127.0.0.1` on any port, or Tauri webview origins) — never a wildcard. Any request carrying `command_type` (i.e. invoking a privileged kernel command) additionally requires an `Authorization: Bearer <token>` header matching the `GODBRAIN_API_TOKEN` environment variable; requests without a valid token are rejected with 401/403. Ordinary unauthenticated local read/chat routes (e.g. plain `/api/chat` messages without `command_type`, `/api/graph`, `/api/test`) are unaffected. The powerful arbitrary-command capability itself is preserved — it is gated, not removed.
- **Environment Variables**: Neo4j credentials (`NEO4J_URI`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`) are expected to be present in the environment. Tests sometimes pull these directly from the Windows Registry to bypass process environment limitations. The kernel API token (`GODBRAIN_API_TOKEN`) must also be set in the environment before privileged commands can be used. Path overrides such as `GODBRAIN_COLIBRI_PATH`, `GODBRAIN_FRONTEND_DIR`, `GODBRAIN_SNAPSHOT_PATH`, `GODBRAIN_MEMORY_ENGINE_PATH`, and `GODBRAIN_LIBRARIAN_PATH` let each native component locate its dependencies without any hardcoded, user-specific absolute path (e.g. `C:\Users\YourUsername\...`).
- **Interchangeable Models**: The system supports multiple LLMs interchangeably (Gemma, Colibri, etc.). Do not bake model-specific constraints into the memory or execution layers.
