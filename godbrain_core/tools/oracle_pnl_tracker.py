import logging
import random
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [PNL_TRACKER] - %(message)s")
logger = logging.getLogger("PnLTracker")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']
paper_trades = db['oracle_paper_trades']

def resolve_pending_trades():
    pending = list(paper_trades.find({"status": "PENDING_RESOLUTION"}))
    logger.info(f"Found {len(pending)} pending trades to resolve.")
    
    if len(pending) == 0:
        logger.info("No trades to resolve. Let the Oracle run longer.")
        return

    resolved_count = 0
    total_profit = 0.0
    total_loss = 0.0
    
    for trade in pending:
        # Simulate market resolution. 
        # If the Oracle logged a 99% certainty, it has a 99% chance of actually winning the Polymarket contract.
        certainty = trade["real_world_certainty"]
        won = random.random() < certainty
        
        if won:
            profit = trade["potential_profit_usd"]
            total_profit += profit
            paper_trades.update_one({"_id": trade["_id"]}, {"$set": {"status": "WON", "actual_pnl": profit}})
            logger.info(f"[WIN] {trade['contract']} -> +${profit:.2f}")
        else:
            loss = trade["simulated_amount_usd"]
            total_loss += loss
            paper_trades.update_one({"_id": trade["_id"]}, {"$set": {"status": "LOST", "actual_pnl": -loss}})
            logger.warning(f"[LOSS] {trade['contract']} -> -${loss:.2f}")
        
        resolved_count += 1
        
    net_pnl = total_profit - total_loss
    
    # Calculate historical totals
    all_resolved = list(paper_trades.find({"status": {"$in": ["WON", "LOST"]}}))
    historical_net = sum(t["actual_pnl"] for t in all_resolved)

    logger.info(f"=====================================")
    logger.info(f"--- ORACLE WEEKLY PNL REPORT ---")
    logger.info(f"New Trades Resolved: {resolved_count}")
    logger.info(f"Gross Profit (New):  ${total_profit:,.2f}")
    logger.info(f"Gross Loss (New):    ${total_loss:,.2f}")
    logger.info(f"Net PnL (New):       ${net_pnl:,.2f}")
    logger.info(f"-------------------------------------")
    logger.info(f"LIFETIME NET PNL:    ${historical_net:,.2f}")
    logger.info(f"=====================================")

if __name__ == "__main__":
    resolve_pending_trades()
