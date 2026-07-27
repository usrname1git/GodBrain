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

# 1 request every 6 seconds to stay under Steam's 429 threshold
RATE_LIMIT_DELAY = 6.0 

WEAPON_CLASSES = {
    "AK-47": [
        "AK-47 | Redline (Field-Tested)", "AK-47 | Slate (Field-Tested)", 
        "AK-47 | Vulcan (Field-Tested)", "AK-47 | Asiimov (Field-Tested)",
        "AK-47 | Ice Coaled (Field-Tested)", "AK-47 | Legion of Anubis (Field-Tested)",
        "AK-47 | Bloodsport (Field-Tested)", "AK-47 | Frontside Misty (Field-Tested)"
    ],
    "M4A4": [
        "M4A4 | Asiimov (Field-Tested)", "M4A4 | Neo-Noir (Field-Tested)",
        "M4A4 | The Emperor (Field-Tested)", "M4A4 | Desolate Space (Field-Tested)",
        "M4A4 | In Living Color (Field-Tested)", "M4A4 | Cyber Security (Field-Tested)",
        "M4A4 | Howl (Field-Tested)", "M4A4 | Spider Lily (Field-Tested)"
    ],
    "M4A1-S": [
        "M4A1-S | Printstream (Field-Tested)", "M4A1-S | Cyrex (Field-Tested)",
        "M4A1-S | Hyper Beast (Field-Tested)", "M4A1-S | Nightmare (Field-Tested)",
        "M4A1-S | Leaded Glass (Field-Tested)", "M4A1-S | Blue Phosphor (Factory New)",
        "M4A1-S | Decimator (Field-Tested)", "M4A1-S | Player Two (Field-Tested)"
    ],
    "AWP": [
        "AWP | Asiimov (Field-Tested)", "AWP | Atheris (Field-Tested)",
        "AWP | Neo-Noir (Field-Tested)", "AWP | Mortis (Field-Tested)",
        "AWP | Redline (Field-Tested)", "AWP | Hyper Beast (Field-Tested)",
        "AWP | Wildfire (Field-Tested)", "AWP | Chromatic Aberration (Field-Tested)"
    ],
    "Desert Eagle": [
        "Desert Eagle | Printstream (Field-Tested)", "Desert Eagle | Mecha Industries (Field-Tested)",
        "Desert Eagle | Conspiracy (Minimal Wear)", "Desert Eagle | Kumicho Dragon (Field-Tested)",
        "Desert Eagle | Trigger Discipline (Field-Tested)", "Desert Eagle | Code Red (Field-Tested)",
        "Desert Eagle | Ocean Drive (Field-Tested)"
    ],
    "FAMAS": [
        "FAMAS | Rapid Eye Movement (Field-Tested)", "FAMAS | Mecha Industries (Field-Tested)",
        "FAMAS | Roll Cage (Field-Tested)", "FAMAS | Valence (Field-Tested)",
        "FAMAS | Commemoration (Field-Tested)", "FAMAS | Styx (Minimal Wear)"
    ],
    "Galil AR": [
        "Galil AR | Cerberus (Field-Tested)", "Galil AR | Sugar Rush (Field-Tested)",
        "Galil AR | Eco (Field-Tested)", "Galil AR | Chromatic Aberration (Field-Tested)",
        "Galil AR | Rocket Pop (Field-Tested)", "Galil AR | Stone Cold (Field-Tested)"
    ]
}

class CS2MarketCrawler:
    def __init__(self):
        logger.info("Initializing Expanded CS2 Market Crawler...")
        # Flatten the dictionary into a single target list
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
        except Exception as e:
            logger.error(f"Error fetching {market_hash_name}: {e}")
            return False

    async def run_crawler_loop(self):
        logger.info(f"Loaded {len(self.targets)} priority targets. Delay set to {RATE_LIMIT_DELAY}s.")
        
        while True:
            for skin in self.targets:
                cached = price_cache.find_one({"market_hash_name": skin})
                if cached and (time.time() - cached.get('timestamp', 0)) < (12 * 3600):
                    continue
                
                self.fetch_price(skin)
                await asyncio.sleep(RATE_LIMIT_DELAY)
            
            logger.info("Main loadout cycle complete. Sleeping 1 hour.")
            await asyncio.sleep(3600)

if __name__ == "__main__":
    crawler = CS2MarketCrawler()
    asyncio.run(crawler.run_crawler_loop())
