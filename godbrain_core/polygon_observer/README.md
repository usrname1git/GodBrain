# GodBrain Polygon Confirmed-Chain Observer

This C++20 component provides a fail-closed, local-only observation boundary for
Polygon PoS mainnet. It targets the current supported node stack:

- **Bor v2.10.0** for execution, confirmed blocks, and Ethereum-compatible
  JSON-RPC;
- **Heimdall v2 v0.10.0** for Polygon consensus/checkpoint coordination.

This component exclusively supports the Bor and Heimdall v2 architecture.

The component never launches node processes, reads keys, signs, submits or
broadcasts transactions, installs services, deploys contracts, mutates chain
state, or queries pending/mempool data. It is independent of the FastLane,
Polymarket, and Alexandria implementations.

## Architecture and trust boundary

Bor is the only source of Ethereum-compatible execution data. Heimdall v2 is
documented as consensus infrastructure; this component does not treat Heimdall
as a transaction or quote source.

The built-in Bor RPC enum contains only:

- `web3_clientVersion`
- `eth_chainId`
- `eth_blockNumber`
- `eth_syncing`
- `net_peerCount`
- `eth_getBlockByNumber`
- `eth_getCode`
- `eth_call`
- `eth_getTransactionReceipt`

There is no string-based RPC method entry point. The enum structurally excludes
transaction submission, signing, account management, personal/wallet/miner
methods, pending block queries, txpool methods, and mempool methods.
`eth_getCode` accepts only a canonical lowercase address and explicit canonical
block number. `eth_call` accepts only `to` and bounded canonical calldata plus
an explicit canonical block number; pending tags, state overrides, batch
requests, transaction fields, and unbounded calldata are rejected. Health
fetches `eth_getBlockByNumber("latest", false)` and requires:

- chain ID exactly `137`;
- recognized Bor v2.10.0 client identity;
- a non-syncing node with peers;
- a canonical-format block hash and number;
- a recent, internally consistent head;
- bounded RPC latency.

Reachability is never readiness. JSON-RPC requests, responses, timeouts, IDs,
types, canonical hex quantities, and JSON nesting are bounded and validated.
Only explicit loopback endpoints (`127.0.0.1`, `[::1]`, or `localhost`) with a
port and path are accepted. Redirects, userinfo, fragments, queries, percent
encoding, ambiguous hosts, remote hosts, and non-HTTP(S) schemes are rejected.
WinHTTP uses no proxy, disables redirects, and retains normal HTTPS certificate
validation.

## Confirmed atomic-action evidence

The observer tracks public, already-confirmed, atomic two-venue/two-token
actions. It does not discover or target users and does not infer intent. A
separate decoder may derive candidate evidence from block-pinned Bor blocks and
successful receipts, but this component accepts the evidence only when all of
the following are explicit:

- chain 137, canonical block/transaction hashes, block timestamp/index, and
  observed head;
- the configured minimum confirmation depth (128 by default);
- one successful receipt and one transaction containing exactly two distinct
  allowlisted venues;
- exactly two allowlisted token deltas;
- two distinct venue log indices and at least two transfer log indices;
- all costs accounted in the supplied raw token deltas;
- at least one positive realized token delta;
- the exact externally reviewed allowlist revision.

The input is deliberately normalized rather than ABI-specific. GodBrain ships
no DEX or token addresses and invents no live address. An operator must provide
a reviewed JSON allowlist:

```json
{
  "schema_version": 1,
  "chain_id": 137,
  "revision": "<64 lowercase hex SHA-256 revision of the reviewed evidence bundle>",
  "venues": [
    {
      "address": "<canonical lowercase address>",
      "label": "<reviewed venue name>",
      "source_url": "https://<external source>",
      "source_sha256": "<64 lowercase hex digest of source evidence>"
    }
  ],
  "tokens": [
    {
      "address": "<canonical lowercase address>",
      "label": "<reviewed symbol>",
      "decimals": 18,
      "source_url": "https://<external source>",
      "source_sha256": "<64 lowercase hex digest of source evidence>"
    }
  ]
}
```

At least two entries are required in each category. HTTP sources, uppercase or
non-canonical addresses, unknown fields, duplicate addresses, wrong-chain
lists, and mismatched revisions fail closed.

## Registry, rankings, and tuning exports

Each accepted transaction is stored as one immutable JSON file in the registry
directory. Publication uses a same-directory pending file followed by an
atomic rename under an OS-managed exclusive registry lock. The lock is released
automatically if a process exits. Restart loading is deterministic, duplicate
transactions are idempotent, conflicting duplicates fail, and every record has
a deterministic FNV-1a corruption checksum. This checksum detects accidental
corruption; it is not a cryptographic authenticity mechanism. Authenticity
remains anchored in the reviewed source SHA-256 digests and allowlist revision.

Rankings default to a configurable seven-day window and aggregate **per token**;
raw units from different tokens are never added or converted into a fictional
common value. Arbitrary-precision signed decimal arithmetic avoids uint256
overflow. Output ordering is deterministic by token, realized raw PnL, and
actor. Confidence is computed from confirmation depth and attribution
evidence, never supplied by the input:

- 8,000 bps base for validated receipt/log/cost evidence;
- +500 bps when actor and executor are identical;
- +500 bps at twice the configured confirmation depth.

Confidence is not certainty. Rankings are public-chain research aggregates, not
target lists or profitability claims. JSON and CSV rankings include raw PnL,
token decimals, action count, and minimum confidence. The tuning export
aggregates confirmed action count, positive action count, raw per-token PnL,
venue pair, and minimum confidence; it does not change strategy limits.

## Build and test

From a Visual Studio Developer PowerShell:

```powershell
cmake -S godbrain_core\polygon_observer -B build\polygon-observer -DBUILD_TESTING=ON
cmake --build build\polygon-observer --config Release
ctest --test-dir build\polygon-observer -C Release --output-on-failure
```

MSVC uses C++20 with `/W4 /WX /permissive-`; other compilers use
`-Wall -Wextra -Wpedantic -Werror`. Tests use fake transports and synthetic
reserved fixture addresses only. No test contacts a node. A real-node smoke
test is absent and therefore skipped by default.

## CLI

```powershell
$observer = "build\polygon-observer\Release\godbrain-polygon-observer.exe"

# Local Bor health only
& $observer status `
  --endpoint http://127.0.0.1:8545/ `
  --heimdall-status-endpoint http://127.0.0.1:26657/status `
  --json

# Offline validation and render-only node planning
& $observer validate-config `
  --config godbrain_core\polygon_observer\examples\operator-config.json --json
& $observer render-config `
  --config godbrain_core\polygon_observer\examples\operator-config.json --json

# Validate external address evidence, then ingest normalized confirmed actions
& $observer validate-allowlist --allowlist reviewed-allowlist.json --json
& $observer ingest --allowlist reviewed-allowlist.json `
  --registry D:\PolygonResearch\confirmed-actions `
  --input decoded-confirmed-actions.json --min-confirmations 128 --json

# Deterministic seven-day research exports
& $observer rank --allowlist reviewed-allowlist.json `
  --registry D:\PolygonResearch\confirmed-actions `
  --as-of 1786593600 --window-days 7 --format json
& $observer rank --allowlist reviewed-allowlist.json `
  --registry D:\PolygonResearch\confirmed-actions `
  --as-of 1786593600 --window-days 7 --format csv
& $observer tuning --allowlist reviewed-allowlist.json `
  --registry D:\PolygonResearch\confirmed-actions `
  --as-of 1786593600 --window-days 7 --format json
```

Logs are bounded structured events and never dump environments or evidence
payloads. Sensitive configuration key names are rejected, and no credential or
key environment variable is read.

## Render-only Bor + Heimdall v2 operator plan

[`examples/operator-config.json`](examples/operator-config.json) points at the
user's source/build roots under `C:\Polygon_Bor` and
`C:\Polygon_Heimdall_v2`; the legacy `C:\Polygon_Heimdall` tree is not used.
Data directories remain placeholders for the future SSD.

Rendering produces argument arrays and PowerShell previews only:

- Bor `server --chain=mainnet`, explicit data directory, local Heimdall REST,
  loopback HTTP, `eth,net,web3,bor` namespaces, IPC disabled, WebSocket
  disabled, full GC, snap sync, and snapshots enabled;
- Heimdall v2 `start` with an explicit Windows home directory.

The manifest also lists required reviewed `app.toml`/`config.toml` settings:
loopback API/CometBFT endpoints, Bor RPC, mainnet chain, and a separate
**loopback Ethereum L1 endpoint**. Heimdall requires Ethereum L1; this component
will not silently point it at remote infrastructure. Official Polygon guidance
requires Heimdall `localhost:26657/status` to report
`result.sync_info.catching_up: false` before Bor starts. The renderer does not
edit TOML files, initialize data directories, download snapshots, or start
either process.

Official current guidance recommends roughly 8 TB for a mainnet full node with
buffer and publishes community snapshot sizes/providers. The sample records an
8,192 GiB operator expectation, not an enforced universal requirement. Recheck
current sizing and snapshot hashes when the SSD arrives.

## Integration boundary

[`polygon_searcher`](../polygon_searcher/README.md) remains a paper-only
block-pinned exact-quote searcher. The
[`polygon_pipeline`](../polygon_pipeline/README.md) binds the observer's
confirmed explicit-block calls to the searcher through a narrowly fixed
Uniswap-V2-compatible `getAmountsOut` adapter. A future decoder may use this observer's
confirmed Bor block/receipt boundary to produce normalized historical actor
evidence. Quote observations feed the searcher; confirmed-action rankings feed
research/tuning only. Neither path creates transactions.

Atlas simulation and any execution adapter remain separate future components
requiring independent security review and explicit authorization. Signing,
submission, broadcasting, private keys, live deployment, user targeting, and
chain-state mutation are absent.

## Official sources

Research baseline: **2026-08-13**.

- Bor v2.10.0 release and immutable commit
  [`82d3b610`](https://github.com/0xPolygon/bor/tree/82d3b610d48468462a504245b5839de66dc86272)
- Bor chain/RPC flags
  [`internal/cli/server/flags.go`](https://github.com/0xPolygon/bor/blob/82d3b610d48468462a504245b5839de66dc86272/internal/cli/server/flags.go)
- Bor chain ID 137
  [`params/config.go`](https://github.com/0xPolygon/bor/blob/82d3b610d48468462a504245b5839de66dc86272/params/config.go)
- Bor RPC implementations
  [`internal/ethapi/api.go`](https://github.com/0xPolygon/bor/blob/82d3b610d48468462a504245b5839de66dc86272/internal/ethapi/api.go)
- Heimdall v2 v0.10.0 immutable commit
  [`55ebf0a5`](https://github.com/0xPolygon/heimdall-v2/tree/55ebf0a5bf23e08f6084972d30769c808c6935ed)
- Heimdall v2 init/start and mainnet chain ID
  [`README.md`](https://github.com/0xPolygon/heimdall-v2/blob/55ebf0a5bf23e08f6084972d30769c808c6935ed/README.md)
- Heimdall v2 mainnet application template
  [`app.toml`](https://github.com/0xPolygon/heimdall-v2/blob/55ebf0a5bf23e08f6084972d30769c808c6935ed/packaging/templates/config/mainnet/app.toml)
- Official node sequence, versions, and sync check:
  <https://docs.polygon.technology/pos/how-to/full-node/full-node-binaries>
- Official prerequisites and storage guidance:
  <https://docs.polygon.technology/pos/how-to/prerequisites>
- Official snapshot guidance:
  <https://docs.polygon.technology/pos/how-to/snapshots>
