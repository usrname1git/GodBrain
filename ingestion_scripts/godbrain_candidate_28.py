import os
import sys
import logging
import argparse
import asyncio
from dotenv import load_dotenv

load_dotenv()

# Setup logging for the debug connection
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s"))
logger = logging.getLogger("neo4j")
logger.addHandler(handler)

def get_driver():
    from neo4j import GraphDatabase
    uri = os.environ.get("NEO4J_URI", "neo4j+ssc://334f8d57.databases.neo4j.io")
    username = os.environ.get("NEO4J_USERNAME", "334f8d57")
    password = os.environ.get("NEO4J_PASSWORD")
    if not password:
        print("Error: NEO4J_PASSWORD environment variable not set.")
        exit(1)
    return GraphDatabase.driver(uri, auth=(username, password))

def test_connection():
    logger.setLevel(logging.DEBUG)
    uri = os.environ.get("NEO4J_URI", "neo4j+ssc://334f8d57.databases.neo4j.io")
    database = os.environ.get("NEO4J_DB", "334f8d57")
    
    print(f"[+] Starting connection probe to {uri}...")
    try:
        driver = get_driver()
        with driver:
            print("[+] Verifying connectivity...")
            driver.verify_connectivity()
            print(f"[+] Routing successful! Executing test query on '{database}' database...")
            summary = driver.execute_query("RETURN 'GodBrain is Online' as message", database_=database).summary
            print(f"[+] Success! Connected to: {summary.metadata.get('server')}")
    except Exception as e:
        print("\n[-] CONNECTION FAILED:")
        print(f"Type: {type(e).__name__}")
        print(f"Message: {e}")

def check_memory(filename):
    database = os.environ.get("NEO4J_DB", "334f8d57")
    driver = get_driver()
    try:
        with driver.session(database=database) as session:
            result = session.run("MATCH (m:Memory {filename: $filename}) RETURN m.text as text", filename=filename)
            record = result.single()
            if record:
                print(f"Text from {filename}:\n{record['text']}")
            else:
                print(f"No record found for {filename}")
    finally:
        driver.close()

def show_results(filename):
    database = os.environ.get("NEO4J_DB", "334f8d57")
    driver = get_driver()
    try:
        with driver.session(database=database) as session:
            result = session.run("""
            MATCH (m:Memory {filename: $filename})-[r:REFERENCES]->(e) 
            RETURN e.name as entity, labels(e) as type
            """, filename=filename)
            print(f"Knowledge Graph Entities extracted from {filename}:")
            for record in result:
                print(f"- {record['entity']} ({record['type'][0]})")
    finally:
        driver.close()

def query_models():
    database = os.environ.get("NEO4J_DB", "334f8d57")
    driver = get_driver()
    try:
        with driver.session(database=database) as session:
            result = session.run("MATCH (n:Model) RETURN n.id as id, n.name as name, n.downloads as downloads, n.best_use_case as use_case")
            print("Model Nodes in Knowledge Graph:")
            for record in result:
                print(f"ID: {record['id']}, Name: {record['name']}, Downloads: {record['downloads']}, Use Case: {record['use_case']}")
    finally:
        driver.close()

def test_ingestion(image_path):
    # Appending the parent directory so import god_brain_core works
    sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from universal_ingestion_engine import UniversalIngestionEngine
    
    engine = UniversalIngestionEngine()
    entities = [
        {"label": "Hardware", "name": "PCIE"},
        {"label": "Hardware", "name": "DIMM"},
        {"label": "Brand", "name": "Republic of Gamers"},
        {"label": "Series", "name": "Apex"},
        {"label": "Hardware", "name": "Motherboard"},
    ]
    try:
        engine.ingest_image(image_path, entities=entities)
        print("[+] Structured ingestion complete.")
    finally:
        engine.close()

async def check_sync():
    sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from godbrain_core.commands.memory import GodBrainEngine
    engine = GodBrainEngine()
    recent = await engine.get_recent(5)
    for t in recent:
        print(f"Content: {t['content']}, Synced: {t['synced_to_graph']}")

def main():
    parser = argparse.ArgumentParser(description="GodBrain Database Diagnostics and Tools")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("test-conn", help="Test connection to Neo4j database")
    subparsers.add_parser("check-sync", help="Check MongoDB syncing to GodBrainCore")
    subparsers.add_parser("models", help="List all Model nodes in Graph")
    
    mem_parser = subparsers.add_parser("memory", help="Check Memory Node textual content")
    mem_parser.add_parser("h1470", help="Check h1470.png memory")
    mem_parser.add_parser("gemini", help="Check Gemini-cli-report_neo4j.png memory")
    
    ref_parser = subparsers.add_parser("refs", help="Show extraction references for a memory node")
    ref_parser.add_parser("h1470", help="Check h1470.png memory refs")
    ref_parser.add_parser("gemini", help="Check Gemini-cli-report_neo4j.png memory refs")

    ingest_parser = subparsers.add_parser("ingest", help="Test structured image ingestion")
    ingest_parser.add_argument("image_path", help="Path to image file to ingest")

    args = parser.parse_args()

    if args.command == "test-conn":
        test_connection()
    elif args.command == "check-sync":
        asyncio.run(check_sync())
    elif args.command == "models":
        query_models()
    elif args.command == "memory":
        filename = "h1470.png" if sys.argv[2] == "h1470" else "Gemini-cli-report_neo4j.png"
        check_memory(filename)
    elif args.command == "refs":
        filename = "h1470.png" if sys.argv[2] == "h1470" else "Gemini-cli-report_neo4j.png"
        show_results(filename)
    elif args.command == "ingest":
        test_ingestion(args.image_path)

if __name__ == "__main__":
    main()