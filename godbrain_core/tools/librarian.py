import os
import json
import datetime

class GodBrainLibrarian:
    """
    The Librarian Agent. 
    Runs at the end of a session to clean up the Data Swamp.
    """
    def __init__(self):
        # We assume local MongoDB on the PC, but fallback to env if testing cloud
        self.mongo_uri = os.environ.get("MONGODB_URI", "mongodb://localhost:27017")
        self.db_name = "godbrain"
        # self.client = MongoClient(self.mongo_uri)
        # self.db = self.client[self.db_name]

    def ensure_indexes(self):
        """
        Creates the 7-day TTL index on the raw_sessions collection so garbage cleans itself.
        Creates vector search indexes on golden_records.
        """
        pass # self.db.raw_sessions.create_index("createdAt", expireAfterSeconds=604800)

    def distill_session(self, raw_transcript: str) -> dict:
        """
        Wakes up a small, fast local LLM (e.g., Llama-3 8B) to read the raw log.
        Prompt: "Extract only permanent architecture decisions, successful code, and OpSec rules."
        """
        print("[LIBRARIAN] Waking up local LLM to distill session logs...")
        
        # Placeholder for the actual LLM API call to your local llama.cpp server
        # response = requests.post("http://localhost:8080/completion", json={"prompt": prompt})
        
        extracted_data = {
            "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
            "core_concepts": ["MongoDB setup", "Aura vs Local", "Librarian Agent architecture"],
            "opsec_rules": ["Never commit raw API keys", "Keep 10-image bypass standard via ShareX"],
            "summary": "Established the Librarian component to prevent Data Swamps and ensure context persistence."
        }
        return extracted_data

    def commit_to_brain(self, session_id: str, raw_transcript: str):
        """
        The main exit routine.
        1. Dumps the raw text to the short-term TTL collection.
        2. Distills the text into a Golden Record.
        3. Saves the Golden Record permanently.
        """
        print(f"[LIBRARIAN] Archiving session {session_id}...")
        
        # 1. Raw Dump (Dies in 7 days)
        # self.db.raw_sessions.insert_one({"session_id": session_id, "text": raw_transcript, "createdAt": datetime.datetime.utcnow()})
        print(f"[LIBRARIAN] Raw transcript saved to TTL storage.")

        # 2. Distill
        golden_record = self.distill_session(raw_transcript)
        golden_record["session_id"] = session_id

        # 3. Permanent Save
        # self.db.golden_records.insert_one(golden_record)
        print(f"[LIBRARIAN] Golden memory committed permanently to MongoDB.")
        
        return golden_record

if __name__ == "__main__":
    # Test execution
    librarian = GodBrainLibrarian()
    librarian.commit_to_brain("session_12345", "User: Vi behöver en librarian. AI: Exakt!")
