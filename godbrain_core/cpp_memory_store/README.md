# C++ Alexandria Memory Store (cut 11)

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

Cut 8: stdin `stale_pins`. Kernel `/observe` uses this when `os_pin` moves:
verified `windows-sre` cards that carry a different `os_pin=` become `stale`
(not deleted). Learn-class cards without `os_pin=` stay verified. Already-stale
mismatches are counted so RAG projection can resync.

Cut 9: search citations load bounded `sources` and emit `evidence` spans
(`byte_valid` / `not_provided` / `invalid` / `partial`). Citation status is
`available` / `partial` / `missing_provenance` / `unavailable`.

Cut 10: `rag-eval.exe` offline hybrid fixture (`-corpus` path, default Go
testdata). `-live` still uses Go. Thresholds match Go (Recall/MRR/nDCG ≥ 0.90,
citation 1.0, no leakage).

Cut 11: ingest `document` + `chunks` (Local-Document-Adapter). Same gates as Go:
metadata and chunks together, `content_sha256` of `raw_transcript`, contiguous
UTF-8 byte ranges, forbidden-secret scan, immutable `chunks` collection.

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
