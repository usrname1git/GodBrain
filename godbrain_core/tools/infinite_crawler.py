import requests
from bs4 import BeautifulSoup
import time
from urllib.parse import urljoin
from pymongo import MongoClient
import sys
import os

# Ensure the core module is in the path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

from godbrain_core.tools.ms_learn_agent import MicrosoftLearnAgent

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

# Load visited URLs from DB to persist across restarts
visited = set(doc['url'] for doc in db.visited_urls.find({}, {"url": 1}))

# Seed URLs focused on hardware, power, and optimization
queue = [
    "https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/",
    "https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options",
    "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/power-manager",
    "https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights"
]

agent = MicrosoftLearnAgent()

print("======================================================")
print("[GodBrain] Booting 24/7/365 Infinite Knowledge Harvester")
print("======================================================")

while True:
    if not queue:
        print("[InfiniteCrawler] Queue empty. Reseeding...")
        queue.append("https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/")
        time.sleep(10)
        
    current_url = queue.pop(0)
    
    # Strip anchors
    current_url = current_url.split('#')[0]
    
    if current_url in visited:
        continue
        
    print(f"\n[InfiniteCrawler] Target Locked: {current_url}")
    
    try:
        # Scrape and ingest into the GodBrain
        agent.scrape(current_url)
        
        # Mark as visited in the database
        db.visited_urls.insert_one({"url": current_url})
        visited.add(current_url)
        
        # Spider outwards: Extract new links to keep the crawler alive forever
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(current_url, headers=headers, timeout=10)
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            new_links = 0
            for a in soup.find_all('a', href=True):
                href = a['href']
                # Restrict spidering to Windows and Hardware topics to stay focused
                if href.startswith('/en-us/windows') or href.startswith('/en-us/sysinternals'):
                    full_url = urljoin("https://learn.microsoft.com", href).split('#')[0]
                    if full_url not in visited and full_url not in queue:
                        queue.append(full_url)
                        new_links += 1
                        
            print(f"[InfiniteCrawler] Discovered {new_links} new internal nodes. Queue size: {len(queue)}")
            
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {current_url}: {e}")
        
    # Be polite to Microsoft servers (wait 3 seconds between requests)
    print("[InfiniteCrawler] Sleeping 3 seconds to evade rate-limits...")
    time.sleep(3)
