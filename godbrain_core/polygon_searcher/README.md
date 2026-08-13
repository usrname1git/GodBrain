# Polygon DEX Arbitrage Searcher (Paper Only)

This component is a deterministic, transport-neutral C++20 search and paper
simulation core for ordinary two-token, two-venue cyclic arbitrage on Polygon:

```text
token A --exact-input quote on venue 1--> token B
token B --exact-input quote on venue 2--> token A
```

Supplying the opposite directional routes evaluates the reverse cycle as well.
The core has no networking, RPC, wallet, account, credential, calldata,
transaction, signing, submission, broadcast, swap, deployment, or chain-state
mutation surface. It cannot trade. It never asks an LLM to quote, optimize,
approve risk, or execute a paper cycle.

Fixture reports are **sanitized test evidence, not market evidence**. They do
not establish that an opportunity existed on Polygon or that any strategy is
profitable.

## Architecture and trust boundaries

`polygon_searcher_core` defines strict dependency-injected protocols:

| Protocol | Responsibility |
|---|---|
| `BlockProvider` | Supply one confirmed block context and re-check canonicality |
| `TokenMetadataProvider` | Supply token identity and explicit decimals |
| `ExactInputQuoteProvider` | Supply authoritative exact-input route quotes at that block |
| `GasCostProvider` | Supply bounded gas and a conservative input-token conversion |
| `Clock` | Supply deterministic time |
| `AuditStore` | Persist sanitized decisions, claims, PnL, incidents, and latches |
| `PaperExecutor` | Produce a deterministic paper-only result |

There is no HTTP or JSON-RPC implementation here. The separate
[`polygon_pipeline`](../polygon_pipeline/README.md) adapts
read-only `eth_call` results into `ExactInputQuote` records only after it verifies
the venue, router/quoter ABI, route, token metadata, response block, and quote
provenance. The searcher continues to represent venue/route identities
opaquely and invents no deployment address.

The future observer should target the local Polygon-native node stack and use
standard Ethereum execution APIs exposed by Bor. The currently provisioned
node directories are configuration inputs to that separate observer, not paths
baked into this search library:

- `C:\Polygon_Bor`
- `C:\Polygon_Heimdall`
- `C:\Polygon_Heimdall_v2`

Bor is the read-only execution/quote boundary; Heimdall provides Polygon PoS
consensus coordination and is not a DEX quoter. The observer must select and
validate the operational Heimdall generation separately. This component has no
node-process lifecycle, IPC, HTTP, or client-specific integration.

References:

- [Ethereum Execution APIs](https://ethereum.github.io/execution-apis/)
- [Polygon documentation](https://docs.polygon.technology/)

The pipeline emits a data-only Atlas simulation envelope from `ArbitragePlan`.
The smart-contract project has a separate, offline-tested typed Atlas
two-router simulation boundary. It is not integrated with this library: the
paper plan has no deployed solver/executor binding, ABI calldata, or approved
policy for deriving executable per-leg minima from observed quotes. Keeping
those inputs separate preserves this library's no-wallet, no-signing,
no-submission boundary and still requires block-pinned simulation and an
independent safety review:

- [FastLane Atlas documentation](https://docs.fastlane.xyz/)
- [FastLane Atlas source](https://github.com/FastLane-Labs/atlas)

## Deterministic search and accounting

All token quantities are unsigned integer base units. Token decimals are
metadata used to validate compiled whole-token ceilings; no binary floating
point is used. Percentage reserves use checked integer basis-point arithmetic
and round costs upward.

For an exact input `I`, first quote `Q1`, and second quote `Q2`:

```text
gross output       = Q2.amount_out
gross profit       = gross output - I
gas cost           = provider's native-gas conversion into input-token base units
bid reserve        = ceil(gross profit * configured Atlas/FastLane reserve bps)
safety margin      = ceil(I * configured safety bps)
adverse slippage   = ceil(gross output * 2 * per-leg slippage bps)
failure reserve    = ceil(I * configured execution-failure bps)
modeled costs      = gas + bid + safety + slippage + failure
expected net       = gross profit - modeled costs
net edge (bps)     = floor(expected net * 10,000 / I)
```

Acceptance requires a strictly positive expected net and the configured minimum
edge after every modeled cost. Gross spread, modeled costs, expected net, and
realized paper PnL remain distinct fields/events. A detected spread is never
reported as realized profit.

The optimizer sorts and deduplicates a caller-supplied input-size set, evaluates
at most 32 sizes per input token, and has no convergence loop. It compares
dimensionless net-edge basis points across input tokens, uses expected net base
units only within the same input token, and then applies a stable ID tie-break.
Route ordering, plan serialization, and the FNV-1a-based idempotency identifier
are deterministic. Creation/deadline times are excluded from the ID so rescans
of the same block and authoritative quotes remain idempotent. The identifier is
for replay/idempotency, not cryptographic authentication.

Every quote and gas conversion must match the requested block number, hash,
parent hash, and confirmed status. Pending, unknown, reorged, stale,
future-dated, malformed, mixed-block, low-confidence, or insufficient-depth
provider data is rejected. Canonicality, plan deadline, block age, both quote
ages, and gas-conversion age are checked again immediately before paper
execution.

## Risk controls

Defaults are intentionally conservative PAPER settings and are unrelated to
the Polymarket paper node:

| Control | Default | Compiled bound |
|---|---:|---:|
| Maximum routes | 32 | 128 |
| Maximum candidates per block | 64 | 256 |
| Maximum input sizes per token | caller supplied | 32 |
| Maximum gas | 350,000 gas units | 1,000,000 |
| Maximum quote age | 1,000 ms | 3,000 ms |
| Maximum block age | 1,500 ms | 3,000 ms |
| Plan lifetime | 750 ms | 3,000 ms |
| Minimum provider confidence | 9,500 bps | at most 10,000 bps |
| Minimum net edge | 50 bps (0.50%) | at least 1 bp |
| Adverse slippage | 25 bps per leg | 200 bps per leg |
| Safety margin | 30 bps of input | 200 bps |
| Execution-failure reserve | 25 bps of input | 200 bps |
| Atlas/FastLane bid reserve | 2,000 bps of gross profit | 5,000 bps |
| Gross cycle output sanity | at most 100x input | fixed 100x ceiling |
| Per-token paper notional | explicit; fixture uses 2.0 tokens | at most 10 whole tokens |
| Per-token UTC daily paper loss | explicit; fixture uses 0.25 token | at most 2 whole tokens |

Token and venue allowlists, per-token notional limits, and per-token daily loss
limits are mandatory and default empty, so an unconfigured searcher cannot run.
Configuration can only stay inside compiled maximums and floors. Only one
synchronous cycle can run at a time.

The emergency switch, daily paper loss threshold, executor error, malformed
paper result, block reorg before execution, and non-atomic/partial paper result
latch processing. The latter exists even though any future on-chain design
would have to be atomic. No latch auto-clears.

## Plans, persistence, and restart behavior

`ArbitragePlan` schema version 1 contains:

- exact block number/hash/parent and observation time;
- token IDs, symbols, decimals, route and venue identities;
- input, intermediate, gross output, gross spread, costs, net, and edge;
- quote providers, provenance, hashes, and gas-conversion provenance;
- confidence/gas constraints, creation time, deadline, and idempotency ID.

It is data only. The schema contains no calldata or transaction envelope.

`FileAuditStore` writes:

- `snapshot.json`, replaced atomically, with claimed/pending plan IDs,
  per-day/per-token realized paper PnL, reconciliation time, and kill latch;
- `audit.jsonl`, an append-only stream of sanitized opportunity decisions,
  accepted plan claims, paper settlements/fills, PnL, incidents, and
  completions.

State and every existing audit line are validated at startup. Missing write
access, malformed JSON, unsupported versions, and I/O errors fail loudly. A
claim is persisted as pending before paper execution. An ambiguous pending plan
found on restart becomes a reconciliation incident and latches processing
instead of repeating the cycle.

## Build, test, and replay

Requirements are CMake 3.25+, a C++20 compiler, and the repository's existing
`godbrain_core/cpp_kernel/json.hpp`. No package or network access is needed.

```powershell
cd godbrain_core\polygon_searcher
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

CMake enforces `/W4 /WX /permissive-` on MSVC or
`-Wall -Wextra -Wpedantic -Werror` elsewhere.

Run the checked-in deterministic replay:

```powershell
.\build\Release\polygon-searcher-replay.exe `
  .\tests\fixtures\polygon_quotes.json `
  .\build\fixture-report
```

The command writes reproducible `summary.json` and `summary.csv` files. The
fixture uses synthetic token/venue identities and deliberately contains no
live address, endpoint, credential, or profitability claim.

## Limitations

Authoritative quotes still cannot guarantee execution. Between observation and
future atomic inclusion, pool state, gas, ordering, competition, liquidity,
token behavior, reorgs, or Atlas auction outcomes may change. Provider
confidence is an adapter assertion that must be independently defined and
tested; it is not a probability. Paper fills omit network latency, builder
selection, validator behavior, failed inclusion, and adversarial tokens.

No profit is guaranteed. Live execution would require separate reviewed
components, contract verification, block-pinned simulation, adversarial tests,
operational controls, legal review, and explicit human authorization. None of
those capabilities exists in this component.
