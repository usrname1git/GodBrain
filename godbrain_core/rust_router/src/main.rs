use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Redirect, Json},
    routing::{get, post},
    Router,
};
use mongodb::{bson::{doc, Document, oid::ObjectId}, Client, Collection, options::ClientOptions};
use serde::{Deserialize, Serialize};
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::time::timeout;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::cors::CorsLayer;
use futures::stream::StreamExt;

#[derive(Clone)]
struct AppState {
    db: mongodb::Database,
}

#[derive(Deserialize)]
struct ChatRequest {
    message: String,
}

#[derive(Serialize)]
struct ChatResponse {
    response: String,
}

#[derive(Deserialize)]
struct NodeQuery {
    id: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Initializing Rust Axum Router for GodBrain...");

    let client_options = ClientOptions::parse("mongodb://localhost:27017").await?;
    let client = Client::with_options(client_options)?;
    let db = client.database("godbrain");
    let state = AppState { db };

    let cors = CorsLayer::permissive();

    let app = Router::new()
        .route("/", get(|| async { Redirect::temporary("/galaxy") }))
        .route_service("/galaxy", ServeFile::new("../frontend/galaxy.html"))
        .nest_service("/frontend", ServeDir::new("../frontend"))
        .route("/api/test", get(|| async { "Rust Router Operational!" }))
        .route("/api/graph", get(get_graph))
        .route("/api/node", get(get_node))
        .route("/api/chat", post(chat_handler))
        .layer(cors)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8082").await?;
    println!("Listening on http://localhost:8082");
    axum::serve(listener, app).await?;

    Ok(())
}

async fn get_graph(State(state): State<AppState>) -> impl IntoResponse {
    let collection: Collection<Document> = state.db.collection("nodes");
    
    let mut cursor = match collection.find(doc! {}).projection(doc! { "title": 1, "type": 1, "tags": 1 }).await {
        Ok(c) => c,
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({"error": "DB query failed"}))),
    };

    let mut nodes = Vec::new();
    while let Some(result) = cursor.next().await {
        if let Ok(doc) = result {
            let id = doc.get_object_id("_id").map(|oid| oid.to_hex()).unwrap_or_default();
            let title = doc.get_str("title").unwrap_or("Unknown").to_string();
            let node_type = doc.get_str("type").unwrap_or("unknown").to_string();
            
            let mut group = "General";
            let title_lower = title.to_lowercase();
            let type_lower = node_type.to_lowercase();
            
            if title_lower.contains("rust") || type_lower.contains("rust") {
                group = "Rust";
            } else if title_lower.contains("windows") || title_lower.contains("sre") {
                group = "Windows SRE / Optimization";
            }

            nodes.push(serde_json::json!({
                "id": id,
                "label": title,
                "group": group,
                "type": node_type,
                "val": 1.5
            }));
        }
    }

    (StatusCode::OK, Json(serde_json::json!({ "nodes": nodes, "links": [] })))
}

async fn get_node(State(state): State<AppState>, Query(query): Query<NodeQuery>) -> impl IntoResponse {
    let collection: Collection<Document> = state.db.collection("nodes");
    
    let filter = if let Ok(oid) = ObjectId::parse_str(&query.id) {
        doc! { "_id": oid }
    } else {
        doc! { "title": &query.id }
    };

    match collection.find_one(filter).await {
        Ok(Some(mut doc)) => {
            if let Ok(oid) = doc.get_object_id("_id") {
                doc.insert("_id", oid.to_hex());
            }
            let bson_val = mongodb::bson::Bson::Document(doc);
            let json_val: serde_json::Value = bson_val.into();
            (StatusCode::OK, Json(json_val))
        },
        Ok(None) => (StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Node not found"}))),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({"error": "DB query failed"}))),
    }
}

async fn chat_handler(State(state): State<AppState>, Json(payload): Json<ChatRequest>) -> impl IntoResponse {
    println!("[RAG] User asked: {}", payload.message);
    
    let stop_words = vec!["what", "when", "where", "will", "this", "that", "delete", "disable", "change", "remove", "need", "right"];
    let words: Vec<&str> = payload.message.split_whitespace().collect();
    let mut keywords = Vec::new();
    
    for w in words {
        let clean_w = w.to_lowercase().replace(|c: char| !c.is_alphanumeric(), "");
        if clean_w.len() > 3 && !stop_words.contains(&clean_w.as_str()) {
            keywords.push(clean_w);
        }
    }

    let mut context_text = String::from("Knowledge Graph Context:\n");
    if !keywords.is_empty() {
        let regex_pattern = keywords.join("|");
        println!("[RAG] Searching graph for: {}", regex_pattern);
        
        let collection: Collection<Document> = state.db.collection("nodes");
        let filter = doc! {
            "$or": [
                { "title": { "$regex": &regex_pattern, "$options": "i" } },
                { "content": { "$regex": &regex_pattern, "$options": "i" } }
            ]
        };
        
        if let Ok(mut cursor) = collection.find(filter).limit(3).await {
            let mut i = 1;
            let mut found = false;
            while let Some(Ok(node)) = cursor.next().await {
                found = true;
                let title = node.get_str("title").unwrap_or("Unknown");
                let mut content = node.get_str("content").unwrap_or("").to_string();
                if content.len() > 500 {
                    content.truncate(500);
                }
                context_text.push_str(&format!("\n--- Source {}: {} ---\n{}...\n", i, title, content));
                i += 1;
            }
            if !found {
                context_text.push_str("No exact matches found in local graph.\n");
            }
        }
    } else {
         context_text.push_str("No specific keywords extracted.\n");
    }

    let system_prompt = "You are GodBrain, the Sovereign SRE Agent. You help the user optimize Windows 11 safely. Use the Knowledge Graph Context provided below to answer the user's question. If a tweak FATALLY_BREAKS something, WARN THE USER aggressively.";
    let full_prompt = format!("{}\n\n{}\n\nUser Question: {}\nAnswer:", system_prompt, context_text, payload.message);

    println!("[RAG] Context built. Executing Colibri via Rust...");

    let coli_path = r#"C:\Users\autismo\Documents\GitHub\GodBrain\LLM\colibri_LLM\c\colibri.exe"#;

    let output_future = tokio::task::spawn_blocking(move || {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        
        // Critical: Set COLI_API=1 or pass the prompt cleanly via standard input to completely bypass
        // the interactive terminal tokenizer loops in Colibri.
        let mut child = Command::new(coli_path)
            .args(&["64", "8", "8"])
            .env("SNAP", r#"C:\nvme\glm52"#)
            // By NOT passing COLI_PROMPT we force it to expect prompt from stdin, which doesn't hang the tokenizer
            .env("COLI_API", "1") // Try to tell it this is an API call
            .env("NGEN", "64")
            .env("COLI_RAM_OVERCOMMIT", "1")
            .env("COLI_CUDA", "1")
            .env("CUDA_EXPERT_GB", "12")
            .stdin(Stdio::piped()) // Pipe stdin so we can write the prompt
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW) // Detach from console properly
            .spawn()
            .expect("Failed to spawn Colibri natively");

        // Write the prompt to stdin and immediately drop it (which sends EOF)
        if let Some(mut stdin) = child.stdin.take() {
            use std::io::Write;
            let _ = stdin.write_all(full_prompt.as_bytes());
            let _ = stdin.write_all(b"\n");
        }

        let output = child.wait_with_output().expect("Failed to read Colibri output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        format!("{}{}", stdout, stderr)
    });

    match timeout(Duration::from_secs(180), output_future).await {
        Ok(Ok(combined)) => {
            let mut final_answer = combined.clone();
            if let Some(idx) = combined.rfind("ATTENTION:") {
                let parts: Vec<&str> = combined[idx..].splitn(2, '\n').collect();
                if parts.len() > 1 {
                    final_answer = parts[1].to_string();
                }
            } else if let Some(idx) = combined.rfind("Answer:") {
                final_answer = combined[idx + "Answer:".len()..].to_string();
            } else {
                let lines: Vec<&str> = combined.lines().collect();
                if lines.len() > 10 {
                    final_answer = lines[lines.len() - 10..].join("\n");
                }
            }

            final_answer = final_answer.trim().to_string();
            if final_answer.is_empty() {
                final_answer = "No output returned from Colibri engine.".to_string();
            }
            (StatusCode::OK, Json(ChatResponse { response: final_answer }))
        },
        Ok(Err(_)) => {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ChatResponse { response: "Failed to execute task".to_string() }))
        },
        Err(_) => {
            let _ = Command::new("taskkill").args(&["/F", "/IM", "colibri.exe"]).output();
            (StatusCode::GATEWAY_TIMEOUT, Json(ChatResponse { response: "System fault. Colibri C-Engine timed out.".to_string() }))
        }
    }
}
