import asyncio
import logging
import time
import urllib.request
import urllib.parse
import json
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - [CS2_MARKET_CRAWLER] - %(message)s")
logger = logging.getLogger("CS2Market")

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']
price_cache = db['cs2_price_cache']

# Strict rate limit: 1 request every 6 seconds = 10 per minute = 600 per hour.
# This prevents Steam from throwing a 429 Too Many Requests ban.
RATE_LIMIT_DELAY = 6.0 

TARGET_CATEGORIES = [
    "AK-47", "M4A4", "M4A1-S", "AWP", "Desert Eagle", "Karambit", "Butterfly Knife", "M9 Bayonet"
]

COMMON_SKINS = [
    "AK-47 | Redline (Field-Tested)",
    "M4A1-S | Printstream (Field-Tested)",
    "AWP | Asiimov (Field-Tested)",
    "Desert Eagle | Printstream (Field-Tested)",
    "AK-47 | Slate (Field-Tested)"
]

class CS2MarketCrawler:
    def __init__(self):
        logger.info("Initializing CS2 Rate-Limited Market Crawler...")

    def fetch_price(self, market_hash_name):
        """Fetches the price from Steam with strict starvation to avoid 429s."""
        encoded_name = urllib.parse.quote(market_hash_name)
        url = f"https://steamcommunity.com/market/priceoverview/?appid=730&currency=1&market_hash_name={encoded_name}"
        
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept-Language': 'en-US,en;q=0.9'
        }
        
        try:
            req = urllib.request.Request(url, headers=headers)
            response = urllib.request.urlopen(req)
            data = json.loads(response.read().decode('utf-8'))
            
            if data and data.get('success'):
                price_info = {
                    "market_hash_name": market_hash_name,
                    "lowest_price": data.get('lowest_price', 'N/A'),
                    "volume": data.get('volume', 'N/A'),
                    "timestamp": time.time()
                }
                # Upsert into MongoDB
                price_cache.update_one(
                    {"market_hash_name": market_hash_name},
                    {"$set": price_info},
                    upsert=True
                )
                logger.info(f"[CACHE UPDATED] {market_hash_name}: {price_info['lowest_price']} (Volume: {price_info['volume']})")
                return True
            else:
                logger.warning(f"Steam returned success=false for {market_hash_name}")
                return False
                
        except urllib.error.HTTPError as e:
            logger.error(f"HTTP Error {e.code} for {market_hash_name}. Rate limit hit?")
            return False
        except Exception as e:
            logger.error(f"Error fetching {market_hash_name}: {e}")
            return False

    async def run_crawler_loop(self):
        """Infinite loop that slowly trickles requests to build the database."""
        logger.info(f"Starting crawler loop. Strict delay set to {RATE_LIMIT_DELAY}s between requests.")
        
        while True:
            for skin in COMMON_SKINS:
                # Check if we already fetched it recently (within 12 hours)
                cached = price_cache.find_one({"market_hash_name": skin})
                if cached and (time.time() - cached.get('timestamp', 0)) < (12 * 3600):
                    logger.debug(f"Skipping {skin}, cache is fresh.")
                    continue
                
                logger.info(f"Fetching live data for: {skin}")
                self.fetch_price(skin)
                
                # The Golden Rule: Starve the API to stay under the radar
                await asyncio.sleep(RATE_LIMIT_DELAY)
            
            logger.info("Cycle complete. Resting for 1 hour before next cache refresh...")
            await asyncio.sleep(3600)

if __name__ == "__main__":
    crawler = CS2MarketCrawler()
    asyncio.run(crawler.run_crawler_loop())
