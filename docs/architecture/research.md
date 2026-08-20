# Research and later

These trees are in the repo. They are not the Jarvis runtime. Do not mix them
into Heal, Galaxy chat, or Alexandria ingest.

Index: [`ARCHITECTURE.md`](../../ARCHITECTURE.md).

## Experimental routers (`127.0.0.1:8082`)

Root `main.go` and `godbrain_core/rust_router/` are non-privileged RAG router
alternatives. They cannot run together because they share port `8082`. Both use
the canonical loopback RAG service. Neither exposes the C++ kernel's
`command_type` dispatcher.

They provide similar graph/chat routes with different implementation tradeoffs.
CORS accepts trusted local/Tauri origins only.

The Rust router still uses search-only and returns `410` for `/api/graph` and
`/api/node`.

Useful for comparison. Deployment on this host uses the C++ kernel on `:8083`.

## Market research and contracts

Preserve the paper-only / read-only / no-signing guarantees in each subtree
README. Do not weaken them into signing, broadcast, account access, or
automatic limit changes.

| Tree | Status | Constraint |
|---|---|---|
| `godbrain_core/polymarket_paper/` | Experimental, CMake | Paper trading only |
| `godbrain_core/polygon_searcher/` | Experimental, CMake | Read-only search |
| `godbrain_core/polygon_observer/` | Experimental, CMake | Read-only observation |
| `godbrain_core/smart_contracts/` | Experimental Foundry | Pinned submodules; no approved deployment path |

Offline CMake tests use fixtures/fake transports. `POLYGON_RPC_URL` is only for
the explicitly selected read-only fork test documented in that subtree.

Native ingestors under `godbrain_core/cpp_ingestors/` and `cpp_tools/` are
standalone executables, not Heal.

## Agent Factory (later, not this host's next node)

A factory is allowed only when a named signal pays for the node (see
[Default control loop](../../ARCHITECTURE.md#default-control-loop)). This host
has one GPU slot and one `last_oracle.json`. Growing Alexandria is Librarian +
`/verify`, not Architect/Surgeon/Verifier agents.

See [`AGENT_FACTORY_ROSTER.md`](../../AGENT_FACTORY_ROSTER.md) if that contract
is ever staffed. Do not treat it as the backlog for Jarvis.

The five bullets that used to end `ARCHITECTURE.md` are Factory-era decisions.
They still correlate as long-horizon rails. They are not what moves the desk
forward. Ranked below against the Jarvis now-list in the index.

## Ranked later decisions

What actually moves Jarvis is in the index **Now vs later** section: Heal
verifier, Librarian candidates, phone GET glance, SRE diagnose-only, one GPU
mouth. Against that, the old five:

| Rank vs Jarvis | Old bullet | Verdict |
|---|---|---|
| 1 (constraint, not a ticket) | Add structured audit storage and recovery semantics **before** enabling autonomous privileged execution. Not a standing allow on BIOS, DISM, or registry cocktails. | **Still correlates as a rail.** The decision is already made: do not enable autonomous privileged execution. Do not build an audit plane in order to turn it on. Heal stays detect → allowlist → verify. Named GO per repair tool. |
| 2 (real later library work) | Define retention and supersession policy for immutable MongoDB source and Golden Record collections. | **Still correlates, later.** Sources and nodes are already immutable; only status changes. When the vault fills, you need how candidates supersede, how rejected/stale stay queryable, and what (if anything) may be deleted. Do this before inventing typed edges or Factory jobs. |
| 3 (only if privileged surface grows) | Replace coarse bearer authorization with short-lived capability grants. | **Correlates as Factory auth, not next.** Bearer + loopback + Tailscale-GET-needs-token is the current gate. Capability grants pay off when many agents share one kernel. This host has one operator and one loop. Do not expand `command_type` in order to need grants. |
| 4 (Galaxy nicety) | Decide whether typed `knowledge_edges` should be written by the Librarian and replace the current provenance co-occurrence stars in Galaxy. | **Optional later.** Stars from `rag_provenance` (`same_source` / `same_run`) are enough to browse. Typed edges are a second write path and a second way to be wrong. Staff only after the library has verified cards worth linking. |
| 5 (do not staff) | Define versioned HTTP, job, result, and evidence JSON Schemas. | **Factory job contracts.** Chat, RAG, and Librarian already have fail-closed shapes. Versioned job/evidence schemas are for a control plane this host is not hiring. Do not start a schema repo to look serious. |

If a sixth node is ever justified, the smallest honest one is still a
**candidate-vs-verified conflict queue** (overloaded verifier), not Architect /
Surgeon / a capability-grant service.
