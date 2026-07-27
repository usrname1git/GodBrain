from flask import Flask, jsonify, send_from_directory, request
from pymongo import MongoClient
import os
import subprocess
import re
import sys

app = Flask(__name__, static_folder='frontend')
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0

# Connect to Windows MongoDB
client = MongoClient('mongodb://localhost:27017/')
db = client['godbrain']

COLI_PATH = r"C:\Users\autismo\Documents\GitHub\GodBrain\LLM\colibri_LLM\c\colibri.exe"
MODEL_PATH = r"C:\nvme\glm52"

@app.route('/')
def index_redirect():
    return '<meta http-equiv="refresh" content="0; url=/galaxy">'

@app.route('/galaxy')
def serve_frontend():
    response = send_from_directory('frontend', 'galaxy.html')
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    return response

@app.route('/api/test')
def test_route():
    return jsonify({"status": "reloaded!"})

@app.route('/api/log', methods=['POST'])
def client_log():
    print(f"\n[BROWSER ERROR] {request.json}\n", flush=True)
    return jsonify({"status": "logged"})

@app.route('/api/chat', methods=['POST'])
def chat_with_godbrain():
    data = request.json
    user_message = data.get("message", "")
    if not user_message:
        return jsonify({"response": "I cannot hear you. Message was empty."})
        
    print(f"[RAG] User asked: {user_message}")
    
    # 1. RETRIEVAL: Find relevant nodes based on the user's message
    words = [w.lower() for w in re.findall(r'\b\w+\b', user_message) if len(w) > 3]
    stop_words = {'what', 'when', 'where', 'will', 'this', 'that', 'delete', 'disable', 'change', 'remove'}
    keywords = [w for w in words if w not in stop_words]
    
    context_text = "Knowledge Graph Context:\n"
    if keywords:
        regex_pattern = '|'.join(keywords)
        print(f"[RAG] Searching graph for: {regex_pattern}")
        
        relevant_nodes = list(db.nodes.find({
            "$or": [
                {"title": {"$regex": regex_pattern, "$options": "i"}},
                {"content": {"$regex": regex_pattern, "$options": "i"}},
                {"_id": {"$regex": regex_pattern, "$options": "i"}}
            ]
        }).limit(5))
        
        if relevant_nodes:
            node_ids = [n['_id'] for n in relevant_nodes]
            relevant_edges = list(db.edges.find({
                "$or": [{"source": {"$in": node_ids}}, {"target": {"$in": node_ids}}]
            }))
            
            for n in relevant_nodes:
                context_text += f"- Node [{n['type']}]: {n.get('title', n['_id'])} - {n.get('content', '')}\n"
            
            for e in relevant_edges:
                context_text += f"- Edge: {e['source']} --[{e['relationship']}]--> {e['target']}\n"
        else:
            context_text += "No relevant nodes found in the graph.\n"
    else:
        context_text += "No specific keywords extracted.\n"
        
    print("[RAG] Context built. Sending to Colibri...")
    
    system_prompt = "You are GodBrain, the Sovereign SRE Agent. You help the user optimize Windows 11 safely. Use the Knowledge Graph Context provided below to answer the user's question. If a tweak FATALLY_BREAKS something, WARN THE USER aggressively."
    full_prompt = f"{system_prompt}\n\n{context_text}\n\nUser Question: {user_message}\nAnswer:"
    
    cmd = [
        COLI_PATH, "run", full_prompt,
        "--model", MODEL_PATH,
        "--gpu", "0",
        "--vram", "8",
        "--ngen", "256", 
        "--temp", "0.3"
    ]
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8')
        output = result.stdout + result.stderr
        
        answer_split = output.split("Answer:")
        if len(answer_split) > 1:
            final_answer = answer_split[-1].strip()
        else:
            lines = output.splitlines()
            final_answer = "\n".join(lines[-10:])
            
        print("[RAG] Answer generated.")
        return jsonify({"response": final_answer})
        
    except Exception as e:
        print(f"[-] Colibri crashed: {e}")
        return jsonify({"response": f"System fault. The LLM engine crashed: {str(e)}"})

@app.route('/api/node')
def get_node_details():
    node_id = request.args.get('id')
    if not node_id:
        return jsonify({"error": "No ID provided"}), 400
        
    node = db.nodes.find_one({"_id": node_id})
    if not node:
        # Try finding by title just in case it's a mismatch
        node = db.nodes.find_one({"title": node_id})
        
    if not node:
        try:
            from bson.objectid import ObjectId
            node = db.nodes.find_one({"_id": ObjectId(node_id)})
        except:
            pass
            
    if not node:
        return jsonify({"error": "Node not found"}), 404
        
    return jsonify({
        "id": str(node.get("_id", "")),
        "title": node.get("title", "Unknown"),
        "content": node.get("content", "No content available."),
        "type": node.get("type", "note"),
        "tags": node.get("tags", [])
    })

@app.route('/api/graph')
def get_graph():
    nodes_cursor = db.nodes.find({}, {"_id": 1, "title": 1, "type": 1, "tags": 1})
    nodes = []
    valid_node_ids = set()
    for n in nodes_cursor:
        node_id = str(n["_id"])
        valid_node_ids.add(node_id)
        
        node_type = n.get("type", "note")
        title = n.get("title", "Unknown Node")
        
        # Heuristic to assign groups based on title or type for UI filtering
        group = "General"
        t_lower = title.lower()
        type_lower = node_type.lower()
        
        if "rust" in t_lower or "rust" in type_lower:
            group = "Rust"
        elif "windows" in t_lower or "sre" in t_lower or "sysinternals" in t_lower:
            group = "Windows SRE / Optimization"
        elif "node" in t_lower or "v8" in t_lower or "javascript" in t_lower:
            group = "Node.js Ecosystem"
        elif "react" in t_lower or "fiber" in t_lower or "hook" in t_lower:
            group = "React Architecture"
        elif "usurper" in type_lower or "supabase" in t_lower or "firebase" in t_lower:
            group = "BaaS Usurpers (Enemy)"
        elif "chromium" in type_lower or "electron" in t_lower or "chrome" in t_lower or "v8" in t_lower:
            group = "Chromium Bloat (Priority Enemy)"
        elif "linux" in type_lower or "linux" in t_lower:
            group = "Linux"
        elif "apple" in type_lower or "mac" in t_lower:
            group = "Apple"
        elif "github" in t_lower:
            group = "GitHub Docs"
            
        nodes.append({
            "id": node_id,
            "title": title,
            "type": node_type,
            "group": group
        })
        
    edges_cursor = db.edges.find({}, {"_id": 0, "source": 1, "target": 1, "relationship": 1})
    edges = []
    dropped_edges = 0
    for e in edges_cursor:
        source = str(e["source"])
        target = str(e["target"])
        if source in valid_node_ids and target in valid_node_ids:
            edges.append({
                "source": source,
                "target": target,
                "relationship": e.get("relationship", "links_to")
            })
        else:
            dropped_edges += 1
            
    print(f"API generated graph: {len(nodes)} nodes, {len(edges)} edges. Dropped {dropped_edges} invalid edges.")
        
    return jsonify({"nodes": nodes, "links": edges})

if __name__ == '__main__':
    print("Starting GodBrain API on http://127.0.0.1:8081")
    app.run(host='127.0.0.1', port=8081, debug=False)


