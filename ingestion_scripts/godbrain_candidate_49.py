import os
import json
import shutil
import asyncio
import uvicorn
from fastapi import FastAPI, Header, Depends, UploadFile, File, HTTPException
from pydantic import BaseModel
from godbrain_core.commands.memory import GodBrainEngine, logger
#from sekreterare import AISecretary
#from universal_ingestion_engine import UniversalIngestionEngine
from dotenv import load_dotenv

load_dotenv() # Load from .env file

app = FastAPI(title="GodBrain Shared Memory API (Remote Control Mode)")
engine = GodBrainEngine()
secretary = AISecretary() 
ingestor = UniversalIngestionEngine()

# Paths
REMOTE_TASKS_FILE = r"C:\Users\autismo\Documents\GitHub\GodBrain\remote_tasks.json"
UPLOADS_DIR = r"C:\Users\autismo\Documents\GitHub\GodBrain\uploads"

# Security
API_KEY = os.environ.get("GODBRAIN_API_KEY", "SuperGem123!@#")

async def verify_token(x_api_key: str = Header(...)):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API Key")

class Thought(BaseModel):
    content: str
    source: str = "iPhone_Shortcut"
    tags: list[str] = []

class RemoteTask(BaseModel):
    task: str
    priority: str = "normal"
    tags: list[str] = ["remote-task"]

@app.get("/health")
async def health_check():
    return {"status": "GodBrain Memory API is Online (God Mode)"}

@app.post("/whisper", dependencies=[Depends(verify_token)])
async def ingest_thought(thought: Thought):
    """Endpoint for iPhone Shortcuts to POST whispered thoughts (text)."""
    thought_id = await engine.save_thought(
        content=thought.content, 
        source=thought.source, 
        tags=thought.tags
    )
    if thought_id:
        return {
            "status": "Thought Captured",
            "id": thought_id,
            "local_storage": "OK",
            "cloud_sync": "Background_Task"
        }
    return {"status": "Error", "detail": "Local write failed"}

@app.post("/ingest/image", dependencies=[Depends(verify_token)])
async def ingest_image(file: UploadFile = File(...), source: str = "iPhone_OCR"):
    """Endpoint for iPhone to upload images for OCR and Knowledge Injection."""
    try:
        temp_file = os.path.join(UPLOADS_DIR, f"remote_{file.filename}")
        with open(temp_file, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        # Run OCR Ingestion
        thought_id = await ingestor.ingest_image(temp_file, source=source)
        
        if thought_id:
            return {"status": "OCR Success", "id": thought_id, "file": file.filename}
        return {"status": "Error", "detail": "OCR extraction failed"}
    except Exception as e:
        logger.error(f"[-] Image ingestion failed: {e}")
        return {"status": "Error", "detail": str(e)}

@app.post("/secretary/ingest", dependencies=[Depends(verify_token)])
async def ingest_audio(file: UploadFile = File(...), device: str = "Remote_Mic"):
    """Endpoint for iPhone/Mac to upload audio recordings for transcription."""
    try:
        temp_file = os.path.join(UPLOADS_DIR, f"temp_{device}_{file.filename}")
        with open(temp_file, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        # Run transcription
        text = secretary.transcribe(temp_file)
        os.remove(temp_file) # Cleanup
        
        return {
            "status": "Transcription Success",
            "device": device,
            "transcription": text
        }
    except Exception as e:
        logger.error(f"[-] Audio ingestion failed: {e}")
        return {"status": "Error", "detail": str(e)}

@app.post("/tasks", dependencies=[Depends(verify_token)])
async def queue_task(task_data: RemoteTask):
    """Queues a task for the GodBrain agent to execute in the next session."""
    try:
        # 1. Save to JSON queue
        tasks = []
        if os.path.exists(REMOTE_TASKS_FILE):
            with open(REMOTE_TASKS_FILE, "r") as f:
                tasks = json.load(f)
        
        new_task = {
            "id": f"task_{int(asyncio.get_event_loop().time())}",
            "content": task_data.task,
            "priority": task_data.priority,
            "status": "pending",
            "timestamp": str(asyncio.get_event_loop().time())
        }
        tasks.append(new_task)
        
        with open(REMOTE_TASKS_FILE, "w") as f:
            json.dump(tasks, f, indent=2)
        
        # 2. Log as a thought for graph history
        await engine.save_thought(
            content=f"Remote Task Queued: {task_data.task}",
            source="iPhone_Remote",
            tags=task_data.tags
        )
        
        return {"status": "Task Queued", "id": new_task["id"]}
    except Exception as e:
        logger.error(f"[-] Task queueing failed: {e}")
        return {"status": "Error", "detail": str(e)}

@app.post("/jobs/{job_id}", dependencies=[Depends(verify_token)])
async def run_job(job_id: str):
    """Executes a pre-defined 'God Mode' system script."""
    job_map = {
        "run-audit": r"powershell.exe -File C:\Users\autismo\Documents\GitHub\godbrain\audit.ps1",
        "sync-brain": r"python C:\Users\autismo\Documents\GitHub\godbrain\check_sync.py",
    }
    
    if job_id not in job_map:
        return {"status": "Error", "detail": f"Job '{job_id}' not found"}
    
    try:
        # Run in background to not block API
        asyncio.create_subprocess_shell(job_map[job_id])
        return {"status": "Job Started", "job": job_id}
    except Exception as e:
        return {"status": "Error", "detail": str(e)}

@app.get("/recent", dependencies=[Depends(verify_token)])
async def get_recent_thoughts(limit: int = 5):
    """Retrieves the latest captured thoughts from Local Storage."""
    return await engine.get_recent(limit)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
