# Alexandria Memory Store and Golden Record retrieval

This Go module contains two boundaries:

- `cmd/memory-store` validates one Librarian JSON document from stdin and writes
  immutable Alexandria source-of-truth records.
- `cmd/rag-service` exposes bounded lexical retrieval of committed Golden
  Records on `127.0.0.1`. It does not execute models, commands, or writes.

Layer 2 connects the C++ Kernel and the experimental Go/Rust routers only to
`http://127.0.0.1:8084/v1/search`. They require a ready, schema-valid response,
preserve bounded citations and trust labels, quote retrieved content as
untrusted reference data, and fail closed before model invocation on any
retrieval error or empty result. Legacy records are reported only as a separate
health count and are never mixed into Golden Record search results.

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
| `rag_metadata` | Singleton active/building generation pointer and retired-generation timestamps |

Provenance is separate from `rag_documents` so a frequently observed semantic
node cannot grow past MongoDB's document limit. Search results sort and bound
the provenance returned to callers; the projection retains every committed
link.

## Commit and repair behavior

After an ingestion reaches `committed`, `memory-store` projects that run into
the active generation and any generation currently being rebuilt. It writes the
document and provenance identities idempotently and confirms that each distinct
run link is present before returning a success receipt.

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
   documents and provenance. A mismatch refuses the switch.
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
Layer 2 routers intentionally accept only the default port and exact
`/v1/search` path, so changing the service port makes router retrieval fail
closed.
`GODBRAIN_RAG_PREFERRED_SCHEMA_VERSION` adds a deterministic ranking preference
for the configured node schema without hiding older schemas.

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
readiness reasons, and a separate legacy `nodes` count. Readiness requires
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
  "context_bytes": 8192
}
```

`top_k` is capped at 25 and `context_bytes` at 32 KiB. Queries are NFKC
normalized and reduced to bounded Unicode letter/number tokens before the
indexed `$text` query. Callers cannot supply MongoDB operators or regular
expressions. A query with no searchable tokens returns an explicit empty result;
there is no arbitrary first-N fallback.

Each HTTP search is accepted only when readiness watermarks captured before and
after the database read agree on the active/building generation, projection
versions, committed/projected cardinalities, and latest commit/projection
timestamps, and the response identifies that same generation and version. One
retry is allowed inside the existing total timeout; an unstable or unready
projection returns `503` and the attempted results are discarded.

Candidates are reranked deterministically using lexical score, visible
status/trust, confidence, optional current-schema preference, source timestamp,
and bounded source/sector diversity. Stable semantic identity is deduplicated
before top-k selection.

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

## Known limitations

This is an indexed lexical and metadata baseline. Layer 2 router integration is
implemented, but there are no embeddings, vector index, semantic similarity, or
hybrid vector ranking claims. MongoDB text tokenization has language-specific
limitations even with explicit mixed-language behavior. Vector/hybrid retrieval
belongs to Layer 3.
