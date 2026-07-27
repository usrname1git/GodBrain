import requests
from bs4 import BeautifulSoup
import sys
import os

sys.stdout.reconfigure(encoding='utf-8')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import WindowsSRELibrarian

factory = WindowsSRELibrarian()

urls = [
    "https://github.com/M2Team",
    "https://github.com/M2Team/Privexec"
]

print("======================================================")
print("[GodBrain] INGESTING M2TEAM & PRIVEXEC (wsudo)")
print("======================================================")

for url in urls:
    print(f"\n[M2TeamHarvester] Target Locked: {url}")
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            # Look specifically for the GitHub README markdown body
            markdown = soup.find('article', class_='markdown-body')
            if markdown:
                text = markdown.get_text(separator=' ', strip=True)
            else:
                # Fallback to main content
                main_content = soup.find('main') or soup.body
                for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
                    garbage.decompose()
                text = main_content.get_text(separator=' ', strip=True)
                
            title = soup.title.string.strip() if soup.title else "M2Team Repository"
            
            factory.process_and_ingest(url, title, text)
            print(f"[M2TeamHarvester] Assimilated {title} into GodBrain.")
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {url}: {e}")
