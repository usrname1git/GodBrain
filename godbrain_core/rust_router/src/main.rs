use axum::{
    extract::{Query, State},
    http::{HeaderValue, StatusCode},
    response::{IntoResponse, Redirect, Json},
    routing::{get, post},
    Router,
};
use mongodb::{bson::{doc, Document, oid::ObjectId}, Client, Collection, options::ClientOptions};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::time::timeout;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::cors::{AllowOrigin, CorsLayer};
use futures::stream::StreamExt;

/// Origins allowed to talk to this loopback-only API: localhost/127.0.0.1 on
/// any port (dev servers, the packaged UI, etc.) plus the Tauri webview
/// origins, matching the C++ kernel router's allow-list. No wildcard is ever
/// accepted.
fn is_trusted_origin(origin: &str) -> bool {
    if origin.is_empty() {
        return false;
    }
    if origin == "tauri://localhost" {
        return true;
    }
    let rest = match origin.split_once("://") {
        Some((_, rest)) => rest,
        None => return false,
    };
    let rest = rest.split('/').next().unwrap_or("");
    let host = rest.split(':').next().unwrap_or("");
    host == "localhost" || host == "127.0.0.1" || host == "tauri.localhost"
}

/// Resolves the Colibri C-Engine executable. `GODBRAIN_COLIBRI_PATH` always
/// wins; otherwise a handful of repo-relative candidates are tried (from both
/// the running executable's own directory and the current working
/// directory), so no single user's absolute path is ever baked in.
fn resolve_colibri_path() -> PathBuf {
    if let Ok(v) = std::env::var("GODBRAIN_COLIBRI_PATH") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            candidates.push(exe_dir.join("../../LLM/colibri_LLM/c/colibri.exe"));
            candidates.push(exe_dir.join("../../../LLM/colibri_LLM/c/colibri.exe"));
            candidates.push(exe_dir.join("LLM/colibri_LLM/c/colibri.exe"));
        }
    }
    candidates.push(PathBuf::from("../LLM/colibri_LLM/c/colibri.exe"));
    candidates.push(PathBuf::from("LLM/colibri_LLM/c/colibri.exe"));

    for candidate in &candidates {
        if Path::new(candidate).exists() {
            return candidate.clone();
        }
    }

    let fallback = PathBuf::from("../../LLM/colibri_LLM/c/colibri.exe");
    eprintln!(
        "[SYS] WARNING: could not locate colibri.exe via GODBRAIN_COLIBRI_PATH or repo-relative defaults; using best-effort path '{}'.",
        fallback.display()
    );
    fallback
}

fn resolve_snapshot_path() -> String {
    std::env::var("GODBRAIN_SNAPSHOT_PATH").unwrap_or_else(|_| r#"C:\nvme\glm52"#.to_string())
}

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

    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(|origin: &HeaderValue, _| {
            origin
                .to_str()
                .map(is_trusted_origin)
                .unwrap_or(false)
        }))
        .allow_methods([axum::http::Method::GET, axum::http::Method::POST, axum::http::Method::OPTIONS])
        .allow_headers([axum::http::header::CONTENT_TYPE, axum::http::header::AUTHORIZATION]);

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

    // Loopback only: this API is not meant to be reachable from other hosts
    // on the network.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8082").await?;
    println!("Listening on http://127.0.0.1:8082 (loopback only)");
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

    let coli_path = resolve_colibri_path();

    // Fully async: tokio::process::Command instead of spawn_blocking + the
    // std::process API. This lets us keep the live `Child` handle across the
    // timeout, so on timeout we can terminate exactly the process we spawned
    // (by handle/PID) instead of a `taskkill /IM colibri.exe`, which would
    // kill every colibri.exe on the machine including unrelated instances a
    // user might be running directly. `kill_on_drop` is a safety net in case
    // this function returns early for any other reason.
    let mut child = match Command::new(&coli_path)
        .args(&["64", "8", "8"])
        .env("SNAP", resolve_snapshot_path())
        // By NOT passing COLI_PROMPT we force it to expect prompt from stdin, which doesn't hang the tokenizer
        .env("COLI_API", "1") // Try to tell it this is an API call
        .env("NGEN", "64")
        .env("COLI_RAM_OVERCOMMIT", "1")
        .env("COLI_CUDA", "1")
        .env("CUDA_EXPERT_GB", "12")
        .stdin(Stdio::piped()) // Pipe stdin so we can write the prompt
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(0x08000000) // CREATE_NO_WINDOW: detach from console properly
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ChatResponse { response: format!("Failed to spawn colibri: {}", err) }),
            );
        }
    };

    // Write the prompt to stdin and immediately drop it (which sends EOF)
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(full_prompt.as_bytes()).await;
        let _ = stdin.write_all(b"\n").await;
        // stdin is dropped here, closing our end of the pipe.
    }

    let mut stdout = child.stdout.take().expect("stdout was piped");
    let mut stderr = child.stderr.take().expect("stderr was piped");

    // Read stdout/stderr concurrently with waiting on the child: reading
    // only after the process exits would deadlock if Colibri fills the pipe
    // buffer before exiting, and reading synchronously before starting the
    // wait (as the previous implementation effectively did inside
    // `wait_with_output`) is exactly the pattern that lets a hung child block
    // forever, since the timeout could never actually apply until the read
    // finished.
    let collect = async {
        let mut out_buf = Vec::new();
        let mut err_buf = Vec::new();
        let (_, _, status) = tokio::join!(
            stdout.read_to_end(&mut out_buf),
            stderr.read_to_end(&mut err_buf),
            child.wait(),
        );
        (out_buf, err_buf, status)
    };

    match timeout(Duration::from_secs(180), collect).await {
        Ok((out_buf, err_buf, status)) => {
            if let Err(err) = status {
                eprintln!("[RAG] failed to wait on colibri process: {}", err);
            }
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out_buf),
                String::from_utf8_lossy(&err_buf)
            );
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
        Err(_) => {
            // Terminate only the exact child process we spawned (by
            // handle/PID via tokio), never a `taskkill /IM colibri.exe`,
            // which would kill every colibri.exe on the machine including
            // unrelated instances a user might be running directly. Await
            // the kill so the process is fully reaped before we respond.
            if let Err(err) = child.kill().await {
                eprintln!("[RAG] failed to kill timed-out colibri process (pid {:?}): {}", child.id(), err);
            }
            let _ = child.wait().await;
            (StatusCode::GATEWAY_TIMEOUT, Json(ChatResponse { response: "System fault. Colibri C-Engine timed out.".to_string() }))
        }
    }
}
