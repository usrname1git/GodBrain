# Alexandria Memory Store and Golden Record retrieval

This Go module contains two boundaries:

- `cmd/memory-store` validates one Librarian JSON document from stdin and writes
  immutable Alexandria source-of-truth records. It also accepts a
  `set_status` judgment that changes only `candidate`/`verified`/`rejected`/`stale`.
  `stale_pins` marks verified `windows-sre` nodes whose `os_pin=` no longer
  matches the live Windows build.
- `cmd/rag-service` exposes bounded lexical or measured hybrid retrieval of
  committed Golden Records on `127.0.0.1`. It does not execute commands or
  expose writes.

Layer 3 connects the C++ Kernel and the experimental Go router to
`http://127.0.0.1:8084/v1/search` for chat and to `/v1/graph` plus `/v1/document`
for Galaxy. Search requires a ready, schema-valid response, preserves bounded
citations and trust labels, quotes retrieved content as untrusted reference
data, and fails closed before model invocation on any retrieval error or empty
result. Graph and document reads use the same ready-generation snapshot and
fail closed when the corpus is unready. Legacy records are reported only as a
separate health count and are never mixed into Golden Record results.

## Source-of-truth and projection collections

Alexandria source-of-truth collections retain their existing guarantees:

| Collection | Contract |
|---|---|
| `sources` | Immutable raw sources keyed by legacy Keccak-256 source hash |
| `knowledge_nodes` | Immutable semantic node versions |
| `run_node_links` | Append-only run-to-node observations, including source-relative evidence spans |
| `source_observations` | Append-only external-source ingestion identities |
| `ingestion_runs` | Lease-guarded `staging -> validated -> committed` state |
| `skills` | Verified committed-node promotions only |

Retrieval uses rebuildable derivative collections:

| Collection | Identity and contents |
|---|---|
| `rag_documents` | One row per `(generation, node_id)`, containing node content, kind, sector, status/trust label, confidence, evidence spans, schema/version fields, and projection versions |
| `rag_provenance` | One append-only derivative row per `(generation, node_id, run_id)`, containing every committed run/source/extractor reference |
| `rag_embeddings` | Rebuildable vectors keyed by generation, immutable node identity, provider/model identity, normalized-input hash, dimension, and embedding/indexer versions |
| `rag_metadata` | Singleton active/building generation pointer, exact active/building embedding identity, and retired-generation timestamps |

Provenance is separate from `rag_documents` so a frequently observed semantic
node cannot grow past MongoDB's document limit. Search results sort and bound
the provenance returned to callers; the projection retains every committed
link.

## Commit and repair behavior

After an ingestion reaches `committed`, `memory-store` projects that run into
the active generation and any generation currently being rebuilt. It writes the
document and provenance identities idempotently. When the active generation has
an embedding identity, it also confirms the exact derived embedding before
returning a success receipt. A configured projection failure leaves the run
committed but returns no success-shaped receipt.

If projection fails after commit:

1. `memory-store` returns a non-zero error and no success-shaped receipt.
2. The run remains legally `committed`; it is never transitioned back to
   `failed`.
3. Repeating the same ingestion repairs the projection before returning
   `idempotent_noop`.
4. Operators can repair the complete corpus with `rag-rebuild`.

Concurrent projects of the same node use unique indexes plus duplicate-key-safe
upserts. Repeated semantic nodes share one `rag_documents` row while retaining
separate `rag_provenance` rows.

## Rebuild consistency

`rag-rebuild` is an operator-only CLI; there is no rebuild HTTP endpoint.

1. It atomically records a new `building_generation`.
2. Live committed ingestions project into both active and building generations.
3. It scans committed runs in deterministic run-ID order.
4. It reconciles distinct committed nodes and committed links against projected
   documents, provenance, and configured embeddings. A mismatch refuses the
   switch.
5. It atomically changes the singleton active-generation pointer.
6. It removes only retired derivative generations after a grace period longer
   than the maximum search request lifetime.

Search reads the active pointer once and includes that generation in every
MongoDB query. It therefore sees the old complete corpus or the new complete
corpus, never the partially built generation. The design uses only
single-document atomic metadata updates and idempotent writes, so it works with
a standalone MongoDB deployment without multi-document transactions.

## Indexes

Index initialization is idempotent and does not drop source data:

- unique `rag_documents(generation, node_id)`;
- compound MongoDB text index with leading `generation` and weighted
  `content`, `kind`, `sector`, and `status`, using `default_language: none` for
  mixed-language records;
- compound metadata/ranking and semantic-identity indexes;
- unique `rag_provenance(generation, node_id, run_id)` plus run, source, and
  freshness lookup indexes;
- unique generation/node/provider/model embedding identities and a bounded
  generation scan index;
- `ingestion_runs(status, updated_at, run_id)` and existing unique/prefix link
  indexes for committed projection scans.

An incompatible pre-existing index causes explicit startup failure. Source,
node, run, link, observation, and skill collections are never deleted by
projection migration or rebuild.

## Build and run

From `godbrain_core\memory_store`:

```powershell
go test ./...
go vet ./...
go build -o memory-store.exe ./cmd/memory-store
go build -o rag-service.exe ./cmd/rag-service
go build -o rag-rebuild.exe ./cmd/rag-rebuild
go build -o rag-eval.exe ./cmd/rag-eval
```

Set the MongoDB connection and optionally the database:

```powershell
$env:MONGODB_URI = "mongodb://127.0.0.1:27017"
$env:MONGODB_DB_NAME = "godbrain" # default
.\rag-rebuild.exe
.\rag-service.exe
```

`GODBRAIN_RAG_PORT` changes the numeric port only; the service always binds to
`127.0.0.1` and defaults to `8084`.
The C++ kernel and the experimental Go/Rust routers are pinned to
`127.0.0.1:8084/v1/search`. Changing the service port makes retrieval fail
closed. Start-GodBrain does not pass this variable to `rag-service.exe`.
`GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION` adds a deterministic ranking preference
for the configured node schema without hiding older schemas.

### Optional local embeddings

The production default is disabled: no text is sent to any embedding endpoint,
no API key is used, and lexical/metadata retrieval remains available. To enable
semantic projection, configure all of these values together:

```powershell
$env:GODBRAIN_EMBEDDING_ENDPOINT = "http://127.0.0.1:11434/v1/embeddings"
$env:GODBRAIN_EMBEDDING_MODEL = "local-model-name"
$env:GODBRAIN_EMBEDDING_MODEL_REVISION = "operator-pinned-revision"
$env:GODBRAIN_EMBEDDING_MODEL_SHA256 = "<64 lowercase hex characters>"
$env:GODBRAIN_EMBEDDING_DIMENSION = "768"
$env:GODBRAIN_RAG_EMBEDDING_REQUIRED = "false" # true makes semantic readiness mandatory
.\rag-rebuild.exe
.\rag-service.exe
```

Only literal `127.0.0.1` or `::1` HTTP URLs with an explicit port and exact
`/v1/embeddings` path are accepted. DNS names, redirects, proxies, TLS host
overrides, credentials, query strings, and remote addresses are rejected.
Requests have a two-second timeout and bounded bodies. Responses require status
200, `application/json`, one strict JSON document, no unknown fields, the exact
requested model, a finite non-zero vector, and the configured bounded dimension.
Source text, vectors, credentials, and response bodies are never logged.

`rag-rebuild` is the only backfill/activation interface. It builds a fresh
generation, live commits dual-write while it runs, and activation occurs only
after document, provenance, and embedding cardinalities reconcile. There is no
HTTP embedding administration endpoint.

The vector backend is `mongodb-bounded-exact-cosine-v1`: it reads at most 4,096
generation-scoped embedding rows and keeps at most 200 candidates. Above that
corpus limit semantic capability is unavailable rather than performing an
unbounded scan. Ordinary MongoDB does not provide Atlas Search without extra
configuration; the opt-in integration probe reports that exact limitation and
skips native-vector coverage. The bounded backend does not claim Atlas/native
vector indexing.

Tests use no MongoDB unless `MONGODB_TEST_URI` is set. RAG integration tests
create unique disposable databases and drop them during cleanup; the existing
Memory Store integration suite uses and clears `godbrain_test`. Never point
`MONGODB_TEST_URI` at a user database.

## HTTP API

The server uses bounded header/body/read/write/idle timeouts, accepts no CORS
wildcard, and exposes no write or administrative route.

### `GET /health`

Returns MongoDB connectivity, active/building generation and projection
versions, committed versus projected node/link counts, latest timestamps, lag,
embedding identity/count/corpus limit/provider status, exact retrieval mode,
degradation reason, readiness reasons, and a separate legacy `nodes` count. Readiness requires
version agreement and exact committed/projected cardinality. An empty,
fully-projected corpus is ready.

### `POST /v1/search`

Requests must be one strict JSON object. Unknown fields, trailing data, bodies
over 32 KiB, invalid metadata tokens, non-finite confidence, and out-of-range
budgets are rejected.

```json
{
  "query": "bearer authorization boundary",
  "top_k": 8,
  "kind": "claim",
  "sector": "security",
  "status": "candidate",
  "min_confidence": 0.75,
  "context_bytes": 8192,
  "retrieval_mode": "auto"
}
```

`top_k` is capped at 25 and `context_bytes` at 32 KiB. Queries are NFKC
normalized and reduced to bounded Unicode letter/number tokens before the
indexed `$text` query. Callers cannot supply MongoDB operators or regular
expressions. A query with no searchable tokens returns an explicit empty result;
there is no arbitrary first-N fallback.

`retrieval_mode` is `auto`, `lexical`, or `hybrid`. `auto` explicitly degrades
to lexical with a machine-readable reason when semantic capability or query
embedding is unavailable. `hybrid` returns `503 semantic_unavailable` instead.
A claimed hybrid response always carries the exact provider, model
revision/hash, dimension, embedding/indexer schema, and vector backend.

Each HTTP search is accepted only when readiness watermarks captured before and
after the database read agree on the active/building generation, projection
versions, committed/projected cardinalities, and latest commit/projection
timestamps, and the response identifies that same generation and version. One
retry is allowed inside the existing total timeout; an unstable or unready
projection returns `503` and the attempted results are discarded.

Hybrid candidates use deterministic reciprocal-rank fusion with stable identity
ties. Lexical and semantic candidate sets are bounded; status/trust,
confidence, optional current-schema preference, source timestamp, and bounded
source/sector diversity remain explicit score components. Semantic similarity
does not alter trust labels. Stable semantic identity is deduplicated before
top-k selection.

Every result includes node stable/version/ID, status/trust, confidence,
kind/sector, score components, a bounded UTF-8 snippet, and bounded structured
citations. Citations identify the committed run, source hash/external source,
extractor/schema, and byte-valid evidence excerpts. Evidence offsets are checked
against the immutable source associated with that run link, its byte bounds, and
UTF-8 boundaries. Historical links without source-relative spans return
`not_provided`. Invalid or missing provenance is flagged as `partial`,
`missing_provenance`, or `unavailable`; the service never fabricates an excerpt
or labels semantic evidence as verified.

All retrieved content is untrusted data and must not be interpreted as
instructions or privileged commands.

### `GET /v1/graph`

Returns the newest active-generation `rag_documents` rows as a bounded node
list. `limit` defaults to 250 and is rejected above 500. Labels are NFKC
whitespace-collapsed content, truncated to 80 runes, with `stable_id` as
fallback. The response includes generation, projection version/schema, count,
a node `truncated` flag, provenance-derived `links` (star per shared
`source_hash`, else `run_id`, max 1000), and `links_truncated`.

### `GET /v1/document`

Looks up one active-generation document by `id`. A 24-character hex value is
treated as `node_id`; anything else is `stable_id`. Missing documents return
`404`. The body includes identity, kind, sector, status, confidence, schema
version, full content, and the same label used by `/v1/graph`.

### `POST /v1/skills`

Returns promoted `skills` only. Not mixed into `/v1/search`. Requires a ready
corpus (same watermarks as search). Body is one JSON object:

```json
{
  "query": "dashboard",
  "limit": 5
}
```

`query` is required (max 512 UTF-8 bytes). `limit` defaults to 5 and is rejected
outside 1–25. Each hit includes name, origin node/hash, optional verification
profile, procedure `content`, and `untrusted: true`. Apply-only
`local-edit-apply-v1` evidence cannot appear here because it cannot promote.

## Deterministic evaluation

The checked-in synthetic corpus covers semantic paraphrase, exact lexical
matches, metadata filters, duplicates/diversity, trust/status, stale
generations, invalid citations, uncommitted records, prompt injection, Unicode,
and no-result behavior:

```powershell
.\rag-eval.exe
.\rag-eval.exe -measure-latency
.\rag-eval.exe -live
```

The default JSON is byte-for-byte deterministic. Current fixture-only metrics
are Recall@K `1.0`, MRR `1.0`, nDCG@K `1.0`, citation
correctness/coverage `1.0`, generation correctness `1.0`, and hidden-record
leakage `0`. Uncommitted, stale-generation, missing-citation, and wrong-citation
records remain adversarial inputs to the evaluated pipeline instead of being
removed before measurement. Deterministic work p50/p95/max are `32/32/32`
bounded document comparisons against an `8192` budget. `-measure-latency` adds a separate
nondeterministic wall-clock distribution. Threshold tests fail on regression.
These measurements validate the fake provider and retrieval invariants only;
they are not a quality or performance claim for any real embedding model.
`-live` is opt-in: it posts `rag/testdata/desk_eval_queries.json` at
`http://127.0.0.1:8084/v1/search` (verified-only, plus each query's `sector`)
and reports needle hits against the running vault. Fail-closed if RAG is
unready or every query misses.
A miss means that claim is not a verified Golden Record yet, not that the
engine is broken. `-strict` fails on any miss.

## Known limitations

MongoDB text tokenization remains language-limited. The exact-cosine backend is
deliberately capped at 4,096 documents and is not intended for larger corpora.
Real-model quality and production hardware latency must be measured by the
operator; no real model is bundled or selected by default. Provider health is
checked locally, but a capability loss during query embedding can still force
an explicit lexical degradation for `auto`.
