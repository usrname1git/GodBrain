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
                {"tags": {"$regex": regex_pattern, "$options": "i"}}
            ]
        }).limit(3))
        
        if relevant_nodes:
            for idx, node in enumerate(relevant_nodes):
                context_text += f"\n--- Source {idx+1}: {node.get('title')} ---\n"
                context_text += f"{node.get('content', '')[:500]}...\n"
        else:
            context_text += "No exact matches found in local graph.\n"
    else:
        context_text += "No specific keywords extracted.\n"
        
    print("[RAG] Context built. Sending to Colibri...")
    
    system_prompt = "You are GodBrain, the Sovereign SRE Agent. You help the user optimize Windows 11 safely. Use the Knowledge Graph Context provided below to answer the user's question. If a tweak FATALLY_BREAKS something, WARN THE USER aggressively."
    full_prompt = f"{system_prompt}\n\n{context_text}\n\nUser Question: {user_message}\nAnswer:"
    
    cmd = [COLI_PATH]
    
    env = os.environ.copy()
    env["SNAP"] = MODEL_PATH
    env["COLI_PROMPT"] = full_prompt
    env["NGEN"] = "256"
    env["COLI_RAM_OVERCOMMIT"] = "1"
    env["COLI_CUDA"] = "1"
    env["CUDA_EXPERT_GB"] = "12"
    
    import subprocess
    try:
        subprocess.run(["taskkill", "/F", "/IM", "colibri.exe"], capture_output=True)
    except:
        pass

    try:
        process = subprocess.run(cmd, env=env, input="", capture_output=True, text=True, encoding='utf-8', timeout=180)
        output = process.stdout + process.stderr
        
        if "ATTENTION:" in output:
            final_answer = output.split("ATTENTION:")[-1].split("\n", 1)[-1].strip()
        elif "Answer:" in output:
            final_answer = output.split("Answer:")[-1].strip()
        else:
            lines = output.splitlines()
            final_answer = "\n".join(lines[-10:])
            
        print(f"[RAG] Answer generated: {final_answer[:50]}...")
        
        return jsonify({"response": final_answer})
        
    except subprocess.TimeoutExpired as e:
        print("[-] Colibri timed out after 180 seconds.")
        return jsonify({"response": "System fault. Colibri C-Engine timed out."})
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










