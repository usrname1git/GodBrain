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

## Default is one loop

A loop is one agent (or one script) running discover → plan → execute → verify
until a checkable done. A graph is several nodes with edges. GodBrain's job is
to count how many nodes the problem actually has. Usually one.

- **Default to the loop.** Heal, Watch, Oracle CONTINUE, and Librarian are
  loops. Do not add a second process, subagent, or framework because a diagram
  looks more serious. This host has one Colibri GPU slot and one
  `last_oracle.json`.
- **The verifier is the bottleneck, not the model.** Generation is cheap and
  often wrong. Value is the check: port probes after Start, fail-closed RAG,
  loop/ngram abort, `/verify last` / `/reject last` with a why. Strengthen the
  check before adding nodes. Half of "we need more agents" is a weak verifier.
- **Name the signal before a second node.** Allowed signals: distinct
  specialty (Architect vs Surgeon), true parallel fan-out that does not share
  the GPU slot, a different model/tool per step (Colibri vs a future
  llama-server runner — still one chat door), auditable branch (verify vs
  reject), or an overloaded verifier (a future candidate-vs-verified conflict
  queue). If you cannot name which signal paid for the node, delete it.
- **One node per real specialty, not per imagined step.** Do not spawn
  research/plan/execute/review agents for a kernel one-liner.
- **Keep it collapsible.** If deleting a node leaves the same result, delete
  it. Coordination is latency and another failure point (two starters racing
  `:8000` is the tax).
- **Stop and re-loop when sideways.** Do not keep pushing the same generate
  (Oracle-DB CONTINUE, heading loops, 32 GB RAM death). Re-plan the check.
- Do not add `tasks/todo.md`, `tasks/lessons.md`, or an agent framework to
  implement this. The loop is Heal + judge + this file.

## Before implementing

Bill yourself for rework. A wrong assumption is the agent's cost. An
unnecessary question is the operator's. Discoverable in a minute of
searching is not a question.

- **Investigate first.** Read the code, tests, configs, and the nearest
  README before asking. Test framework, language, lint, directory layout,
  and existing abstractions are research you owe. Raise it only if the
  repo contradicts itself.
- **Proportionality.** A typo, rename, or one-obvious-form change under
  ~20 lines: just do it in the same turn. A new module, schema change,
  auth, money, migration, or **any delete** (model tree, Mongo, DISM):
  full treatment below, and be more suspicious than usual.
- **For full treatment, write this and stop:**
  - **Goal.** One paragraph restating the ask and the acceptance check.
  - **Blocking questions (0–3).** Only if a wrong answer means throwing
    the work away, not adjusting it. Each question ships a recommended
    default so the operator can say "yes to all." Zero is allowed.
  - **Assumptions.** Numbered, specific, falsifiable. Cover only what
    this change touches: data shape/trust, failure (retry / fail loud /
    degrade), API vs internal, concurrency/idempotency, environment
    (Windows, no LocalSystem Colibri, one GPU slot), explicit non-goals,
    and what you will actually test.
  - **Plan.** Files, key signatures, order. If you rejected a real
    alternative, name it in one clause.
- **After go-ahead:** implement that plan. If an assumption dies on
  contact with the code, stop and say so. Do not quietly improvise a
  different design.

This is the same loop as Heal: discover → plan → execute → verify. The
plan step is skipped when the blast radius is a one-liner.

- **Rails live in this file.** Do not re-negotiate host rules each turn
  (Windows-first, no LocalSystem Colibri, no DISM, one GPU slot, candidate
  ≠ verified). A human blog post about an API is extra color after the
  repo docs, not a replacement for them.
- **Lock scope before a large write.** Goal + 0–3 blocking questions with
  defaults. Do not invent XML ceremony.
- **Verify on the running host.** Ports, `/status`, Galaxy click-path, or
  a failing test — not only a diff. For UI, screenshot or exercise the
  route. For Colibri, `/health` and `coli=serve` (not busy).
- **Voice I/O is local and CPU-first.** STT: `faster-whisper` `large-v3`
  at `C:\nvme\faster-whisper-large-v3` via `C:\nvme\stt\Transcribe-Clip.ps1`
  (20 threads, no CUDA while coli holds VRAM). TTS: `python -m piper` with
  voices in `C:\nvme\piper-voices` via `C:\nvme\stt\Speak-Text.ps1`.
  FFmpeg is `C:\Tools\ffmpeg\ffmpeg.exe`. Do not use cloud STT/TTS. Do
  not load Whisper or Piper on the 4080 while `coli serve` is pinned.
- **Next loop starts from persisted state.** Read
  `logs/where-we-are.md` first if it exists (session pointer: what
  changed, what is next). Then `last_oracle.json`, Heal last, git,
  Golden Records. Do not treat chat history as the source of truth.
  End a working session with `Write-SessionDigest.ps1 -Now ... -Next
  ...`. If the plan died, say so; do not continue from a hallucinated
  tree.

## Ingestion protocol (raw vs processed)

This is the research loop. Mongo is the vault. Do not stand up Obsidian or a
cloud model to get it.

- **Raw is immutable.** Sources (transcripts, observe blobs, session files)
  are never edited after ingest. Librarian and chat must not rewrite the
  source to match a later opinion.
- **Wiki is processed Golden Records.** Chat, digests, and "what have we
  learned" queries pull from committed `rag_documents`, not from raw
  transcripts. Raw may contain claims later rejected; that is why judge
  exists.
- **Extract claims, not a summary of the whole document.** Librarian writes
  specific new findings with evidence spans. Do not dump a paraphrase of the
  entire source into one node.
- **Extend, do not duplicate.** If a topic already has a Golden Record,
  add a new candidate that points at it. Do not mint a near-copy.
- **Contradictions are flagged, never silently overwritten.** If a new claim
  fights a verified or earlier candidate, both stay. Write a
  `contradiction` / `open-question` candidate and wait for `/verify` or
  `/reject`. Automating the winner defeats the starter pack.
- **Do not guess.** If the source raises a real question the wiki cannot
  answer, store it as an open-question candidate. The Oracle must say it
  does not know rather than invent.
- **Sectors keep topics from contaminating each other.** Abrams hardware
  and Windows SRE do not share a digest unless the operator asks to
  synthesize across sectors. Tanks / military hardware are **not** the
  current ingest sector. B-line is closed-loop OS/network on this host
  (detect → reason → allowlist patch → verify). Do not seed tank cards.
  SRE first step is diagnose: ping, nslookup, tracert (and Heal
  icmp_loopback), then NIC-to-Tcpip binding (Get-NetAdapter /
  Get-NetAdapterBinding ms_tcpip, Class NetCfgInstanceId vs
  Tcpip\Parameters\Interfaces). Repair tools come only after that
  split. Know them all; run none of them first. None of these are
  forbidden: `ipconfig /flushdns`, `/release` `/renew`, `netsh winsock
  reset`, `netsh int ip reset`, DeviceCleanupCmd, reboot. Heal may run
  `ipconfig /flushdns` once after diagnose (dns_self fail, Dnscache
  up, icmp_loopback up). The rest require an explicit operator GO in
  this chat, one named tool per GO, never the full cocktail.
  DeviceCleanupCmd is `C:\Tools\DeviceCleanupCmd\DeviceCleanupCmd.exe`
  (Uwe Sieber 1.5.1). It creates an SRP before the first real remove
  unless `-s`. The operator runs `*` from time to time to clear dead
  PnP entries; do not treat `*` as the default option and do not run
  it without GO. It cannot uninstall leftover NDIS names on a
  still-present PCI NIC.
  SysInternals on this host is `C:\Tools\SysInternals`. After ping /
  nslookup / tracert, use the 64-bit network extras: `psping64` (ICMP,
  TCP connect, latency, bandwidth; `psping64 -? i|t|l|b`), `tcpvcon64
  -a -n` or `tcpview64` (who owns the socket), `whois64` (who owns the
  name or IP). Deeper only: `procmon64` with a Network filter,
  `shareenum64` / `psfile64` for SMB. Heal never launches them.
  Heal auto-starts services, then diagnoses icmp_loopback / dns_self /
  nic_tcpip. nic_tcpip is detect-only. Heal does not reboot.
  The SRE surgeon kit is `godbrain_core/sre_agent/sre_surgeon.exe
  --toolkit` (inventory + gates) and `--diagnose` (read-only probes).
  Do not `--ask` while `coli serve` holds the GPU slot.
  Local file edits: Galaxy can ask the mouth to change a repo file.
  The kernel saves the plan in RAM (`logs/last-edit-plan.txt`), does a
  second GPU pass for `*** APPLY` blocks (thinking off, spoken-only parse),
  writes `logs/last-edit-result.json` for `/status` / `/brief` / Galaxy,
  and writes only root
  `.ps1`/`.cmd`/`.md` or `godbrain_core\` (not build/vendor/LLM/archive).
  Never git push from the mouth.
  Play CS2 via `Start-CS2.ps1` / `Start-CS2.cmd`: pause the mouth
  (coli and `llama-server`) and `tailscale down` first, launch Steam
  app 730, wait until `CS2.exe` exits, wait 5 minutes, then
  `tailscale up --unattended` and Start-GodBrain. Never logout,
  `--reset`, or uninstall Tailscale. `Watch-Cs2Pause` (task
  `GodBrainCs2Pause`) is only the backup if CS2 is started from Steam
  Play. Start/Heal skip the mouth while CS2 is running or has been
  gone under 5 minutes.
- **Volume vs depth.** Routine extract/cross-ref uses the cheap local
  runner (Colibri on this host). Reserve a heavier runner (future
  llama-server / a larger model) for a flagged contradiction or a
  high-stakes synthesis the loop itself marked as worth extra scrutiny.
- **A digest, if anyone writes one, is a pointer.** Only what changed in
  the processed layer, plus new conflicts and open questions. Under 500
  words. Never re-summarize the entire wiki. Never pull from raw.

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
  `memory-store.exe`. `set_godbrain_status` is the only status door
  (`verified` / `rejected` / `stale`). Humans still `/verify` playbooks and
  fights. Host inventory and `/api/truth` host_fact/doc_fact call that door
  themselves when a live probe or a Learn/support quote actually matches.
  `query_recent_thoughts` reads the active RAG graph. Oracle search is
  verified-only.
  Ordinary Galaxy chat exposes `/observe`, `/vram` (one GPU slot + next worker size), `/remember`, `/verify`,
  `/reject`, `/recall`, `/status`, `/last`, and `/brief`. `/verify last <why>`
  and `/reject last <why>` judge the newest on-disk Oracle turn. `/last` and `GET /api/last`
  return on-disk Oracle turns without touching Colibri. `/brief` is the one-glance
  host + mouth + pending-judge + heal + CS2-sleep + last-turn line. If `logs/mouth.txt` says llama and `:8000` is
  down, `/api/status` and `/brief` kick `Start-LlamaServer.ps1` via
  `run_hidden` (skip CS2, skip a loading `llama-server.exe`, 5 min cooldown)
  and report `llama=starting` so Galaxy does not wait on the 5 min Watch tick.
  `/heal` reports the host-listener closed loop
  (detect → start missing allowlist → diagnose → maybe flushdns → verify). Watch-GodBrain runs
  Heal-GodBrain.ps1; it never kills a process. The Galaxy node panel and `POST /api/judge` are
  the same judgment path. `/observe` persists stable host inventory including
  `os_pin=EditionID/CurrentBuild.UBR` and auto-verifies that sensor read.
  If the pin moved, verified `windows-sre` cards that carry a different
  `os_pin=` become `stale` (not deleted). Logon (`Start-GodBrain.ps1`) posts
  `/api/observe` once the kernel is listening; unchanged inventory is an
  idempotent no-op. WMI process start passes `GODBRAIN_API_TOKEN` in the
  child environment so Heal/Watch/logon cannot boot a kernel that fail-opens
  loopback writes; the token is never written to `*.launch.cmd`.
  `POST /api/truth` writes host_fact / doc_fact / playbook
  claims: host probes and Learn quotes can promote; playbooks stay candidate. Kernel boot loads
  the newest Golden Records into the process session buffer so chat still knows
  the host after a restart. `/api/status` reports the host card and Tailscale
  remember URL. The Tailscale shortcuts door binds when
  `GODBRAIN_API_TOKEN` is set and the adapter has a 100.x address.
  `/status` late-binds that door if Tailscale logs in after kernel boot,
  and reports `needs_login` when the service is up but offline.
  Chat requires `coli serve` on `:8000` from
  Colibri 1.6.2 (`../colibri/c`, or `GODBRAIN_COLIBRI_DIR`). Prefer that over
  the vendored 1.1.1 tree under `LLM/colibri_LLM`.
  Cold-spawn of the GLM snapshot on 16 GB is disabled. Do not set both
  `COLI_GPU` and `COLI_GPUS`. Colibri VRAM budget
  is derived from DXGI dedicated memory and
  does not overcommit into system RAM unless `GODBRAIN_COLI_OVERCOMMIT=1`.
- Root `main.go` and `godbrain_core/rust_router/` are experimental,
  non-privileged RAG router alternatives on loopback port 8082. They cannot run
  together because they use the same port. Both use the canonical loopback RAG
  service and neither exposes the C++ kernel's `command_type` dispatcher.
- `godbrain_core/cpp_tools/librarian.cpp` distills a transcript through the live
  `:8000` mouth (llama-server or `coli serve` — same OpenAI chat door), validates
  the result, and sends one JSON document over stdin to the Go Memory Store.
  It does not cold-spawn Colibri unless `GODBRAIN_LIBRARIAN_SPAWN=1`.
  `Invoke-Librarian.ps1 -Text` / `-File` is the door from any IDE or shell.
  `trigger_librarian.ps1` still extracts the newest Copilot session.
  Any text file is a valid source. iPhone/Tailscale: POST `/api/remember`
  to suggest a candidate, or POST `/api/librarian` `{text}` to classify
  (uses the GPU mouth; bearer required).
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
go build -ldflags "-H windowsgui" -o rag-service.exe ./cmd/rag-service
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
cl /std:c++17 /EHsc /W4 /Fe:godbrain-kernel.exe main.cpp kernel.cpp surgery.cpp telemetry.cpp memory.cpp local_edit.cpp /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup pdh.lib dxgi.lib winhttp.lib advapi32.lib
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
