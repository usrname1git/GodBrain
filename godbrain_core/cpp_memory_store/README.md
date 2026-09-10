# C++ Alexandria Memory Store (cut 7)

Same stdin JSON door as Go `memory-store.exe`. Go under `godbrain_core/memory_store/`
stays. This tree is the C++ replacement; Start/Heal still launch Go until this
exe is tested against a disposable Mongo db (never the live `godbrain` db from
ctest).

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

Start/Heal still launch Go.

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
