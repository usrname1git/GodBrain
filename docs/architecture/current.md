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

One GPU generate slot. Desk default is bartowski Gemma 12B IT **Q6_K_L** via
`llama-server` **with MTP** when the bartowski draft GGUF exists
(`scripts/Start-LlamaServer.ps1`; `-NoDraft` disables). Hauhau/official QAT
MTP is not this draft. Soak: `scripts/Invoke-MtpSoak.ps1`.
Heal/Watch kick that door, not Colibri. `-Obliterated` loads the local
OBLITERATUS Gemma 4 12B v2 Q8_0 (Q6_K is not on the Hub); named GO, not the
Watch default. `-Agentic` loads the local yuxinlu1 Gemma 4 12B v2 Q6_K
coding/tool gym; same rule. A GLM MoE snapshot (5.2-uncensored on
disk, or a later 5.3 GGUF) is **research**: RAM-offload, named GO, never the
thing `/brief` cold-starts. One card in the slot (4080 now; 3090 when the 4080
leaves) does not make GLM the default. `logs/mouth.txt` says which engine is up.

Galaxy chat POSTs the live OpenAI door (`/v1/chat/completions`). If `:8000` is
down the kernel **refuses** to cold-spawn a 16 GB snapshot. Heal/status may kick
`scripts/Start-LlamaServer.ps1` (skip CS2, skip a loading server, 5 min cooldown) and
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
an intentional high-risk capability, not a sandbox. Surgery runs `pwsh` with a
60s wait, capped concurrent pipes, and explicit job/process kill on timeout.
If Job Object setup fails it still terminates the `pwsh` it created. Chat advertises OpenAI `tools` to llama-server (`--jinja`). Gemma 4 native
`tool_calls` / `tool_responses` are executed by the kernel. Copilot MCP is
not a runtime on this desk; GodBrain replaces that client. Do not dual-run.
Llama chat prepends `logs/where-we-are.md` (session pointer) and verified
RAG hits so the mouth can RTFM Golden Records (4 KiB cap). That is the
manual, not an internet majority vote. Coli/GLM stays at 160 bytes.
`query_constellation` is an alias of `query_recent_thoughts`. There is no
Node constellation viewer. `*** TOOL` text is a fallback.
Allowlist: FS under `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`,
`C:\Tools`, and `C:\Temp\GitHub` (list/read/write/
search/edit/move/mkdir/info/tail), SysInternals console `*64`,
`reg`/`wevtutil`/`logman`/`schtasks` query, always-on `run_pwsh` /
`run_python` / `run_node`. Mutate and `run_elevate` need `/yolo`. No Mongo
shell, no process kill, no Remote MCP. Mouth text is not a general shell.

Galaxy: graph, chat, This host vs Pending, SRE button. Brave extension talks to
the same loopback API.

`GET /api/status` `host_record` is the Windows host inventory card (`os_pin=`
present, not a Playbook).

## Alexandria (`:8084` + Mongo)

Mongo is the vault. Raw sources are immutable. Chat and Galaxy read committed
Golden Records through `rag-service`, never by querying `nodes` from C++.

Librarian extracts **claims**, not a recap, and writes only
`trust_tier=candidate` through `memory-store.exe`. Contradictions and open
questions stay candidate. **Ingest** keeps sectors apart (do not dump Abrams
hardware into a Windows SRE digest unless the operator asks). Oracle **search**
is verified-only and does not lock a sector unless the caller sends one; b-line
on this host is still Windows SRE / OS-network, not tanks.
`/verify` and `/reject` are the human door
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
`truth`, `judge`. `/brief` **first line** is the host glance (`inbox=`, `sre=`,
`next=`, `tail=door/<100.x>` when bound). Extra lines after that clip `last`
Oracle and `edit=` (same residue as `/last` / `/last-edit`). It does not
prepend `logs/where-we-are.md`; that file is the next-loop pointer, not the
phone glance. The iPhone Shortcut should show the first line.

Pending lists candidate Oracle turns, a candidate host card, and newest
unverified Golden Records. It skips `kind=concept` and Heal-loop labels.

## Local edits and CS2

Galaxy This host shows `Edit: ok` / `Edit: fail` / `Edit: none` from
`last_edit` (missing result is none; `applied=false` or a report without a
successful apply is fail).

`/edit` plans a repo file change, then a second GPU pass applies `*** APPLY`
blocks. `/edit` does not search RAG (the untrusted-notes wrapper jailed the
mouth off APPLY) and does not persist as an Oracle candidate. First pass
gets a window around a marker named in the `/edit` text (not the first
Galaxy glance in the file), not the first 4 KB. Apply skips
an old-text hunk that is not in that excerpt (wrong site, e.g. overlay vs
host-card). A first-pass hunk that misses still gets the second GPU pass. A complete
hunk in the `/edit` message is applied if the mouth
truncates; LF hunks match CRLF files. The second pass uses that same operator-hint excerpt
(including `galaxy.html`) and does not replay the truncated first answer
(wrong-site sludge). It is logged under `SECOND` in
`logs/last-edit-plan.txt`. Writes only root `.ps1` / `.cmd` / `.md`, top-level `scripts\*.ps1`,
`docs\*.md`, or `godbrain_core\` (not build / vendor / LLM / archive). Never
git push from the mouth. Apply
records `local-edit-apply-v1` in `logs/last-edit-result.json` and is **not**
enough to promote a skill. A path-selected bounded check
(`powershell-parse-v1`, `kernel-file-v1`, `memory-store-go-v1`,
`galaxy-html-static-v1`, `librarian-self-test-v1`) may run after apply;
`check_ok` is recorded separately and still cannot promote.

Librarian may extract `skills_extracted`; they land as candidate knowledge
nodes (`kind=skill`). `PromoteSkill` requires a verified origin node, a
committed run, matching hash, origin content (not a caller rewrite), and a
passing latest `skill_verification_runs` row for that skill name whose
profile is not `local-edit-apply-v1`. `POST http://127.0.0.1:8084/v1/skills`
returns promoted skills only.

`godbrain_core/skill_lab/` is a gym, not Galaxy. First canvas is a Vite+React
dashboard fixture (`frontend-spa-v1`). `scripts\Verify-SkillLab.ps1` runs
`npm ci` off the GPU under `skill_lab/fixtures`, fails without a lockfile
or README (Brief, Stack, Run, Check, Not Galaxy), and does not mark the
skill promotable. Stack pick is `stack-policy.json` (SPA → Vite; GodBrain
UI stays `galaxy.html`). Not a kernel factory.

`Start-CS2.ps1` pauses the mouth and Tailscale, launches Steam app 730, waits
until `CS2.exe` exits, waits 10 minutes, then `tailscale up --unattended` and
Start-GodBrain. Never logout, `--reset`, or uninstall Tailscale. Start/Heal
skip the mouth while CS2 is running or has been gone under 10 minutes.

## Also in the tree, not the Jarvis path

Go and Rust routers on `:8082`, paper/read-only market tools, and the Foundry
contracts tree exist as experimental code. This desk does not run them as the
operator UI. See [`future.md`](future.md).
