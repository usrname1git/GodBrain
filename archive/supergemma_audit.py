import os
import json
import urllib.request
import hashlib
from collections import defaultdict

TARGET_DIR = r"C:\Temp\GitHub"
LOG_FILE = r"C:\Users\autismo\supergemma_audit_log.txt"
API_URL = "http://127.0.0.1:8080/v1/chat/completions"

def get_file_hash(filepath):
    hasher = hashlib.md5()
    try:
        with open(filepath, 'rb') as f:
            buf = f.read()
            hasher.update(buf)
        return hasher.hexdigest()
    except Exception:
        return None

def analyze_with_supergemma(prompt):
    data = {
        "messages": [
            {"role": "system", "content": "You are Supergemma, a strict and highly capable Senior Principal Security and Software Engineer. Analyze the provided code."},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.1,
        "max_tokens": 1024
    }
    req = urllib.request.Request(API_URL, data=json.dumps(data).encode('utf-8'), headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            res_body = response.read()
            return json.loads(res_body.decode('utf-8'))['choices'][0]['message']['content']
    except Exception as e:
        return f"Error analyzing: {e}"

def main():
    if not os.path.exists(TARGET_DIR):
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write(f"Target directory {TARGET_DIR} does not exist.\n")
        print(f"Directory {TARGET_DIR} not found.")
        return

    print(f"Scanning directory {TARGET_DIR}...")
    files_by_name = defaultdict(list)
    exact_duplicates = defaultdict(list)
    
    for root, _, files in os.walk(TARGET_DIR):
        if '.git' in root or 'node_modules' in root or '__pycache__' in root:
            continue
        for file in files:
            ext = os.path.splitext(file)[1].lower()
            if ext in ['.exe', '.dll', '.png', '.jpg', '.jpeg', '.zip', '.tar', '.gz', '.mp4', '.pdf', '.bin']:
                continue
                
            path = os.path.join(root, file)
            try:
                if os.path.getsize(path) > 100000: # Skip files > 100KB
                    continue
            except: pass
            
            files_by_name[file].append(path)
            h = get_file_hash(path)
            if h:
                exact_duplicates[h].append(path)

    with open(LOG_FILE, "w", encoding="utf-8") as log:
        log.write("=== Supergemma GitHub Audit Log ===\n\n")
        
        log.write("--- Exact Duplicates (Safely Delete Copies) ---\n")
        found_dupes = False
        for h, paths in exact_duplicates.items():
            if len(paths) > 1:
                found_dupes = True
                log.write(f"Identical files found (Hash: {h}):\n")
                for p in paths:
                    log.write(f" - {p}\n")
                log.write("\n")
        if not found_dupes:
            log.write("No exact duplicates found.\n\n")

        log.write("--- Code Analysis & Security Check ---\n")
        
        processed_hashes = set()
        for name, paths in files_by_name.items():
            if len(paths) > 1:
                log.write(f"\n[GROUP] Found {len(paths)} versions of '{name}'.\n")
                paths.sort(key=lambda x: os.path.getmtime(x), reverse=True)
                target_path = paths[0]
                log.write(f"Analyzing the most recently modified version: {target_path}\n")
                log.write("Recommendation for others: Compare against the newest and archive if redundant.\n\n")
            else:
                target_path = paths[0]
                
            h = get_file_hash(target_path)
            if h in processed_hashes:
                continue
            processed_hashes.add(h)
            
            try:
                with open(target_path, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read().strip()
            except Exception:
                continue
                
            if not content:
                continue

            prompt = f"Analyze the following script from my backup. Path: {target_path}\n\n"
            prompt += "Tasks:\n"
            prompt += "1. Find cleartext credentials (API keys, passwords, tokens). Flag them loudly.\n"
            prompt += "2. Identify outdated/deprecated libraries or techniques (e.g., old Windows 11 registry hacks, outdated Flask configs).\n"
            prompt += "3. Is it worth keeping or is it junk? Give a 1-sentence verdict.\n\n"
            prompt += f"Code Snippet:\n```\n{content[:6000]}\n```" # Truncate to save context
            
            print(f"Analyzing {target_path} with Supergemma...")
            analysis = analyze_with_supergemma(prompt)
            
            log.write(f"File: {target_path}\n")
            log.write(f"{analysis}\n")
            log.write("-" * 60 + "\n")

    print(f"\nAudit complete! Log written to: {LOG_FILE}")

if __name__ == '__main__':
    main()
