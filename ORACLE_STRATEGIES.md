# The Oracle Fleet: Arbitrage & Trading Strategies

To achieve financial independence and fund the acquisition of heavy compute (e.g., DGX Station/Spark), the GodBrain will deploy a fleet of specialized Oracle agents. Each agent focuses on a single, high-probability asynchronous data advantage.

## Phase 1: Paper Trading (Current)
All strategies must run in "Shadow Mode" for 14-30 days. Win rates must exceed 95% before live capital is allocated.

## Target Strategies

### 1. Prediction Market Latency (Polymarket / Kalshi)
*   **Target:** Physical events with absolute certainty but delayed market resolution.
*   **Examples:**
    *   **Weather Events:** API data (NOAA, local radar) shows rain is actively falling. Market closes in 2 minutes but still prices "Will it rain?" at 80%. Oracle buys the 20% margin.
    *   **Flight Delays:** FAA/FlightAware API confirms a plane has been diverted or delayed. Oracle buys the "Flight delayed" contract before market makers parse the data.

### 2. Fast-News Sentiment Snipe
*   **Target:** High-impact, structured news drops (e.g., SEC filings, FDA approvals, CPI data).
*   **Mechanic:** The Oracle connects directly to government RSS/API feeds. It parses the JSON/XML the millisecond it drops and executes trades on related assets *before* human traders read the headline.

### 3. On-Chain MEV (Maximal Extractable Value)
*   **Target:** Decentralized Exchanges (DEXs).
*   **Mechanic:** Monitor the mempool for large, unconfirmed transactions that will shift the price of a token. The Oracle pays a higher gas fee to front-run the transaction, profiting from the guaranteed price slippage.

### 4. Cross-Exchange Arbitrage (CEX/DEX)
*   **Target:** Price discrepancies between exchanges.
*   **Mechanic:** Token X is $1.00 on Binance and $1.02 on Uniswap. Oracle instantly buys on Binance and sells on Uniswap. Requires extremely low-latency execution and capital on both ends.

## Capital Allocation Rules
1. **Rule of Ruin:** Never risk more than 1% of the total pool on a single >95% probability event.
2. **Execution Speed:** Network latency must be under 50ms to the exchange API.
3. **No Emotions:** If the algorithm fails the shadow test, it is scrapped or refined. No manual overrides.
