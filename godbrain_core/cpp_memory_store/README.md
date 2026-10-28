# C++ Alexandria Memory Store (cut 16)

Same stdin JSON door as Go `memory-store.exe`. Go under `godbrain_core/memory_store/`
stays as rollback. Start/Heal prefer `build/cpp_memory_store/Release`
(`rag-service`, `rag-rebuild`) then the Go folder. Kernel and Librarian
resolve `memory-store.exe` the same way. Never write live `godbrain` from
ctest (use `godbrain_cpp_store_test`).

Cut 1 (offline, no Mongo): 15 MiB cap, unknown-field/trailing fail, ingest
validate (`trust_tier=candidate`, Keccak-256 `source_hash`), `set_status` DAG,
run DAG (committed never returns to failed).

Cut 2 (mongo-c-driver 1.30.9 at `C:\Tools\mongo-c-driver`): ingest + `set_status`
writes. Collections: `sources`, `source_observations`, `knowledge_nodes`,
`run_node_links`, `ingestion_runs`, `node_judgments`.

Cut 3: RAG projection after commit (`rag_documents`, `rag_provenance`,
`rag_metadata` seed `live-<uuid>`). `set_status` syncs projected `status`.

Cut 4: embedding projection. Same env as Go (`GODBRAIN_EMBEDDING_ENDPOINT` must
be exact `http://127.0.0.1:<port>/v1/embeddings` plus model/revision/sha256/
dimension together). Seeds `rag_metadata.embedding` on first insert, writes
`rag_embeddings`, fail-closed if metadata identity does not match the runtime.

Cut 5: `rag-rebuild.exe` — new `rebuild-<uuid>` generation, project all committed
runs, verify corpus counts (3 attempts), atomic switch of `active_generation`,
retire previous, delete retired generations after 30s. Concurrent rebuild
fail-closed. stdout one JSON report; logs on stderr.

Cut 6: `rag-service.exe` on `127.0.0.1:8084` (or `GODBRAIN_RAG_PORT`). GET
`/health`, POST `/v1/search` (lexical `$text`; hybrid is RRF fusion against
`rag_embeddings`, fail-closed if embeddings unavailable), GET `/v1/graph`, GET
`/v1/document`, POST `/v1/skills` (promoted `skills` collection, `untrusted`).

Cut 7: stdin `record_skill_run` / `promote_skill` / `query_skills`. Same allowlist
and gates as Go (`desk-v1` one fixture; `galaxy-html-v1` / `frontend-*-v1` two
distinct passing fixtures; `local-edit-apply-v1` cannot promote). Origin must be
verified, content-hash bound, linked to a committed run.

Cut 8: stdin `stale_pins`. Kernel `/observe` uses this on every valid observation,
not only when a disk checkpoint says `os_pin` moved:
verified `windows-sre` cards that carry a different `os_pin=` become `stale`
(not deleted). Learn-class cards without `os_pin=` stay verified. Already-stale
mismatches are counted so RAG projection can resync.
Every ASCII-whitespace-delimited pin value must match exactly; a build-number
prefix or a second conflicting pin cannot keep a card current. Sweeps stream
the complete matching corpus in Mongo `_id` order and 100-document batches,
rather than silently stopping after 500 cards. Cursor/projection errors fail
the request; this does not introduce new automatic verification.
Missing or unchanged kernel checkpoints cannot suppress reconciliation.
Unconfirmed Windows build reads fail before reconciliation or inventory writes;
This applicability sweep is independent of the source-maintenance cut below.

Cut 9: search citations load bounded `sources` and emit `evidence` spans
(`byte_valid` / `not_provided` / `invalid` / `partial`). Citation status is
`available` / `partial` / `missing_provenance` / `unavailable`.

Cut 10: `rag-eval.exe` offline hybrid fixture (`-corpus` path, default Go
testdata). `-live` queries loopback `:8084` with desk needles (`-desk`,
`-strict`). Desk file decode matches Go (unknown fields, duplicate ids,
needles). `--self-test` is offline. Thresholds match Go (Recall/MRR/nDCG ≥ 0.90,
citation 1.0, no leakage).

Cut 11: ingest `document` + `chunks` (Local-Document-Adapter). Same gates as Go:
metadata and chunks together, `content_sha256` of `raw_transcript`, contiguous
UTF-8 byte ranges, forbidden-secret scan, immutable `chunks` collection.

Cut 12: `rag-service` search retries once if generation/health moved mid-query
(Go `searchConsistently`). Unready or hybrid-without-embeddings still fail
closed on the first look.

Cut 13: offline snapshot self-test ports Go `http_test.go` searchConsistently
cases (stable snapshot, partial interleave, retry-fresh, rebuild bound, hybrid
identity). `search_before_gate` / `search_after_gate` are shared with
`rag-service`.

Cut 14: skill lookup rechecks current verified committed origin, exact
content/hash/version and latest passing profile/suite evidence. Relevance
within a bounded 100-promotion pool precedes recency. Stale, personal and
apply-only origins/evidence do not route. `memory-store query_skills` and
`rag-service /v1/skills` share the same read implementation; no read-time
writes or schema migration. Go rollback uses the same parity fixtures.

`cpp_skill_lookup` exercises actual joins in a uniquely named test database
when `MONGODB_TEST_URI` points at a disposable MongoDB instance; otherwise
CTest reports it skipped. Never use the live vault for integration tests.

Cut 15: stdin `{"command":"evidence","action":"next|status|complete"}` and
kernel loopback `POST /api/evidence` / `GET /api/evidence`. The authenticated
POST takes only `{}`; callers cannot select a source, submit a verdict, choose
a TTL or supply a clock. Heal runs the bounded serial loop after observation,
including host-only AFK ticks. No model, new daemon, paid API or GPU is involved.

The first maintenance tick persists the `evidence_maintenance` policy version.
Before that cutover, readers preserve the previous contract; afterward every
verified technical search/document/graph/skill read requires a current bound
check. Missing, expired, changed or failed evidence is withheld from verified
search and reported as `stale` by document/graph reads. Original source, node,
judgment and projection records are not rewritten by this temporal overlay.
Session origins inherit this check through canonical document reads; Continue
also rechecks cached procedures instead of replaying expired skill references.
The candidate query excludes temporally ineligible versions before applying
lexical/vector limits, so historical high-score hits cannot crowd out current
evidence. Final admission still checks the exact canonical binding and proof.

`evidence_checks` is mutable maintenance state, keyed by the exact node ID,
version and complete-content Keccak hash. `evidence_check_runs` is append-only
check evidence, separate from immutable `sources`, candidate claims and the
rebuildable retrieval projection. Admission rechecks canonical identity,
sector, status, committed linkage, proof pointer and maintenance version.
Checks expire after 24 hours for documents and 15 minutes for host observations;
successful checks schedule renewal halfway through that lifetime.

Discovery scans 32 verified nonpersonal canonical nodes per pass with a durable
wrapping cursor, joining committed provenance automatically. Reproducible sources
are preferred before selecting the newest run; an unsupported transcript cannot
mask an older reproducible source. Changed source bindings reconcile only while
idle, clear old lease/proof pointers, and require a new check. Equivalent runs
with the same usable source do not discard current proof.
Superseded observations retain daily recovery; a returning exact successor is
re-armed without being made fresh. Previously infinite retirement deadlines are
repaired during discovery. Content-Type changes require quote rechecking even
when the document body bytes are identical. Supported sources
are existing truth observations, host inventory, and legacy exact-body
Learn/Support sources. A byte change cannot renew the old version. If a
supported observation can be established again, the kernel ingests and judges
a separate exact observation through the existing authority path. Unrelated
interpretations are never automatically verified. Unsupported provenance is
not labeled fresh or silently discarded.

Claims have expiring exclusive leases. Results use lease-bound CAS and
idempotent delivery; an old/expired worker cannot overwrite a newer result.
Failed checks back off for 1, 2, 4, 8 and 16 minutes, escalate on the sixth
attempt, and retry daily rather than becoming permanent operator-owned cards.
Repeated crashes also reach this bounded-recovery state. GET reports at most
eight incidents grouped by reason/source, not a per-card approval list; Heal
persists `logs\last-evidence.json` and warns on newly exhausted recovery.
The worker starts at most four checks within a 45-second start budget; each
network/store operation retains its own timeout. This is not a hard 45-second
request deadline.
Replacement publication skips the interactive RAG-rebuild helper; projection
failures stay explicit and the existing Heal recovery owns rebuilds.

This cut is source maintenance, not continuous open-web discovery or proof of
semantic correctness. Local-model research/novelty curation remains the next
separate increment; the available 27B has not been qualified for it here.
No running deployment is implied by these source changes.

## Working shelves (native extension)

Cut 16: native-only `command="shelf"`, `action="post"|"read"` adds separate
`discussion_messages` and `research_notes` collections. Existing C++/Go
ingestion contracts remain unchanged; Go rollback does not implement this
extension. Working posts are immutable, journal-acknowledged, hash-bound
`trust="untrusted"` records, never Golden Records or automatic RAG projection.
Repeated host/shelf/scope/request identity is idempotent only for identical
content; conflicting retries fail explicitly.

Both operations require `shelf` (`discussion|research`) and `host_id`.
`scope` defaults to `technical`; `personal` is isolated. Posts require
`thread_id`, `request_id`, `text`, and a research `title`; `speaker` defaults
to `operator`. Optional `sources` hold provenance references, not verification.
Text is capped at 32,768 UTF-8 bytes, title/query at 512, and sources at
16 references of 2,048 bytes each. Reads accept a lexical `query`, a
`thread_id` or `exclude_thread_id` filter, and `limit` 1-20 (default 8).
Search uses the complete collection's text index, not just recent messages.
Unknown/authority fields, malformed UTF-8/JSON and conflicting filters fail.
The existing one-document stdin and one-JSON stdout contract still applies.

The kernel's bearer-authenticated `POST /api/shelf` supplies the actual
target host and can generate a request ID. `GET /api/shelf/schema` describes
the public write/read contract. `POST /api/index` accepts only `{}` and stores
a timestamped native hardware/capability snapshot in reserved research thread
`environment-index`, then atomically publishes its hash-bound local cache.
It never starts a model, rebuilds RAG, expands grants or verifies research.
Authenticated GET/POST `/api/context` returns that snapshot, current granted
roots, relevant provisional research, optional discussion continuity and
separately labeled canonical verified retrieval in a 4 KiB model context.
Missing/corrupt indexes and unavailable/invalid canonical retrieval are
explicit errors; personal context never queries technical RAG.
These routes are not exposed by the read-only Phone Desk listener.

`cpp_working_shelves` covers strict protocol validation and, when
`MONGODB_TEST_URI` is supplied, storage/search/isolation in
`godbrain_cpp_store_test`. The test removes only its unique host's working
records and checks that canonical collection counts remain unchanged.

## Build and validate

Start/Heal prefer this tree's Release exes, then Go.

```powershell
.\scripts\Fetch-MongoCDriver.ps1
```

```text
cmake -S godbrain_core\cpp_memory_store -B build\cpp_memory_store -DBUILD_TESTING=ON
cmake --build build\cpp_memory_store --config Release
ctest --test-dir build\cpp_memory_store -C Release --output-on-failure
build\cpp_memory_store\Release\memory-store.exe --self-test
build\cpp_memory_store\Release\rag-rebuild.exe
```

Live write smoke (disposable db only — never `godbrain`):

```powershell
$env:MONGODB_URI = "mongodb://127.0.0.1:27017"
$env:MONGODB_DB_NAME = "godbrain_cpp_store_test"
```
