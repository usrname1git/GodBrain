import requests
from bs4 import BeautifulSoup
import time
from urllib.parse import urljoin, urlparse
from pymongo import MongoClient
import sys
import os

# Force UTF-8 for Windows Console to prevent cp1252 crash
sys.stdout.reconfigure(encoding='utf-8')

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import NodejsLibrarian

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

visited = set(doc['url'] for doc in db.visited_urls.find({"crawler": "nodejs"}, {"url": 1}))

queue = [
    "https://nodejs.org/api/documentation.html",
    "https://nodejs.org/en/learn/getting-started/introduction-to-nodejs",
    "https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick"
]

factory = NodejsLibrarian()

print("======================================================")
print("[GodBrain] Booting NODE.JS ECOSYSTEM HARVESTER (24/7/365)")
print("======================================================")

while True:
    if not queue:
        print("[NodeHarvester] Queue exhausted, re-seeding...")
        queue = [
            "https://nodejs.org/api/documentation.html",
            "https://nodejs.org/en/learn/getting-started/introduction-to-nodejs",
            "https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick"
        ]
        visited.clear()

    current_url = queue.pop(0).split('#')[0]
    
    if current_url in visited:
        continue
        
    print(f"\n[NodeHarvester] Target Locked: {current_url}")
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(current_url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            main_content = soup.find('main') or soup.find('article') or soup.body
            for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
                garbage.decompose()
                
            text = main_content.get_text(separator=' ', strip=True)
            title = soup.title.string.strip() if soup.title else "Node.js Documentation"
            
            factory.process_and_ingest(current_url, title, text)
            db.visited_urls.insert_one({"url": current_url, "crawler": "nodejs"})
            visited.add(current_url)
            
            new_links = 0
            for a in soup.find_all('a', href=True):
                href = a['href']
                full_url = urljoin(current_url, href).split('#')[0]
                parsed = urlparse(full_url)
                
                if parsed.netloc == "nodejs.org" and full_url not in visited and full_url not in queue:
                    queue.append(full_url)
                    new_links += 1
                    
            print(f"[NodeHarvester] Discovered {new_links} new internal nodes. Queue size: {len(queue)}")
            
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {current_url}: {e}")
        
    time.sleep(1.5)
