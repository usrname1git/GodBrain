import requests
from bs4 import BeautifulSoup
import time
from urllib.parse import urljoin, urlparse
from pymongo import MongoClient
import sys
import os

sys.stdout.reconfigure(encoding='utf-8')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import WindowsSRELibrarian

client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

visited = set(doc['url'] for doc in db.visited_urls.find({"crawler": "windows_sre"}, {"url": 1}))

queue = [
    "https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options",
    "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/power-manager",
    "https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/",
    "https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-defender-application-control/wdac-and-applocker-overview",
    "https://learn.microsoft.com/en-us/sysinternals/",
    "https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing"
]

factory = WindowsSRELibrarian()

print("======================================================")
print("[GodBrain] Booting WINDOWS SRE HARVESTER (24/7/365)")
print("======================================================")

while True:
    if not queue:
        print("[WinSREHarvester] Queue exhausted, re-seeding...")
        queue = [
            "https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options",
            "https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/power-manager",
            "https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/",
            "https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-defender-application-control/wdac-and-applocker-overview",
            "https://learn.microsoft.com/en-us/sysinternals/",
            "https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing"
        ]
        visited.clear()

    current_url = queue.pop(0).split('#')[0]
    
    if current_url in visited:
        continue
        
    print(f"\n[WinSREHarvester] Target Locked: {current_url}")
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(current_url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            main_content = soup.find('main') or soup.find(role='main') or soup.body
            if main_content:
                for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
                    garbage.decompose()
                    
                text = main_content.get_text(separator=' ', strip=True)
                title = soup.title.string.replace(" | Microsoft Learn", "").strip() if soup.title else "Windows Internals Doc"
                
                factory.process_and_ingest(current_url, title, text)
                db.visited_urls.insert_one({"url": current_url, "crawler": "windows_sre"})
                visited.add(current_url)
                
                new_links = 0
                for a in soup.find_all('a', href=True):
                    href = a['href']
                    full_url = urljoin(current_url, href).split('#')[0]
                    parsed = urlparse(full_url)
                    
                    if parsed.netloc == "learn.microsoft.com" and ("/windows/" in href or "/windows-hardware/" in href or "/windows-server/" in href or "/sysinternals/" in href):
                        if full_url not in visited and full_url not in queue:
                            queue.append(full_url)
                            new_links += 1
                            
                print(f"[WinSREHarvester] Discovered {new_links} new internal nodes. Queue size: {len(queue)}")
            
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {current_url}: {e}")
        
    time.sleep(2)
