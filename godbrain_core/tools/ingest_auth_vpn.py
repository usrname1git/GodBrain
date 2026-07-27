import requests
from bs4 import BeautifulSoup
import sys
import os

sys.stdout.reconfigure(encoding='utf-8')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import GeneralDevLibrarian

factory = GeneralDevLibrarian()

urls = [
    "https://github.com/krissrex/google-authenticator-exporter",
    "https://github.com/autom8edIT/Cisco-VPN-autologin",
    "https://github.com/autom8edIT/Chrome-MFA-extension"
]

print("======================================================")
print("[GodBrain] INGESTING MFA & VPN AUTOMATION TOOLS")
print("======================================================")

for url in urls:
    print(f"\n[AuthHarvester] Target Locked: {url}")
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GodBrain/SovereignCrawler'}
        r = requests.get(url, headers=headers, timeout=10)
        
        if r.status_code == 200:
            soup = BeautifulSoup(r.text, 'html.parser')
            
            markdown = soup.find('article', class_='markdown-body')
            if markdown:
                text = markdown.get_text(separator=' ', strip=True)
            else:
                main_content = soup.find('main') or soup.body
                for garbage in main_content(["script", "style", "nav", "header", "footer", "aside"]):
                    garbage.decompose()
                text = main_content.get_text(separator=' ', strip=True)
                
            title = soup.title.string.strip() if soup.title else "Auth/VPN Tool Doc"
            
            factory.process_and_ingest(url, title, text)
            print(f"[AuthHarvester] Assimilated {title} into GodBrain.")
        else:
            print(f"[-] HTTP {r.status_code} on {url}")
    except Exception as e:
        print(f"[-] Harvester encountered turbulence on {url}: {e}")
