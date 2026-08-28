# The Oracle Fleet: Research and Paper-Simulation Strategies

These are research directions, not promises of profit. Every strategy starts
with bounded, auditable paper evidence. No win-rate threshold, latency target,
backtest, quote, or simulation can make a trade certain.

## Phase 1: Paper simulation

Strategies must remain in shadow mode until their assumptions, costs, failure
modes, and realized paper PnL are independently reviewed. A high historical win
rate alone is not sufficient evidence for allocating capital.

## Target Strategies

### 1. Prediction Market Latency (Polymarket / Kalshi)
*   **Target:** Physical events with public data and delayed market prices. Not certain.
*   **Examples:**
    *   **Weather Events:** API data (NOAA, local radar) shows rain is actively falling. Market closes in 2 minutes but still prices "Will it rain?" at 80%. Oracle buys the 20% margin.
    *   **Flight Delays:** FAA/FlightAware API confirms a plane has been diverted or delayed. Oracle buys the "Flight delayed" contract before market makers parse the data.

### 2. Structured public-data research
*   **Target:** Public, structured releases such as regulatory filings or economic data.
*   **Mechanic:** Measure whether public-data parsing can produce a repeatable paper signal after realistic latency, spread, fees, and adverse-selection costs. Do not assume faster parsing creates a fair, executable, or profitable trade.

### 3. Atomic DEX backrun arbitrage research
*   **Target:** Same-chain cyclic price discrepancies across verified DEX quote sources.
*   **Mechanic:** Compare block-consistent exact-input quotes and model gas, bid reserve, slippage, safety margin, and execution-failure reserve. A future solver could compete to execute an atomic cycle after the state transition that creates the discrepancy.

Paying higher gas to front-run does **not** create guaranteed profit. A
front-run deliberately orders before another pending transaction. A sandwich
places transactions before and after a user's trade to worsen that user's
execution and extract value from it; that behavior is outside this project's
scope. A backrun executes after an observed state transition and can pursue an
independent price discrepancy without intentionally degrading a user's quoted
execution. Even an atomic backrun can lose its bid, fail simulation, be
outcompeted, be invalidated by a reorg, or earn less than modeled costs.

The paper-only Polygon searcher lives in
[`godbrain_core/polygon_searcher`](../godbrain_core/polygon_searcher/README.md).
The confirmed-chain boundary lives in
[`godbrain_core/polygon_observer`](../godbrain_core/polygon_observer/README.md).
The read-only adapter and replay boundary lives in
[`godbrain_core/polygon_pipeline`](../godbrain_core/polygon_pipeline/README.md).
Polygon's supported local stack is Bor plus Heimdall v2.

The observer accepts only loopback Bor JSON-RPC, requires chain ID 137, a
supported Bor client, completed sync, peers, and a recent canonical-format
block header. It excludes pending/txpool/mempool, signing, submission, account,
wallet, personal, and miner methods. Heimdall v2 is consensus infrastructure,
not a quote source, and must finish catching up before Bor is considered an
operator-ready dependency.

The pipeline reads one confirmed Bor block selected below the ready head,
rechecks its canonical hash around fixed-ABI exact-input calls, and provides
verified quote and conservatively modeled gas inputs to `polygon_searcher`.
Searcher output remains paper-only plans plus append-only audit evidence.
Separately, the observer may
ingest normalized successful-receipt evidence for externally allowlisted
two-venue/two-token atomic actions and export conservative per-token historical
rankings. Those public-chain aggregates are research inputs, not user targets
or profit guarantees.

A versioned data-only Atlas simulation envelope may carry a paper plan across
the next review boundary. It contains no solver or transaction calldata. Any
execution adapter remains a separate future security boundary. Signing,
submission, broadcasting, private keys, deployment, and chain-state mutation
are absent.

### 4. Cross-exchange arbitrage research (CEX/DEX)
*   **Target:** Price discrepancies between exchanges.
*   **Mechanic:** Paper-model both legs, transfer/custody constraints, latency, fees, inventory, and failure risk. A displayed price difference is not an executable profit.

## Capital Allocation Rules
1. **Capital preservation:** Strategy-specific compiled limits and loss latches must cap exposure; a confidence estimate is not certainty.
2. **Net accounting:** Evaluate realized results only after fees, gas, bids, slippage, failures, latency, and settlement.
3. **Fail closed:** Stale, mixed, malformed, unreconciled, non-atomic, or ambiguous state stops new paper cycles.
4. **Human review:** No strategy may auto-enable or raise its own limits. Any future live-capital decision requires a separate reviewed design and explicit authorization.
