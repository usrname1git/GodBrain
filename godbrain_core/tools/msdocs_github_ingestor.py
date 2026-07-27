import os
import sys
import shutil
import subprocess
import glob
from pathlib import Path
from pymongo import MongoClient

# Ensure the core module is in the path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

# We reuse the SREGodFactory which has the hardcore Kernel/SRE prompt
from godbrain_core.tools.sre_god_harvester import SREGodFactory

class MSLearnGithubIngestor:
    def __init__(self):
        self.factory = SREGodFactory()
        self.clone_dir = os.path.join(os.environ.get('TEMP', '/tmp'), 'godbrain_msdocs')
        
    def clone_repo(self, repo_url):
        repo_name = repo_url.split('/')[-1].replace('.git', '')
        target_dir = os.path.join(self.clone_dir, repo_name)
        
        if os.path.exists(target_dir):
            print(f"[MSDocsGit] Updating existing repo: {repo_name}")
            subprocess.run(["git", "-C", target_dir, "pull"], check=False)
        else:
            print(f"[MSDocsGit] Cloning {repo_url} into {target_dir}...")
            os.makedirs(self.clone_dir, exist_ok=True)
            subprocess.run(["git", "clone", "--depth", "1", repo_url, target_dir], check=True)
            
        return target_dir

    def process_markdown_files(self, repo_dir):
        # We only care about high-value SRE/Kernel paths
        # So we filter for markdown files inside directories that sound hardcore
        md_files = glob.glob(f"{repo_dir}/**/*.md", recursive=True)
        print(f"[MSDocsGit] Found {len(md_files)} markdown files in {repo_dir}.")
        
        keywords = ['kernel', 'debugger', 'sysinternals', 'performance', 'security', 'etw', 'memory', 'driver', 'power']
        
        count = 0
        for md_path in md_files:
            # Skip noise
            if 'includes' in md_path or 'images' in md_path or 'toc.md' in md_path:
                continue
                
            path_lower = md_path.lower()
            if any(k in path_lower for k in keywords):
                with open(md_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    
                # Skip tiny files
                if len(content) < 200:
                    continue
                    
                title = os.path.basename(md_path).replace('.md', '')
                source_pseudo_url = f"github://{os.path.basename(repo_dir)}/{os.path.relpath(md_path, repo_dir)}"
                
                print(f"[MSDocsGit] Injecting Markdown: {title}")
                self.factory.process_and_ingest(source_pseudo_url, title, content)
                count += 1
                
                # To prevent rate-limiting ourselves / exploding the CPU too fast
                import time
                time.sleep(1)
                
        print(f"[MSDocsGit] Finished processing {count} hardcore SRE files from {repo_dir}")

if __name__ == '__main__':
    repos = [
        "https://github.com/MicrosoftDocs/windows-driver-docs.git",
        "https://github.com/MicrosoftDocs/windows-itpro-docs.git"
    ]
    
    ingestor = MSLearnGithubIngestor()
    for repo in repos:
        repo_dir = ingestor.clone_repo(repo)
        ingestor.process_markdown_files(repo_dir)

