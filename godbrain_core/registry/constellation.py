import json
import os

def load_map():
    """Loads the spatial map of the system from constellation.json"""
    map_path = os.path.join(os.getcwd(), "constellation.json")
    if os.path.exists(map_path):
        with open(map_path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {"status": "No mapped constellation json found locally"}

def query(payload):
    """Placeholder for querying the constellation registry"""
    return {"status": "Registry queried successfully", "payload_echo": payload, "current_map": load_map()}
