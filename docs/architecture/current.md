# Currently in place

What ships and is exercised on this host. Tables, routes, and env vars live in
[`reference.md`](reference.md). How to stand it up: [`setup.md`](setup.md).
Index: [`ARCHITECTURE.md`](../../ARCHITECTURE.md).

## Desk

After logon, `Start-GodBrain.ps1` starts whichever of `rag-service`, the
configured mouth, and `godbrain-kernel` actually exist. Watch (`GodBrainWatch`)
calls Heal every five minutes. Heal never kills a process. GodBrain is **not**
an SCM service (CUDA cannot run as LocalSystem). MongoDB is its own Windows
service named `MongoDB`.

`Test-GodBrainDesk.ps1` fail-closes the no-GPU doors after Start.

## Mouth (`:8000`)

One GPU generate slot. Desk default is Gemma 12B Q4 via `llama-server` **with
MTP** (`Start-LlamaServer.ps1`; `-NoDraft` disables the draft GGUF).
`logs/mouth.txt` says which engine is up.

Galaxy chat POSTs the live OpenAI door (`/v1/chat/completions`). If `:8000` is
down the kernel **refuses** to cold-spawn a 16 GB snapshot. Heal/status may kick
`Start-LlamaServer.ps1` (skip CS2, skip a loading server, 5 min cooldown) and
report `llama=starting`.

Librarian uses that same mouth. It does not hold VRAM. It does not cold-spawn
Colibri unless `GODBRAIN_LIBRARIAN_SPAWN=1`. The Colibri React workshop is not
the GodBrain operator UI.

## C++ kernel (`:8083`)

Canonical privileged boundary. Serves Galaxy, retrieves committed Golden
Records from `:8084`, talks to the mouth, and dispatches `command_type`
requests that carry `Authorization: Bearer` plus, for high-risk commands, a
non-empty `reasoning` string.

Ordinary loopback chat and GET glances are unauthenticated. Privileged
PowerShell (`execute_godbrain_script`, `propose_sovereign_architect_change`) is
an intentional high-risk capability, not a sandbox. Mouth text is never scanned
and executed.

Galaxy: graph, chat, This host vs Pending, SRE button. Brave extension talks to
the same loopback API.

`GET /api/status` `host_record` is the Windows host inventory card (`os_pin=`
present, not a Playbook).

## Alexandria (`:8084` + Mongo)

Mongo is the vault. Raw sources are immutable. Chat and Galaxy read committed
Golden Records through `rag-service`, never by querying `nodes` from C++.

Librarian extracts **claims**, not a recap, and writes only
`trust_tier=candidate` through `memory-store.exe`. Contradictions and open
questions stay candidate. Sectors do not contaminate each other; b-line on this
host is Windows SRE / OS-network, not tanks.

Oracle search is **verified-only**. `/verify` and `/reject` are the human door
for playbooks and fights. `rejected` is terminal. Content never changes; only
status does. When `os_pin` moves, verified `windows-sre` cards with a different
pin become `stale` (not deleted).

Host inventory (`/observe`) auto-verifies the live pin.
`POST /api/truth` auto-verifies a `host_fact` when an allowlisted probe matches,
or a `doc_fact` when a Learn/support quote is actually on the page. Playbooks
stay candidate.

Galaxy graph links are provenance co-occurrence (`same_source` / `same_run`),
not typed knowledge-graph edges.

Unready RAG is repaired by Heal with `rag-rebuild.exe` (30 min cooldown). Heal
never kills `rag-service`.

## Heal / Watch / SRE

Heal v4: probe TCP then HTTP ready (`rag /health.ready`, mouth `/health`),
start the allowlist, one `flushdns` after a DNS miss, `rag-rebuild` if the
projection is unready, drain one `inbox\*.txt` when the mouth is idle,
quarantine poison files, `POST /api/observe`, `sre_surgeon --diagnose` only
when layer ≠ ok (15 min cooldown). Remember on act/fail as **candidate**.

Heal may not: kill processes, reboot, `tailscale up`, `--ask`, winsock reset,
ip reset, DeviceCleanup, `/release` `/renew`, BIOS, DISM, or registry
cocktails. Those need an explicit operator GO, one named tool per GO.
`nic_tcpip` is detect-only.

## Phone glance (Tailscale)

When `GODBRAIN_API_TOKEN` is set and the adapter has a 100.x address, a second
listener binds on that IPv4. Every Tailscale route needs the bearer, including
GETs. Chat generate is **not** on that door.

Glances: `/brief`, `/heal`, `/sre`, `/pending`, `/last`, `/vram`, `/doors`,
`/desk`, `/last-edit`, `/status`. Writes: `remember`, `librarian`, `observe`,
`truth`, `judge`. `/brief` prints `tail=door/<100.x>` when bound.

Pending lists candidate Oracle turns, a candidate host card, and newest
unverified Golden Records. It skips `kind=concept` and Heal-loop labels.

## Local edits and CS2

`/edit` plans a repo file change, then a second GPU pass applies `*** APPLY`
blocks. Writes only root `.ps1` / `.cmd` / `.md` or `godbrain_core\` (not
build / vendor / LLM / archive). Never git push from the mouth.

`Start-CS2.ps1` pauses the mouth and Tailscale, launches Steam app 730, waits
until `CS2.exe` exits, waits 5 minutes, then `tailscale up --unattended` and
Start-GodBrain. Never logout, `--reset`, or uninstall Tailscale. Start/Heal
skip the mouth while CS2 is running or has been gone under 5 minutes.

## Also in the tree, not the Jarvis path

Go and Rust routers on `:8082`, paper/read-only market tools, and the Foundry
contracts tree exist as experimental code. This desk does not run them as the
operator UI. See [`future.md`](future.md).
