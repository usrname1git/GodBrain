# Top 10 Polymarket paper-training candidates

Paper-only hypotheses for the simulation engine. Not live execution, not a
signed order, not a guaranteed edge. `godbrain_core/polymarket_paper/` stays
read-only. Rank is "might be measurable in a paper loop," not "will print."

Target markets where the outcome is **API-checkable** and latency might beat a
human refresh. Every edge below is an assumption to measure, then `/verify` or
`/reject`.

## 1. Localized Weather Events
*   **Market Example:** "Will it rain in Miami by 12:00 PM on Friday?"
*   **Data Source:** NOAA APIs, AccuWeather radar, or even scraping local airport METAR reports.
*   **Paper hypothesis:** Radar can lead a resolution clock. Still a lag to
    measure, not a live fill.

## 2. YouTube/Spotify View Metrics
*   **Market Example:** "Will MrBeast's new video reach 50M views by Sunday?"
*   **Data Source:** Direct polling of the YouTube Data API.
*   **Paper hypothesis:** View velocity is observable before resolution. Not a
    guarantee the market is mispriced, and not a live buy.

## 3. Macroeconomic Data Drops (CPI / Jobs Reports)
*   **Market Example:** "Will US Core CPI be > 3.0% for July?"
*   **Data Source:** Bureau of Labor Statistics (BLS) JSON/RSS feeds.
*   **Paper hypothesis:** Official prints land at a known timestamp. A paper
    bot can timestamp the feed vs the book. This repo does not execute.

## 4. Rocket & Space Launches
*   **Market Example:** "Will SpaceX Starship Flight 6 launch before October?"
*   **Data Source:** FAA Temporary Flight Restrictions (TFRs), Coast Guard Notice to Mariners (NOTMAR), and FCC licensing APIs.
*   **Paper hypothesis:** Missing TFR/NOTMAR is evidence against a near-term
    launch, not a 0% probability and not a live order. 

## 5. Crypto Asset Price Targets
*   **Market Example:** "Will Bitcoin hit $80,000 in July?"
*   **Data Source:** Direct WebSocket connections to Binance/Coinbase order books.
*   **Paper hypothesis:** Spot venues can move before a resolution oracle.
    Latency is an assumption to measure. No signing.

## 6. Flight Delays & Aviation
*   **Market Example:** "Will Flight X from JFK to LHR be delayed by > 2 hours?"
*   **Data Source:** ADS-B Exchange APIs, FlightAware.
*   **Paper hypothesis:** A plane still on the ground elsewhere is evidence of
    delay risk, not a guaranteed resolution and not a live trade.

## 7. Box Office Grosses
*   **Market Example:** "Will Deadpool 3 gross > $150M opening weekend?"
*   **Data Source:** Scraping Fandango/AMC API seat maps for 50+ bellwether theaters.
*   **Paper hypothesis:** Bellwether seat maps may lead weekend estimates.
    Accuracy is unknown until measured. Not 99%, not live.

## 8. Supreme Court / Legal Decisions
*   **Market Example:** "Will the Supreme Court overturn Chevron deference?"
*   **Data Source:** SCOTUS website RSS feed / PDF scrapers.
*   **Paper hypothesis:** Opinions drop on a clock. Parsing keywords is a
    research task. This repo does not execute.

## 9. Political Election Calls (Micro-Races)
*   **Market Example:** "Who will win the NY District 14 Primary?"
*   **Data Source:** AP Election APIs, county-level clerk data feeds.
*   **Paper hypothesis:** County feeds can lead a TV call. Still candidate
    until verified; no live order.

## 10. Fed Interest Rate Decisions
*   **Market Example:** "Will the Fed cut rates by 25bps in September?"
*   **Data Source:** Federal Reserve press release XML feed.
*   **Paper hypothesis:** The statement lands on a clock. Parsing it is
    measurable in paper. Instant live trade is out of scope.
