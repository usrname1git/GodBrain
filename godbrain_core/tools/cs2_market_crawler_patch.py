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

RATE_LIMIT_DELAY = 6.0 

WEAPON_CLASSES = {
    "FAMAS": [
        "FAMAS | Bad Trip (Factory New)", "FAMAS | Bad Trip (Minimal Wear)",
        "FAMAS | Bad Trip (Field-Tested)", "FAMAS | Bad Trip (Well-Worn)", 
        "FAMAS | Bad Trip (Battle-Scarred)",
        "FAMAS | Rapid Eye Movement (Field-Tested)", "FAMAS | Mecha Industries (Field-Tested)",
        "FAMAS | Roll Cage (Field-Tested)", "FAMAS | Valence (Field-Tested)"
    ]
}
# Added Bad Trip specifically to the crawler

class CS2MarketCrawler:
    def __init__(self):
        logger.info("Initializing Bad Trip priority crawler...")
        self.targets = []
        for w_class, skins in WEAPON_CLASSES.items():
            self.targets.extend(skins)

    def fetch_price(self, market_hash_name):
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
                price_cache.update_one(
                    {"market_hash_name": market_hash_name},
                    {"$set": price_info},
                    upsert=True
                )
                logger.info(f"[CACHE UPDATED] {market_hash_name}: {price_info['lowest_price']} (Vol: {price_info['volume']})")
                return True
            else:
                logger.warning(f"Steam success=false for {market_hash_name}")
                return False
                
        except urllib.error.HTTPError as e:
            logger.error(f"HTTP Error {e.code} for {market_hash_name}. Starving API.")
            return False

    async def run_crawler_loop(self):
        logger.info(f"Loaded priority targets. Delay set to {RATE_LIMIT_DELAY}s.")
        while True:
            for skin in self.targets:
                cached = price_cache.find_one({"market_hash_name": skin})
                if cached and (time.time() - cached.get('timestamp', 0)) < (1 * 3600): # force 1 hr check
                    continue
                self.fetch_price(skin)
                await asyncio.sleep(RATE_LIMIT_DELAY)
            await asyncio.sleep(3600)

if __name__ == "__main__":
    crawler = CS2MarketCrawler()
    asyncio.run(crawler.run_crawler_loop())
