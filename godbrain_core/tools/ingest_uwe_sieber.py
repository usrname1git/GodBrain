import requests
from bs4 import BeautifulSoup
import sys
import os

sys.stdout.reconfigure(encoding='utf-8')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import WindowsSRELibrarian

factory = WindowsSRELibrarian()

urls = [
    "https://www.uwe-sieber.de/usbtreeview_e.html",
    "https://www.uwe-sieber.de/misc_tools_e.html"
]

print("======================================================")
print("[GodBrain] INGESTING S-TIER SRE TOOLS (UWE SIEBER)")
print("======================================================")

for url in urls:
    print(f"\n[UweHarvester] Target Locked: {url}")
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            # Remove scripts/styles
            for garbage in soup(["script", "style", "nav", "header", "footer", "aside"]):
                garbage.decompose()
                
            text = soup.get_text(separator=' ', strip=True)
            title = soup.title.string.strip() if soup.title else "Uwe Sieber Tool Doc"
            
            factory.process_and_ingest(url, title, text)
            print(f"[UweHarvester] Assilimated {title} into GodBrain.")
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {url}: {e}")
