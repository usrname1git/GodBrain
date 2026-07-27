import os
import sys
import logging
import asyncio
from datetime import datetime
from motor.motor_asyncio import AsyncIOMotorClient
from neo4j import GraphDatabase
from dotenv import load_dotenv

# Load environments gracefully
load_dotenv()

# Map tools folder so we can pull secrets securely without plain text env
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "tools"))
try:
    import ramvault_v2
except ImportError:
    ramvault_v2 = None

# Setup Logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("GodBrainCore")

class GodBrainEngine:
    """
    Unified engine for local-first memory management.
    Prioritizes MongoDB (Local) and syncs to Neo4j (Cloud) asynchronously.
    """

    def _get_env_or_vault(self, key, default=None):
        """Attempts to pull from Ghost Vault, falling back to OS env variables, then default."""
        if ramvault_v2:
            try:
                secret = ramvault_v2.get_secret(key)
                if secret:
                    return secret
            except SystemExit:
                pass # Vault locked or missing key
        return os.environ.get(key, default)

    def __init__(self):
        
        # MongoDB Config (Local)
        self.mongo_url = self._get_env_or_vault("MONGODB_URL", "mongodb://localhost:27017")
        self.mongo_client = AsyncIOMotorClient(self.mongo_url)
        self.mongo_db = self.mongo_client.shared_brain
        self.memories = self.mongo_db.memories
        
        # Neo4j Config (Cloud) - Using +ssc to bypass SSL issues
        self.neo4j_uri = self._get_env_or_vault("NEO4J_URI")
        self.neo4j_user = self._get_env_or_vault("NEO4J_USERNAME")
        self.neo4j_password = self._get_env_or_vault("NEO4J_PASSWORD")
        self.neo4j_db = os.environ.get("NEO4J_DB")
        
        if not all([self.neo4j_uri, self.neo4j_user, self.neo4j_password]):
            logger.error("[-] Neo4j credentials missing from environment.")
        
        self._neo4j_driver = None
        logger.info("[+] GodBrain Engine Initialized (Local-First)")

    def get_neo4j_driver(self):
        if not self._neo4j_driver:
            try:
                self._neo4j_driver = GraphDatabase.driver(
                    self.neo4j_uri, 
                    auth=(self.neo4j_user, self.neo4j_password)
                )
                # Test connection briefly
                self._neo4j_driver.verify_connectivity()
                logger.info("[+] Neo4j Cloud Linked")
            except Exception as e:
                logger.warning(f"[-] Neo4j Cloud offline/unauthorized: {e}")
                self._neo4j_driver = None
        return self._neo4j_driver

    async def save_thought(self, content, source="iPhone_Shortcut", tags=None, entities=None):
        """Saves a thought to MongoDB (Immediate) and Neo4j (Background)."""
        timestamp = datetime.utcnow()
        thought_doc = {
            "content": content,
            "source": source,
            "tags": tags or [],
            "timestamp": timestamp,
            "synced_to_graph": False
        }
        
        # 1. Local Write (Priority)
        try:
            res = await self.memories.insert_one(thought_doc)
            logger.info(f"[+] Thought captured locally: {res.inserted_id}")
        except Exception as e:
            logger.error(f"[-] Local MongoDB write failed: {e}")
            return None

        # 2. Background Cloud Sync
        asyncio.create_task(self._sync_to_graph(content, source, timestamp, entities))
        
        return str(res.inserted_id)

    async def _sync_to_graph(self, content, source, timestamp, entities):
        """Internal helper for Neo4j sync. Fails gracefully."""
        driver = self.get_neo4j_driver()
        if not driver:
            logger.info("[!] Neo4j sync skipped (Cloud offline)")
            return

        query = [
            "MERGE (m:Memory {text: $text})",
            "ON CREATE SET m.timestamp = $timestamp, m.source = $source",
            "MERGE (src:Source {name: $source})",
            "MERGE (m)-[:INGESTED_FROM]->(src)",
        ]
        params = {"text": content, "timestamp": timestamp, "source": source}

        if entities:
            for i, entity in enumerate(entities):
                label = entity.get("label", "Concept")
                name = entity.get("name")
                if name:
                    query.append(f"MERGE (e{i}:{label} {{name: $name_{i}}})")
                    query.append(f"MERGE (m)-[:REFERENCES]->(e{i})")
                    params[f"name_{i}"] = name

        try:
            with driver.session(database=self.neo4j_db) as session:
                session.run("\n".join(query), **params)
                # Mark as synced in MongoDB
                await self.memories.update_one(
                    {"content": content, "timestamp": timestamp},
                    {"$set": {"synced_to_graph": True}}
                )
                logger.info("[+] Cloud graph synchronized.")
        except Exception as e:
            logger.warning(f"[-] Cloud sync failed: {e}")

    async def get_recent(self, limit=5):
        cursor = self.memories.find().sort("timestamp", -1).limit(limit)
        thoughts = await cursor.to_list(length=limit)
        for t in thoughts:
            t["_id"] = str(t["_id"])
            if "timestamp" in t:
                t["timestamp"] = t["timestamp"].isoformat()
        return thoughts

if __name__ == "__main__":
    # Quick CLI Test
    engine = GodBrainEngine()
    async def test():
        await engine.save_thought("Test thought from Unified Engine", source="CLI_Test")
        recent = await engine.get_recent(1)
        print(f"Recent: {recent}")
    
    asyncio.run(test())
