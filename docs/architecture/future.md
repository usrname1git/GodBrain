# Future planned implementations

Long-horizon items. They still correlate as rails. They are **not** the
Jarvis backlog. Next phase is [`next.md`](next.md). Index:
[`ARCHITECTURE.md`](../../ARCHITECTURE.md).

A factory node is a hire: add it only for a named signal (distinct specialty,
real parallelism, different runner, auditable branch, or an overloaded
verifier). This host has one GPU slot and one `last_oracle.json`. Growing
Alexandria is Librarian + `/verify`, not Architect/Surgeon/Verifier agents.

See [`AGENT_FACTORY_ROSTER.md`](../AGENT_FACTORY_ROSTER.md) if that contract
is ever staffed.

## Ranked later decisions

The five bullets that used to end `ARCHITECTURE.md`, ranked against what
actually moves this desk:

| Rank vs Jarvis | Item | Verdict |
|---|---|---|
| 1 (constraint, not a ticket) | Structured audit storage and recovery **before** autonomous privileged execution. Not a standing allow on BIOS, DISM, or registry cocktails. | **Rail, already decided.** Do not build an audit plane in order to turn autonomy on. Heal stays detect → allowlist → verify. Named GO per repair tool. |
| 2 (real later library work) | Retention and supersession policy for immutable MongoDB source and Golden Record collections. | **Later, real.** Sources and nodes are already immutable; only status changes. When the vault fills, define how candidates supersede, how rejected/stale stay queryable, and what (if anything) may be deleted. Do this before typed edges or Factory jobs. |
| 3 (only if privileged surface grows) | Replace coarse bearer authorization with short-lived capability grants. | **Factory auth, not next.** Bearer + loopback + Tailscale-GET-needs-token is the current gate. Grants pay off when many agents share one kernel. Do not expand `command_type` in order to need them. |
| 4 (Galaxy nicety) | Typed `knowledge_edges` written by Librarian, replacing provenance co-occurrence stars. | **Optional later.** `same_source` / `same_run` stars are enough to browse. Typed edges are a second write path. Staff after there are verified cards worth linking. |
| 5 (do not staff) | Versioned HTTP, job, result, and evidence JSON Schemas. | **Factory job contracts.** Chat, RAG, and Librarian already have fail-closed shapes. Do not start a schema repo to look serious. |

If a sixth node is ever justified: a **candidate-vs-verified conflict queue**
(overloaded verifier), not Architect / Surgeon / a capability-grant service.

## Steal from graph-engineering lectures (not the merch)

Influencer threads (Claude Code “dynamic workflows,” “uninstall the IDE,”
1000 subagents, “85% of Google PRs”) are **not** a Jarvis ticket. One GPU
slot. Coordination in a second process is latency. The lecture underneath is
still useful if a graph is ever justified.

Copy these, not the fleet:

| Idea | Meaning on this desk | When |
|---|---|---|
| Edge = data actually moves | “And then” is not a dependency. Heal is already diagnose → one allowlist patch → verify. Do not chain independent work just because you typed it in order. | Now as a rail; never a new process to look like a diamond. |
| Node contract | Bounded in/out, fail-closed shape. Librarian JSON, `trust_tier=candidate`, `/pending` as a judge list. Next node consumes a schema, not vibes. | Already ships. Do not add a schema repo (rank 5). |
| Verifier on the edge | `/verify` `/reject`, desk fail-closed, `heal=lie`, `inbox\failed\`. Kill the finding before it becomes truth. Automating the winner is forbidden. | Strengthen this before any fan-out. |
| Isolate failure | One poison extract does not retry forever. Parallel writers (if they ever exist) get separate worktrees, not one shared tree. | Already: quarantine. Worktree isolation only if two writers share a repo. |
| Converging cycle | Loop-until-dry with a stop condition. Dedupe against everything seen, not only confirmed hits, or the loop rediscovers dead ends. Heal’s 5 min tick is this shape. | Do not spawn until the GPU bill dies. |
| Cheap vs expensive node | Extract on the local mouth; human crowns. If a heavier runner ever exists, it is for a flagged contradiction or high-stakes synthesis the loop itself marked — still one chat door. | Volume vs depth in `AGENTS.md`. Not a second `:8000`. |
| Fan-in / barrier only when needed | Merge only if the next step needs the whole set (dedupe, rank, empty-exit). Otherwise pipeline, don’t wait for the slowest. | Relevant only if true parallel fan-out exists that does **not** share the GPU slot. |
| Route in code, judge in the model | `if` on a validated status (`verified` / `rejected` / `stale`), not “the mouth decided to skip `/verify`.” | Already the judge door. |

Do **not** copy: uninstall the IDE, don’t look at the code, Claude writes the
graph, ultracode self-routing, 1000 subagents on this 4080, a second
starter racing `:8000`, or any Factory roster (Architect / Surgeon /
research-plan-execute-review).

The only graph with a named signal later is still the **conflict queue**:
two nodes (candidate vs verified), human on the merge. If deleting a node
leaves the same result, delete it.

## README end-goal items that are not this host

The public README still lists a sovereign autonomous operator (CVE ingest,
cross-fleet patch, self-directed DISM/registry). On **this** host those are
not next and several are standing nos:

| README item | This host |
|---|---|
| Candidate-vs-verified conflict queue | Smallest honest extra node, **later** |
| Autonomous CVE ingestion | Not b-line |
| Cross-fleet patch (Devuan / macOS / Windows) | Not this machine |
| Self-directed DISM/registry repair | **No.** Named GO only; never a standing allow |
| Closed-loop detect → reason → patch → verify with zero hand-holding | Heal already does detect → allowlist → verify. Patch beyond flushdns stays GO-gated |

## Experimental trees in the repo

Do not mix these into Heal, Galaxy chat, or Alexandria ingest.

| Tree | Status | Constraint |
|---|---|---|
| Root `main.go` (`:8082`) | Experimental RAG router | Shares the port with Rust; no `command_type` |
| `godbrain_core/rust_router/` (`:8082`) | Experimental RAG router | Search-only; `/api/graph` and `/api/node` still `410` |
| `godbrain_core/polymarket_paper/` | Experimental, CMake | Paper trading only |
| `godbrain_core/polygon_searcher/` | Experimental, CMake | Read-only search |
| `godbrain_core/polygon_observer/` | Experimental, CMake | Read-only observation |
| `godbrain_core/smart_contracts/` | Experimental Foundry | Pinned submodules; no approved deployment path |
| `godbrain_core/cpp_ingestors/` | Standalone executables | Not Heal |
| `archive/neo4j/` | Historical | Not an active runtime dependency |

Preserve paper-only / read-only / no-signing guarantees. Do not weaken them
into signing, broadcast, account access, or automatic limit changes.
`POLYGON_RPC_URL` is only for the explicitly selected read-only fork test in
that subtree.

Deployment on this host uses the C++ kernel on `:8083`. Start either Go or
Rust on `:8082` for comparison, never both, never as the privileged door.
