(The KnowledgeCommons rename without Constellation bloat)

"""
GodBrain Knowledge Commons
==========================

Global knowledge index that every AI agent can read from and write to.
Transforms individual solutions into collective intelligence.

Each agent contribution includes:
  - Problem solved
  - Solution approach
  - Tools required (and which were missing)
  - Knowledge tags for discovery
  - Confidence/reliability score
"""

import os
from datetime import datetime
from typing import Dict, List, Any, Optional
from enum import Enum
from pymongo import MongoClient
from dotenv import load_dotenv

load_dotenv()

class ProblemCategory(Enum):
    SYSTEM_HARDENING = "system_hardening"
    TOOL_GAP = "tool_gap"
    SERVICE_REMOVAL = "service_removal"
    WORKAROUND = "workaround"

class KnowledgeCommons:
    def __init__(self):
        self.mongodb_url = os.getenv("MONGODB_URL", "mongodb://localhost:27017/godbrain")
        self.db_name = os.getenv("MONGODB_DATABASE", "godbrain")
        self.commons_collection = "knowledge_commons"
        self.solutions_collection = "solved_problems"
        self.tool_gaps_collection = "tool_gaps_catalog"
        self.workarounds_collection = "workarounds_inventory"
        self.client = None
        self.db = None
        self._connect()
    
    def _connect(self):
        try:
            self.client = MongoClient(self.mongodb_url, serverSelectionTimeoutMS=5000)
            self.client.admin.command('ismaster')
            self.db = self.client[self.db_name]
            print(f"[Commons] Connected to shared database")
        except Exception as e:
            print(f"[Commons] Connection failed: {e}")
            self.client = None

commons = None

def get_knowledge_commons() -> KnowledgeCommons:
    global commons
    if not commons:
        commons = KnowledgeCommons()
    return commons