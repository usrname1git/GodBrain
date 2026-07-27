import requests
from bs4 import BeautifulSoup
import time
from urllib.parse import urljoin, urlparse
from pymongo import MongoClient
import sys
import os

# Ensure the core module is in the path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

# Import our Agent Factory to use the exact same LLM injection pipeline
from godbrain_core.tools.ms_learn_agent import AgentFactory

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

# Load visited URLs from DB to persist across restarts
visited = set(doc['url'] for doc in db.visited_urls.find({}, {"url": 1}))

# Seed URLs focused on the entire Rust ecosystem
queue = [
    "https://doc.rust-lang.org/book/title-page.html",
    "https://doc.rust-lang.org/reference/introduction.html",
    "https://doc.rust-lang.org/std/index.html",
    "https://doc.rust-lang.org/rust-by-example/index.html"
]

factory = AgentFactory()

print("======================================================")
print("[GodBrain] Booting RUST LANGUAGE HARVESTER (24/7/365)")
print("======================================================")

while queue:
    current_url = queue.pop(0).split('#')[0]
    
    if current_url in visited:
        continue
        
    print(f"\n[RustHarvester] Target Locked: {current_url}")
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(current_url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            # mdBook (Rust docs) uses <main> or <div id="content">
            main_content = soup.find('main') or soup.find(id='content') or soup.body
            
            # Strip out navigation, sidebars, and code block UI buttons
            for garbage in main_content(["script", "style", "nav", "header", "footer", "aside", "div.buttons"]):
                garbage.decompose()
                
            text = main_content.get_text(separator=' ', strip=True)
            title = soup.title.string.replace(" - The Rust Programming Language", "").strip() if soup.title else "Rust Documentation"
            
            # Pipe straight to Colibri and MongoDB
            factory.process_and_ingest(current_url, title, text)
            
            db.visited_urls.insert_one({"url": current_url})
            visited.add(current_url)
            
            # Spider outwards within the Rust documentation domain
            new_links = 0
            for a in soup.find_all('a', href=True):
                href = a['href']
                full_url = urljoin(current_url, href).split('#')[0]
                parsed = urlparse(full_url)
                
                # Only stay within official Rust docs to avoid spidering the whole internet
                if parsed.netloc == "doc.rust-lang.org" and full_url not in visited and full_url not in queue:
                    queue.append(full_url)
                    new_links += 1
                    
            print(f"[RustHarvester] Discovered {new_links} new internal nodes. Queue size: {len(queue)}")
            
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {current_url}: {e}")
        
    # Be polite to the Rust servers
    print("[RustHarvester] Sleeping 1.5 seconds...")
    time.sleep(1.5)
