# Setup and replication

How to stand up the same desk shape on a Windows machine. This is not a cloud
install. GodBrain runs as the **logged-in user**. CUDA/Colibri cannot run as
LocalSystem.

Index: [`ARCHITECTURE.md`](../../ARCHITECTURE.md). What you get when it works:
[`current.md`](current.md). Route and env tables: [`reference.md`](reference.md).
Agent build commands also live in [`AGENTS.md`](../../AGENTS.md).

## Prerequisites

- Windows, PowerShell (`pwsh` preferred).
- Visual Studio x64 C++ tools (kernel, Librarian, `run_hidden`).
- Go version from `godbrain_core/memory_store/go.mod`.
- MongoDB Community as a **Windows service named `MongoDB`**, listening on
  `127.0.0.1:27017`.
- One GPU mouth: either `llama-server` with a GGUF, or Colibri 1.6.2
  (`../colibri/c`, or `GODBRAIN_COLIBRI_DIR`). Prefer that over the vendored
  1.1.1 tree under `LLM/colibri_LLM`.
- Optional: Tailscale (100.x) for the phone door; `GODBRAIN_API_TOKEN` is
  required for that door to bind.

MongoDB is not needed for offline CMake, Colibri web, or Solidity unit tests.
The Memory Store executable requires `MONGODB_URI`. Integration tests run only
when `MONGODB_TEST_URI` is set (disposable instance; they use isolated DBs /
`godbrain_test`).

Do not rewrite `go.mod` / lockfiles to accommodate an older toolchain.
Smart-contract submodules: `git submodule update --init` only when working in
that subtree.

## 1. MongoDB

Start/Heal look for the Windows service **named `MongoDB`**. They may start it
if `:27017` is down. They never kill it. Install it as its own service; do not
fold it into GodBrain's logon task.

1. Install [MongoDB Community Server](https://www.mongodb.com/try/download/community)
   as a Windows service. Keep the default service name `MongoDB`.
2. Bind to localhost (`127.0.0.1:27017`). Do not expose Mongo on the tailnet.
3. Database name defaults to `godbrain` (`MONGODB_DB_NAME` overrides).
4. Connection string: user or process env `MONGODB_URI`. If unset, Start uses
   `mongodb://127.0.0.1:27017`. Do not commit credentials. Start writes only
   that local default into `*.launch.cmd`, never the API token.

Check:

```powershell
Get-Service MongoDB
Test-NetConnection 127.0.0.1 -Port 27017
```

If the service is missing, Start logs `Windows service MongoDB is not installed`
and RAG will fail until `:27017` is up. Create the `godbrain` database by
running Memory Store / rag-service against it; you do not pre-seed collections
by hand.

## 2. Environment

Set at least:

| Variable | Required for | Notes |
|---|---|---|
| `MONGODB_URI` | `memory-store.exe`, `rag-service.exe`, `rag-rebuild.exe` | Default `mongodb://127.0.0.1:27017`. Kernel and Librarian do not read Mongo; they talk to those processes. |
| `GODBRAIN_API_TOKEN` | Every `command_type`; every Tailscale route | High-entropy. User env, not a file in the repo. WMI child env gets it; `*.launch.cmd` must not. Missing token fail-closes `command_type` and keeps the Tailscale door unbound. Loopback GET glances and loopback chat stay unauthenticated. |

Optional overrides (mouth path, snapshot, frontend, RAG port) are in
[`reference.md`](reference.md#configuration). Do not start a kernel that
fail-opens privileged writes.

## 3. Build Alexandria

From the repo root:

```powershell
.\scripts\build_pipeline.ps1
.\godbrain_core\cpp_tools\librarian.exe --self-test
```

That builds `memory-store.exe`, `rag-service.exe`, `rag-rebuild.exe`,
`rag-eval.exe`, and `librarian.exe`. The Librarian self-test is offline.

Once Mongo is up, project any committed records written before this retrieval
layer:

```powershell
.\godbrain_core\memory_store\rag-rebuild.exe
```

Then let Start or Heal launch `rag-service.exe` on `127.0.0.1:8084`.

Optional live desk eval (from `godbrain_core\memory_store`, RAG must be ready).
Verified-only plus each query's sector. A miss means no configured needle
appeared in the returned top-K, or the query failed. It does not prove the
claim is absent from the verified corpus. `-strict` fails on any such miss:

```powershell
.\rag-eval.exe -live
.\rag-eval.exe -live -strict
```

## 4. Build the kernel

No committed CMake project. From the repo root:

```powershell
.\scripts\Build-Kernel.ps1
```

That compiles without starting GodBrain. Backups go outside git. Equivalent
Developer-shell one-liner from `godbrain_core\cpp_kernel`:

```powershell
cl /std:c++17 /EHsc /W4 /Fe:godbrain-kernel.exe main.cpp kernel.cpp surgery.cpp telemetry.cpp memory.cpp local_edit.cpp /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup pdh.lib dxgi.lib winhttp.lib advapi32.lib
```

Starting the kernel is an integration action. Do not use startup as a
documentation-only check.

## 5. Mouth

One GPU slot. On this desk:

```powershell
.\scripts\Start-LlamaServer.ps1
```

MTP is **off** by default. Pass `-UseDraft` to start with the draft GGUF. This
host's default model/server paths are machine-local under `C:\nvme\` — point
`-Model`, `-Draft`, and `-Server` at your copies, or set the same layout.

If you run Colibri instead, keep a single `coli serve` on `:8000`. Do not set
both `COLI_GPU` and `COLI_GPUS`. Do not overcommit VRAM into RAM unless
`GODBRAIN_COLI_OVERCOMMIT=1`. The kernel will **not** cold-spawn a 16 GB
snapshot when `:8000` is down.

`logs/mouth.txt` must match the process that actually owns `:8000`.

Voice I/O (optional, CPU-first on this host): STT `faster-whisper` via
`C:\nvme\stt\Transcribe-Clip.ps1`; TTS Piper via `C:\nvme\stt\Speak-Text.ps1`.
Do not load Whisper or Piper on the GPU while the mouth holds VRAM. Paths are
this machine's; replicate only if you want voice.

## 6. Logon, Watch, CS2 pause

Build `run_hidden.exe` once by running Watch install (it compiles if missing):

```powershell
.\Install-GodBrainWatch.ps1
.\Install-GodBrainLogon.ps1
.\Install-GodBrainCs2Pause.ps1
```

- **GodBrainLogon** — current-user, at logon, runs `Start-GodBrain.ps1`.
  Starts rag / mouth / kernel if the binaries exist. Does not install Mongo.
- **GodBrainWatch** — every 5 minutes, current-user, batteries allowed. Only
  calls Heal. Never kills. Uses `run_hidden` + `pwsh -File` (never a `.cmd`).
- **GodBrainCs2Pause** — backup if CS2 starts from Steam Play.

Remove with the same scripts `-Unregister`. Never register these as
LocalSystem.

Manual start without waiting for logon:

```powershell
.\Start-GodBrain.ps1
.\Test-GodBrainDesk.ps1
```

Optional operator chrome (not a runtime door):

```powershell
.\scripts\Show-SystemFlex.ps1
```

`ti` on this host is [M2-Team Privexec](https://github.com/M2Team/Privexec) `wsudo --ti` from PATH. GitHub release zips lag `master`; install via [baulk](https://github.com/baulk/baulk) (`baulk install wsudo`) or build from source. Do not copy `wsudo.exe` into this repo. Heal and the kernel do not call it.

## 7. First check

Listeners:

```powershell
Test-NetConnection 127.0.0.1 -Port 27017
Test-NetConnection 127.0.0.1 -Port 8084
Test-NetConnection 127.0.0.1 -Port 8000
Test-NetConnection 127.0.0.1 -Port 8083
```

Browser: `http://127.0.0.1:8083/galaxy`

Heal glance (no GPU): `http://127.0.0.1:8083/api/brief`

Drop a `.txt` in `inbox\` when the mouth is idle; Heal ingests one file per
tick. Or `.\scripts\Invoke-Librarian.ps1 -File path.txt`. Claims stay candidate until
`/verify`.

Loopback ask without Galaxy: `.\scripts\Ask-GodBrain.ps1`.

If Tailscale has a 100.x and `GODBRAIN_API_TOKEN` is set, `/api/doors` lists
the phone URLs. Those routes need the bearer. Chat stays loopback.

## Replication notes

- Same Windows shape: user-level tasks, Mongo as its own service, one GPU
  mouth, kernel on loopback `:8083`.
- Do not copy `logs\`, Mongo data, tokens, model GGUFs, or `*.launch.cmd`
  into git.
- Another box needs its own `GODBRAIN_API_TOKEN`, model paths, and Mongo.
- Experimental `:8082` routers and market/contract trees are optional; skip
  them to replicate Jarvis.
