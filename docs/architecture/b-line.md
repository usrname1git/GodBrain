# B-line phase (complete)

Snapshot of the old `next.md` as of 2026-08-28. This phase **shipped**. Live
desk: [`current.md`](current.md). Pointer that used to be the backlog:
[`next.md`](next.md). Later / not-this-phase: [`future.md`](future.md).
Index: [`ARCHITECTURE.md`](../../ARCHITECTURE.md).

B-line was Windows OS/network on this machine — detect → reason → allowlist
patch → verify. Not tanks, not AppX eviction, not fleet DISM. Do not hire
Agent Factory to look busy.

## 1. Keep the one loop honest

Heal/Watch already start missing listeners, diagnose icmp/dns/nic, flushdns
once, rebuild unready RAG, drain one inbox file, and remember as candidate.

Next work here is the **verifier**, not a second process:

- Desk tests (`Test-GodBrainDesk.ps1`) stay fail-closed after Start.
- `/brief`, `/heal`, `/sre` remain truthful when the kernel or mouth is down
  (on-disk snapshots under `logs\`).
- Do not add a second starter racing `:8000`.
- Do not teach Heal to kill, reboot, or run the repair cocktail.

Done looks like: after reboot, logon + Watch restore `:27017` / `:8084` /
`:8000` / `:8083` without a human, and `/brief` matches the live ports.

## 2. Grow the library as candidates

Inbox + Librarian + `/pending`. Operator `/verify` / `/reject` crowns truth.
Do not auto-verify playbooks.

Next work:

- Drop real sources in `inbox\` when the mouth is idle; Heal takes one file
  per tick.
- Failed extracts stay in `inbox\failed\` so they do not steal the GPU.
- Pending stays a judge list (no concept sludge, no Heal-loop remember noise).
- New claims point at existing Golden Records instead of minting near-copies.
- Contradictions and open questions stay candidate.

Done looks like: `/pending` is a short list of things a human should judge,
not a dump of the vault.

## 3. Phone glance without GPU

`/brief`, `/sre`, `/pending`, `/last`, `/doors` on Tailscale with bearer. Chat
generate stays loopback.

Glance **first line** is the host one-liner (`inbox=`, `sre=`, `next=`).
`/brief` may still append `last` / `edit` clips under that line; the phone
Shortcut should use the first line only. `where-we-are.md` is an agent
pointer, not prepended onto `/brief`.

Keep:

- Tailscale door late-binds if the adapter logs in after kernel boot.
- Writes from the phone (`remember` / `librarian` / `judge`) still need bearer.

Done looks like: the operator can see heal age, pending ids, and SRE layer
from the tailnet without starting a generate.

## 4. SRE diagnose only until a named GO

`sre_surgeon --diagnose` when layer ≠ ok. `GET /api/sre` is the phone snapshot.

Next work:

- Diagnose first: ping, nslookup, tracert (and Heal `icmp_loopback`), then
  NIC-to-Tcpip binding. Repair tools come after that split.
- Heal never `--ask` while the mouth holds the GPU.
- Named GO in this chat for `ipconfig /release` `/renew`, `netsh winsock reset`,
  `netsh int ip reset`, DeviceCleanupCmd, reboot — one tool per GO.

Done looks like: when the layer is down, `/sre` shows the last diagnose text
and Heal has not run a cocktail.

## 5. One GPU mouth

llama-server Gemma 12B IT Q6_K_L, MTP **off** by default (`-UseDraft` only if a draft file exists).
Kernel refuses cold-spawn on 16 GB.

Next work:

- Keep one slot. Librarian waits if chat is generating.
- Status/brief may kick Start-LlamaServer; they must not stack a second generate.
- CS2 pause remains the GPU yield.

Done looks like: `:8000` is either healthy, `llama=starting`, or honestly down
— never a second coli racing the llama-server.

## Explicitly not this phase

- Agent Factory roster / Architect / Surgeon agents.
- Short-lived capability grants (bearer is the current gate).
- Versioned job/evidence JSON Schema repos.
- Typed `knowledge_edges` replacing provenance stars.
- Autonomous privileged execution, BIOS, DISM, or registry cocktails.
- Cross-fleet patching (Devuan / macOS / other PCs).

Those live in [`future.md`](future.md), ranked. If a sixth **node** is ever
justified, the smallest honest one is a candidate-vs-verified **conflict
queue** (overloaded verifier), not an org chart.
