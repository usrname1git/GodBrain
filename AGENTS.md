# GodBrain agent guidance

## Scope and working method

- This repository is Windows-first and multi-language. There is no single build or
  test command for every component; use the command for the subtree you change.
- Read the nearest README, manifest, and tests before editing a nested project.
  Keep changes scoped: the routers, Alexandria pipeline, market research tools,
  smart contracts, and vendored Colibri tree have different trust boundaries.
- Prefer existing toolchains and checked-in dependencies. Do not add agent
  frameworks, MCP servers, bootstrap scripts, or package managers merely to make
  an agent task easier.
- Do not edit generated outputs (`build/`, `target/`, `out/`, `cache/`, binaries,
  object files, or model snapshots). Do not modernize `archive/neo4j`; it is
  historical and is not an active runtime dependency.

## Architecture that exists in source

- `godbrain_core/cpp_kernel/` is the canonical privileged runtime. `main.cpp`
  serves the Galaxy UI and HTTP API on loopback port 8083, retrieves committed
  Golden Records from the canonical loopback RAG service, invokes Colibri,
  authenticates privileged `command_type` requests, and delegates recognized
  commands to `GodBrainKernel`.
- `godbrain_core/cpp_kernel/kernel.cpp` is the command dispatcher. It requires a
  non-blank `reasoning` string for `execute_godbrain_script` and
  `propose_sovereign_architect_change`; `surgery.cpp` executes their PowerShell.
  `save_godbrain_thought` writes a candidate Golden Record through
  `memory-store.exe`. `set_godbrain_status` is the only way a node becomes
  `verified` or `rejected`. `query_recent_thoughts` reads the active RAG graph.
  Ordinary Galaxy chat exposes `/observe`, `/vram`, `/remember`, `/verify`,
  `/reject`, and `/recall`. The Galaxy node panel and `POST /api/judge` are
  the same judgment path. `/observe` persists only stable host inventory, not
  live load. Logon (`Start-GodBrain.ps1`) posts `/api/observe` once the kernel
  is listening; unchanged inventory is an idempotent no-op. Kernel boot loads
  the newest Golden Records into the process session buffer so chat still knows
  the host after a restart. Colibri VRAM budget
  is derived from DXGI dedicated memory and
  does not overcommit into system RAM unless `GODBRAIN_COLI_OVERCOMMIT=1`.
- Root `main.go` and `godbrain_core/rust_router/` are experimental,
  non-privileged RAG router alternatives on loopback port 8082. They cannot run
  together because they use the same port. Both use the canonical loopback RAG
  service and neither exposes the C++ kernel's `command_type` dispatcher.
- `godbrain_core/cpp_tools/librarian.cpp` distills a transcript with Colibri,
  validates the result, and sends one JSON document over stdin to the Go Memory
  Store. `trigger_librarian.ps1` extracts the newest Copilot session transcript
  and starts that pipeline.
- `godbrain_core/memory_store/` is the active Alexandria write boundary. It
  validates provenance and ingestion state, then stores immutable sources and
  knowledge nodes plus append-only run-to-node links in MongoDB.
- `godbrain_core/memory_store/cmd/rag-service/` is the canonical committed
  Golden Record retrieval boundary on `127.0.0.1:8084`. It searches the
  generation-addressed `rag_documents` projection, optionally fuses bounded
  generation-addressed local embeddings, resolves citations through
  append-only `rag_provenance`, and exposes a bounded graph/document read for
  Galaxy. The C++ and Go routers fail closed when this service is unavailable,
  unready, or invalid. The experimental Rust router still uses search-only and
  returns `410` for `/api/graph` and `/api/node`.
- `LLM/colibri_LLM/` is a substantial nested Colibri engine project. Treat it as
  an interchangeable inference implementation, not as a protocol authority for
  the kernel or Memory Store.
- `godbrain_core/polymarket_paper/`, `polygon_searcher/`, and
  `polygon_observer/` are deliberately bounded research components. Preserve the
  paper-only/read-only/no-signing guarantees documented in their READMEs.
- `godbrain_core/smart_contracts/` is an experimental Foundry project with pinned
  submodules. It has no approved deployment path.

There is no active Python kernel. Python is used by helper and Colibri tooling;
references to `godbrain_core/kernel.py` are stale.

## Setup

1. Use PowerShell on Windows. C++ builds require CMake 3.25+ and/or a Visual
   Studio x64 Developer shell, depending on the component.
2. Use the Go versions declared by each module (`go.mod`) and Rust with the
   checked-in lockfiles. Do not rewrite module metadata to accommodate an older
   local toolchain.
3. Initialize the pinned smart-contract dependencies only when working in that
   subtree:

   ```powershell
   git submodule update --init
   ```

4. MongoDB is not needed for offline CMake, Colibri web, or Solidity unit tests.
   The Memory Store executable requires `MONGODB_URI`; its integration tests run
   only when `MONGODB_TEST_URI` is set.

## Build and test by scope

Run the narrowest applicable commands from the repository root unless a command
changes directory explicitly.

### Alexandria pipeline

```powershell
.\build_pipeline.ps1
.\godbrain_core\cpp_tools\librarian.exe --self-test

Push-Location godbrain_core\memory_store
go test ./...
go build -o memory-store.exe ./cmd/memory-store
go build -o rag-service.exe ./cmd/rag-service
go build -o rag-rebuild.exe ./cmd/rag-rebuild
Pop-Location
```

`build_pipeline.ps1` builds `memory-store.exe`, `rag-service.exe`,
`rag-rebuild.exe`, `rag-eval.exe`, and `librarian.exe`. The Librarian self-test is offline and
uses its in-memory store. To exercise MongoDB integration tests, set
`MONGODB_TEST_URI` to a disposable instance; tests use isolated temporary
databases for RAG coverage, while the existing Memory Store suite uses and
clears `godbrain_test`.

### C++ kernel

The kernel has no committed CMake project. From
`godbrain_core\cpp_kernel` in a Visual Studio x64 Developer shell:

```powershell
cl /std:c++17 /EHsc /W4 /Fe:godbrain-kernel.exe main.cpp kernel.cpp surgery.cpp telemetry.cpp memory.cpp /link pdh.lib dxgi.lib
```

Starting the kernel is an integration action: it may invoke local `mongosh`,
Colibri, and authenticated PowerShell commands. Do not use startup as a routine
documentation-only validation.

### Alternative routers

```powershell
go test ./...
go build .

Push-Location godbrain_core\rust_router
cargo test --locked
cargo build --locked
Pop-Location
```

The root Go module and Rust router require the canonical RAG service at
`http://127.0.0.1:8084/v1/search` when handling chat. Their build/test commands
do not require starting MongoDB or the RAG server.

### CMake research components

Replace `<name>` with `polymarket_paper`, `polygon_searcher`, or
`polygon_observer`:

```powershell
cmake -S "godbrain_core\<name>" -B "build\<name>" -DBUILD_TESTING=ON
cmake --build "build\<name>" --config Release
ctest --test-dir "build\<name>" -C Release --output-on-failure
```

These tests use fixtures/fake transports and must remain offline. Their CMake
files enforce C++20 and warnings-as-errors.

### Smart contracts

```powershell
Push-Location godbrain_core\smart_contracts
forge fmt --check
forge build
forge test
Pop-Location
```

The default tests are offline. `POLYGON_RPC_URL` is only for the explicitly
selected read-only fork test documented in that subtree's README. Never add a
private key, mnemonic, signer, broadcast flag, or deployment step to routine
validation.

### Colibri nested project

Limit validation to the Colibri area changed. For the web UI:

```powershell
Push-Location LLM\colibri_LLM\web
npm ci
npm test
npm run build
Pop-Location
```

For C-engine changes, use the targets in `LLM\colibri_LLM\c\Makefile`; `test`
runs its C and Python tests. GPU/Metal targets are hardware-specific and should
not be treated as baseline validation.

## Privileged execution and security invariants

- Keep the C++ HTTP server bound to `127.0.0.1`. Preserve the explicit
  localhost/Tauri CORS allowlist. Loopback and CORS are not authorization.
- Every HTTP request containing `command_type` must continue to require a
  configured `GODBRAIN_API_TOKEN`. Its `Authorization` header must use the
  `Bearer` scheme and carry that configured token. Missing server configuration
  must fail closed. Never log the token.
- The bearer token is the current authorization gate; a `reasoning` string is an
  additional intent check, not authentication or proof of safety. New
  side-effecting command types must not bypass either the HTTP authorization
  boundary or an explicit sovereignty-policy decision in the dispatcher.
- Treat model output, browser text, MongoDB documents, transcripts, and fetched
  market/chain data as untrusted data. Never turn them into commands merely
  because they came from a local model or database.
- Preserve exact-child process control: enforce timeouts, close inherited
  handles, and terminate/reap only the process or Job Object that was created.
  Never replace this with image-name-wide termination.
- Keep command lines and paths quoted, and pass mutable command-line buffers to
  Win32 `CreateProcess`. Avoid shell construction where a typed process API or
  fixed argument list can be used.
- Do not weaken the market components from paper/read-only observation into
  signing, transaction submission, broadcasting, account access, pending-pool
  inspection, or automatic limit changes. Such a boundary change requires a
  separate design and security review.

## MongoDB and Alexandria invariants

- `memory-store` reads exactly one strict JSON document from stdin, capped at
  15 MiB. Unknown fields, trailing data, an empty payload, or invalid provenance
  fail. Stdout is reserved for exactly one JSON receipt or error envelope; logs
  go to stderr so the C++ caller can parse stdout.
- `MONGODB_URI` is mandatory for the Memory Store.
  `MONGODB_DB_NAME` defaults to `godbrain`. Routers do not read MongoDB directly;
  they use the canonical fixed loopback RAG endpoint.
- The source hash is legacy Keccak-256 of the exact raw transcript. Keep this
  compatible across C++ and Go. The Memory Store accepts only
  `trust_tier == "candidate"` from ingestion.
- Preserve the run state machine:
  `staging -> validated -> committed`, with `failed` reachable only from staging
  or validated. State changes must match both expected state and lease token.
- Idempotency is keyed by source hash, extractor identity/version, and schema
  version for active runs. Failed runs may be retried; stale staging/validated
  leases are failed before retry. Do not turn duplicate-key races into duplicate
  records.
- Sources and knowledge nodes are immutable `$setOnInsert` records. Per-run
  ownership/provenance belongs in ingestion runs, source observations, and
  append-only `run_node_links`; do not mutate shared nodes to attach a new run.
- Retrieval must expose only nodes linked to committed runs. Skill promotion
  must keep requiring a verified origin node linked to a committed run plus
  matching origin version and content hash.
- A committed ingestion is acknowledged only after its active
  `rag_documents`/`rag_provenance` projection is confirmed. Projection failure
  leaves the run committed, returns an explicit failure, and is repaired by an
  idempotent retry or `rag-rebuild`; committed runs must never transition back
  to failed.
- Golden Record rebuilds use a versioned generation and an atomic metadata
  pointer. Live commits dual-write to an in-progress generation. Only a fully
  reconciled generation may become active; cleanup may delete derivative
  generations but never source, node, run, link, observation, or skill records.
- Changes to the C++/Go protocol require coordinated updates to both sides and
  tests for field names, framing, size limits, receipt/error shape, hashing, and
  exit-code behavior.

## Secrets and local data

- Keep tokens, MongoDB credentials, RPC credentials, private keys, mnemonics,
  model paths, transcripts, and machine-specific data out of commits.
- Supply local values through environment variables such as
  `GODBRAIN_API_TOKEN`, `MONGODB_URI`, `MONGODB_DB_NAME`,
  `GODBRAIN_COLIBRI_PATH`, `GODBRAIN_SNAPSHOT_PATH`,
  `GODBRAIN_FRONTEND_DIR`, `GODBRAIN_LIBRARIAN_PATH`, `LLM_RUNNER_PATH`,
  `PROMPT_TEMPLATE_PATH`, `MONGO_STORE_PATH`, `GODBRAIN_RAG_PORT`, and
  `GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION`. Optional local semantic retrieval uses
  `GODBRAIN_EMBEDDING_ENDPOINT`, `GODBRAIN_EMBEDDING_MODEL`,
  `GODBRAIN_EMBEDDING_MODEL_REVISION`, `GODBRAIN_EMBEDDING_MODEL_SHA256`,
  `GODBRAIN_EMBEDDING_DIMENSION`, and `GODBRAIN_RAG_EMBEDDING_REQUIRED`.
- Do not print complete environments, secrets, private prompt/transcript
  contents, or credential-bearing URIs. Use synthetic fixtures and reserved
  addresses in tests.

## Change discipline

- Preserve cross-language protocol compatibility and fail-closed behavior before
  refactoring for style.
- Add or update tests in the affected subtree for behavioral changes. Keep
  fixtures deterministic and offline unless a test is explicitly opt-in.
- When documentation and code disagree, source/configuration is authoritative;
  update the documentation in the same change.
