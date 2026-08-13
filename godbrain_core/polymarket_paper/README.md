# GodBrain Polymarket Paper Node

This is a **public-data, paper-trading simulator**. It cannot place, cancel, or
sign orders, access an account, use a wallet, or mutate Polymarket state. The
native transport exposes only HTTPS `GET`, and its host allowlist contains only:

- `https://gamma-api.polymarket.com` for bounded market discovery
- `https://clob.polymarket.com` for public order-book snapshots

There is deliberately no private key, API credential, HMAC, EIP-712, wallet,
authenticated WebSocket, POST/PUT/PATCH/DELETE, or live-mode code path.
`POLYMARKET_LIVE_ENABLED` and credential-named environment variables cause
startup to fail rather than enabling anything.

Polymarket currently publishes unified TypeScript and Python SDKs, not a native
C++ SDK. Its documented raw authenticated API would require implementing
signing and authentication in C++; that is outside this component's safety
boundary. This node must not be described or deployed as a live trader.

## Strategy and accounting

The scanner considers ordinary, active binary markets only. A market is
excluded unless:

- it has exactly `Yes` and `No` outcomes with distinct CLOB token IDs;
- `acceptingOrders=true`, `closed=false`, and `negRisk=false`;
- positive minimum-order and tick-size values are present;
- both public books match the discovered constraints and token IDs;
- snapshots are no more than the configured age (2 seconds by default);
- both sides have enough depth for equal simulated shares.

The repository requirement originally described collateral as USDC. Current
Polymarket product documentation calls the trading collateral **pUSD**; this
node therefore labels all paper cash, exposure, and PnL in pUSD. This naming
choice does not imply custody or conversion of any real asset.

For equal quantity `q`, the evaluator walks every consumed ask level:

```text
raw cost       = YES depth-walk cost + NO depth-walk cost
documented fee = sum(shares × configured fee rate × price × (1 − price))
slippage       = raw cost * configured slippage reserve
all-in cost    = raw cost + documented fee + slippage
merge value    = q pUSD
net edge       = (merge value - all-in cost) / all-in cost
```

An opportunity needs a net edge of at least 2%. All arithmetic uses signed
fixed-point integers at 0.000001 precision; binary floating point is not used.
API quantities are rounded down and acquisition costs are rounded up.

The runtime then fetches each book again immediately before its simulated leg.
The conservative fill model walks depth and applies adverse slippage to every
level. YES and NO legs are non-atomic. A failed second leg triggers a simulated
bid-side recovery attempt and latches the paper kill switch even if recovery
completes. Any unrecovered quantity is persisted as stranded exposure.

Paired positions remain unrealized until the configured merge/settlement delay
has elapsed. Only then is `q - actual simulated fill cost` written to realized
PnL. Detected edge, intents, fills, recoveries, positions, settlements,
rejections, and realized PnL are distinct audit events; a theoretical
top-of-book spread is never reported as realized profit.

Fees follow Polymarket's documented taker formula and round upward to the
documented five-decimal fee precision. The configurable fee-rate floor defaults
to `0.07`, the highest currently documented category rate, even for markets that
may be fee-free. This is deliberately conservative. Simulated fills cannot
reproduce queue position, exchange latency, adverse selection, matching-engine
downtime, chain confirmation, market suspension, or actual settlement.

## Hard risk limits

These ceilings are compiled into `Config` and configuration may only lower them:

| Limit | Hard ceiling |
|---|---:|
| Gross simulated acquisition per pair | 5 pUSD |
| Total open/stranded simulated exposure | 10 pUSD |
| UTC-day realized loss | 5 pUSD |

Only one paper cycle runs at a time. At a cumulative realized loss of 5 pUSD,
new cycles stop and the kill switch remains latched until the next UTC day.
Non-atomic leg failure also latches the switch and does not auto-clear.

The node never auto-scales or self-modifies these limits. Any future increase
must be a separate manual, reviewed code/configuration change after a meaningful
observation period demonstrates positive **net realized** paper PnL after
modeled fees/slippage, no unresolved reconciliation incidents, and successfully
tested kill switches. Increase limits in stages, not all at once. Paper results
are not evidence that a live implementation will be profitable.

## Persistence and evidence

The default state directory is `polymarket-paper-state/`:

- `snapshot.json` is atomically replaced and contains claimed opportunity IDs,
  open/stranded/merged positions, UTC PnL, reconciliation time, and kill state.
- `audit.jsonl` is append-only, sanitized evidence suitable for deterministic
  JSONL export and external analysis.

Opportunity IDs combine market ID, both authoritative CLOB book hashes, and
quantity. Claiming persists a `pending_opportunities` state before simulation,
so a process restart cannot submit the same paper cycle twice. A pending cycle
found at startup is an explicit reconciliation incident and latches the kill
switch instead of silently dropping unknown paper exposure. PnL event IDs are
also idempotent. Snapshot and append-only audit JSON are both validated at
startup. Missing, unwritable, unsupported-version, or malformed state fails
loudly; the node does not discard or silently reconstruct corrupt state.

Structured JSON logs and the `status` command expose paper-only mode, public-data
freshness, reconciliation state, simulated exposure, daily realized/unrealized
PnL, kill state, and the last error.

## Build and test

Requirements are CMake 3.25+, a C++20 compiler, and the repository's existing
`godbrain_core/cpp_kernel/json.hpp`. Windows runtime networking uses the OS
WinHTTP library; no package manager or new vendored dependency is required.

From a Visual Studio developer shell:

```powershell
cd godbrain_core\polymarket_paper
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

Safe commands:

```powershell
# One bounded public scan and paper evaluation.
.\build\Release\godbrain-polymarket-paper.exe scan-once

# Repeated bounded scans until Ctrl+C.
.\build\Release\godbrain-polymarket-paper.exe run

# Read local paper state without calling Polymarket.
.\build\Release\godbrain-polymarket-paper.exe status
```

`scan-once` and `run` perform read-only public network requests. Tests use
sanitized fixtures and fake transports and make no network requests.

## Configuration

| Environment variable | Default | Constraint |
|---|---:|---|
| `POLYMARKET_PAPER_MAX_PAIR_GROSS` | `5` | `(0, 5]` pUSD |
| `POLYMARKET_PAPER_MAX_TOTAL_EXPOSURE` | `10` | `(0, 10]` pUSD |
| `POLYMARKET_PAPER_MAX_DAILY_LOSS` | `5` | `(0, 5]` pUSD |
| `POLYMARKET_PAPER_MIN_NET_EDGE` | `0.02` | `[0.02, 0.25]` |
| `POLYMARKET_PAPER_FEE_RATE` | `0.07` | `[0, 0.25]` |
| `POLYMARKET_PAPER_SLIPPAGE_BPS_PER_LEG` | `50` | `0..500` |
| `POLYMARKET_PAPER_STALE_BOOK_MS` | `2000` | `1..10000` |
| `POLYMARKET_PAPER_SETTLEMENT_DELAY_MS` | `30000` | non-negative |
| `POLYMARKET_PAPER_DISCOVERY_PAGE_SIZE` | `50` | `1..100` |
| `POLYMARKET_PAPER_DISCOVERY_MAX_PAGES` | `1` | `1..20` |
| `POLYMARKET_PAPER_SCAN_INTERVAL_MS` | `3000` | at least `1000` |
| `POLYMARKET_PAPER_STATE_DIR` | `polymarket-paper-state` | writable local path |
| `POLYMARKET_PAPER_KILL_SWITCH` | `0` | set exactly `1` to latch at startup |
| `POLYMARKET_PAPER_KILL_SWITCH_FILE` | unset | existing file latches at startup/runtime |

There are intentionally no environment variables for secrets, wallets, account
addresses, proxies, private endpoints, or live activation.

Page size, page count, and scan interval are jointly validated against a
conservative public-book budget of 1,000 requests per 10 seconds, below the
documented 1,500-per-10-second `/book` limit. Individually valid values that
would exceed that combined budget are rejected at startup.

## Public API references

- [SDKs and APIs](https://docs.polymarket.com/getting-started/sdks-apis)
- [Direct API overview](https://docs.polymarket.com/getting-started/api)
- [Gamma list markets](https://docs.polymarket.com/api-reference/markets/list-markets)
- [CLOB get order book](https://docs.polymarket.com/api-reference/orderbook/get-order-book-summary)
- [Market WebSocket](https://docs.polymarket.com/api-reference/wss/market)

Discovery uses Gamma's stable `/markets/keyset` cursor pagination with a hard
100-item page ceiling and bounded page count. The implementation intentionally
uses fresh bounded REST snapshots rather than a market WebSocket cache.
Discovery changes the token set dynamically, every paper leg needs an
authoritative fresh snapshot, and the official WebSocket documentation provides
no replay or reconnect/resync contract. A new HTTPS GET is a new connection and
snapshot, so there is no persistent stream state to reconnect or accidentally
reuse after a gap.
