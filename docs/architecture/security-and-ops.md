# Security and ops

Index: [`ARCHITECTURE.md`](../../ARCHITECTURE.md). Kernel HTTP:
[`runtime.md`](runtime.md). Mongo write rules: [`alexandria.md`](alexandria.md).

## Trust zones

1. **Untrusted input:** Browser text, retrieved web content, database documents,
   and model output.
2. **Local application zone:** UI and ordinary RAG APIs on loopback.
3. **Privileged execution zone:** Authenticated C++ Kernel dispatch.
4. **Credential zone:** Environment-provided API, MongoDB, and future capability
   credentials.
5. **External services:** Market APIs, advisory sources, and other
   explicitly configured endpoints.

Data never becomes executable merely because it came from a model or database.

## Current controls

- Kernel binds to `127.0.0.1:8083`. RAG binds to `127.0.0.1:8084`. Alternative
  routers bind to `127.0.0.1:8082`.
- Browser CORS is restricted to trusted local/Tauri origins. Loopback and CORS
  are not authorization.
- Privileged HTTP dispatch (`command_type`) requires `Authorization: Bearer`
  matching configured `GODBRAIN_API_TOKEN`. Missing server configuration fail-
  closes. The token is never logged and never written to `*.launch.cmd`.
- High-risk kernel commands require a non-empty `reasoning` string. Reasoning
  is intent, not authentication.
- Tailscale GET/POST shortcuts require the bearer on that listener. Chat
  generate is not on the tailnet.
- MongoDB connection configuration is read from the environment.
- Child-process timeouts target the exact spawned process or Job Object. Never
  image-name-wide termination.
- UI text is inserted through text nodes rather than raw HTML.
- Heal/Watch never kill a process. Heal never runs BIOS, DISM, registry
  cocktails, winsock reset, ip reset, DeviceCleanup, or reboot.

## Known limitations

- A bearer token is a coarse capability; it does not yet scope individual
  commands, resources, or time windows. That is acceptable while the privileged
  surface stays small. Short-lived grants are a later Factory item, not a
  Jarvis blocker. See [`research.md`](research.md#ranked-later-decisions).
- Ordinary local chat/graph routes are intentionally unauthenticated.
- Raw PowerShell remains available behind the privileged boundary. Do not grow
  that surface. Do not enable autonomous privileged execution.
- Chat, graph, and node lookup go through the loopback RAG service rather than
  a native MongoDB driver in C++.
- Default Golden Record retrieval is lexical MongoDB text search. Hybrid
  retrieval is opt-in behind a pinned loopback embedding provider.
- Galaxy graph links are provenance co-occurrence (`same_source` / `same_run`),
  not typed `knowledge_edges`. Those edges are indexed but not written yet.
- The experimental Rust router still returns `410` for `/api/graph` and
  `/api/node`.
- Structured audit events, approval records, and automated rollback belong to
  the planned Agent Factory control plane. They are required *before* anyone
  enables autonomous privileged execution — which this host is not doing.
  Not a standing allow on BIOS, DISM, or registry cocktails.

## Configuration

| Variable | Used by | Purpose |
|---|---|---|
| `GODBRAIN_API_TOKEN` | C++ Kernel | Bearer token for privileged `command_type` and Tailscale door |
| `GODBRAIN_COLIBRI_PATH` | Heal / spawn path | Override the Colibri executable path. Kernel does not cold-spawn on 16 GB |
| `GODBRAIN_COLIBRI_MODEL` | C++ Kernel | Model id sent to `coli serve` (default `glm-5.2-colibri`) |
| `GODBRAIN_COLIBRI_KEY` | C++ Kernel | Bearer token for `coli serve` if `COLI_API_KEY` is set |
| `GODBRAIN_FRONTEND_DIR` | C++ and Go routers | Override the Galaxy static-file directory |
| `GODBRAIN_SNAPSHOT_PATH` | Routers and SRE tools | Override the model snapshot directory |
| `GODBRAIN_CUDA_EXPERT_GB` | C++ Kernel | Override Colibri VRAM expert budget; default is dedicated VRAM minus 4 GB on ≤16 GB cards |
| `GODBRAIN_COLI_OVERCOMMIT` | C++ Kernel | `1` allows Colibri to spill experts into system RAM (the slow path). Default off |
| `GODBRAIN_LIBRARIAN_PATH` | `trigger_librarian.ps1` | Override `librarian.exe` |
| `GODBRAIN_LIBRARIAN_SPAWN` | Native Librarian | `1` allows Librarian to cold-spawn Colibri. Default off |
| `LLM_RUNNER_PATH` | Native Librarian | Override the Colibri executable used for framed inference |
| `MONGO_STORE_PATH` | Native Librarian | Override `memory-store.exe` |
| `GODBRAIN_TEMP_DIR` | Native ingestors | Override temporary script/output location |
| `GODBRAIN_TELEMETRY_LOG` | ETW daemon prototype | Override telemetry log location |
| `MONGODB_URI` | Go Memory Store and Golden Record RAG tools | Required MongoDB connection string |
| `MONGODB_DB_NAME` | Go Memory Store and Golden Record RAG tools | Override the `godbrain` database name |
| `GODBRAIN_RAG_PORT` | Golden Record RAG service | Override loopback port `8084`; bind address is not configurable |
| `GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION` | Golden Record RAG service | Optional schema version ranking preference |

MongoDB currently defaults to `mongodb://localhost:27017` and database
`godbrain`.

Secrets must not be committed, logged, inserted into prompts, or stored in graph
records. Keep tokens, MongoDB credentials, RPC credentials, private keys,
mnemonics, model paths, transcripts, and machine-specific data out of commits.

## Deployment topology

After a Windows reboot, Mongo should come back as its own service. GodBrain
itself is **not** an SCM service (CUDA/Colibri cannot run as LocalSystem).
Register a current-user logon task instead:

```powershell
.\Install-GodBrainLogon.ps1
```

That runs `Start-GodBrain.ps1` when you sign in and starts whichever of
`rag-service.exe`, the configured mouth (`llama-server` or `coli serve`), and
`godbrain-kernel.exe` actually exist. Missing binaries are skipped and logged
under `logs\`.

Watch (`Install-GodBrainWatch.ps1`) is the 24/7 loop: it only calls Heal.
`Test-GodBrainDesk.ps1` fail-closes the no-GPU doors after Start-GodBrain.

### Minimal C++ path

1. Start MongoDB on `localhost:27017`.
2. Start the mouth (`Start-LlamaServer.ps1` on this desk, or `coli serve`).
   Set `GODBRAIN_COLIBRI_PATH` and `GODBRAIN_SNAPSHOT_PATH` only when defaults
   do not apply. Do not expect the kernel to cold-spawn a 16 GB snapshot.
3. Set a high-entropy `GODBRAIN_API_TOKEN` if privileged commands or the
   Tailscale door are required.
4. Build and start the C++ Kernel.
5. Open `http://127.0.0.1:8083/galaxy` or use the Brave extension.

### Golden Record path

1. Start MongoDB and set `MONGODB_URI`.
2. Run `build_pipeline.ps1` to build `memory-store.exe`, `rag-service.exe`,
   `rag-rebuild.exe`, and `librarian.exe`.
3. Set optional binary overrides. Librarian uses the live `:8000` mouth.
4. Drop a `.txt` in `inbox\` or run `Invoke-Librarian.ps1` /
   `trigger_librarian.ps1`.
5. Run `rag-rebuild.exe` once to project committed records written before this
   retrieval layer, then start `rag-service.exe`.

### Alternative router path

Start either the root Go router or the Rust router on `127.0.0.1:8082`, not both.
These paths require MongoDB and a mouth but do not host privileged kernel
dispatch. See [`research.md`](research.md).

## Failure and recovery behavior

- Startup fails when a required database dependency cannot be reached.
- Child-process spawn and timeout errors return failure rather than synthetic
  model output.
- Database writes are consumed before success is reported.
- Test cleanup failures return non-zero.
- The Librarian propagates Memory Store failure to its caller. Heal quarantines
  a failed inbox file so the next tick does not retry it forever on the GPU.
- A post-commit projection failure is explicit. The committed source records are
  not rolled back or marked failed; retrying ingestion or running
  `rag-rebuild.exe` repairs the derivative projection.
- Rebuilds populate a non-active generation, reconcile committed node and
  provenance counts, then atomically switch one metadata pointer. Retired
  generations are deleted only after the maximum request lifetime has elapsed.
- Generated build artifacts are excluded from source control.
- If `:8000` is down, chat and Librarian fail closed (or Heal/status kick
  `Start-LlamaServer.ps1`). The kernel does not cold-spawn.

Automated state snapshots, rollback execution, durable retries, and lease
recovery are planned Agent Factory responsibilities, not current guarantees.
Heal is the host recovery loop that exists today.

## Observability

Current components emit process-local text logs, JSON snapshots under `logs\`,
and exit codes. Desk glances survive a dead kernel:

| File | Written by |
|---|---|
| `logs/last-brief.txt` | `/brief`, Heal |
| `logs/last-heal.txt` | `/heal` |
| `logs/last-sre.txt` | `/sre`, Start-GodBrain |
| `logs/last-pending.json` | `/pending`, `/verify`, `/reject` |
| `logs/last-vram.json` | `/vram`, Heal |
| `logs/last-oracle.txt` | `/last` |
| `logs/last-edit.txt` | `/last-edit` |
| `logs/heal-last.json` | Heal |
| `logs/where-we-are.md` | `Write-SessionDigest.ps1` |
| `logs/mouth.txt` | mouth starter |

A production control plane would add structured JSON logs, latency/queue
metrics, and audit events. That is Factory later, not the next brick. Logs
must redact bearer tokens, credentials, private keys, and sensitive prompt
content.
