import os
from neo4j import GraphDatabase, RoutingControl

# Windows process env bypass (forcing a load of the user env)
import winreg
key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Environment')
uri, _ = winreg.QueryValueEx(key, 'NEO4J_URI')
user, _ = winreg.QueryValueEx(key, 'NEO4J_USERNAME')
pwd, _ = winreg.QueryValueEx(key, 'NEO4J_PASSWORD')

# Disable routing overhead that breaks v5 drivers on Aura free tier
driver = GraphDatabase.driver(uri, auth=(user, pwd), max_connection_lifetime=30 * 60)

def seed_graph(tx):
    query = """
    MERGE (gb:System {name: 'GodBrain', type: 'Cognitive OS'})
    MERGE (u:User {name: 'Autismo', clearance: 'Approved by NSA'})
    MERGE (m:Hardware {name: 'Mac Studio M5 Max', vram: '128GB UMA'})
    MERGE (f:Hardware {name: 'Delta Fan', rpm: 16000, db: 140})
    MERGE (pc:Hardware {name: 'Apex Comedy', status: 'Demoted to Xbox'})
    
    MERGE (u)-[:BUILDS]->(gb)
    MERGE (gb)-[:RUNS_ON]->(m)
    MERGE (u)-[:DEMOTED]->(pc)
    MERGE (u)-[:DESPISES]->(f)
    
    RETURN gb.name, u.name
    """
    result = tx.run(query)
    return result.data()

try:
    with driver.session() as session:
        data = session.execute_write(seed_graph)
        print("SUCCESS! Created graph nodes:", data)
except Exception as e:
    print("ERROR:", e)
