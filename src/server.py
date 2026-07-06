import os
import uuid
import uvicorn
from fastapi import FastAPI, BackgroundTasks, HTTPException
from pydantic import BaseModel
from typing import Dict, Optional, Any
from .core import MusicConverter
from .constants import TaskStatus, ModelType, ProcessingMode

app = FastAPI(title="Music Piano Converter API")

# Initialize converter
# Note: Configuration is loaded from config.json by default
converter = MusicConverter()

# In-memory task store
tasks: Dict[str, Dict[str, Any]] = {}

class ProcessRequest(BaseModel):
    input_path: str
    mode: str = ProcessingMode.ENHANCED_PIANO
    model_type: str = ModelType.PIANO_TRANSCRIPTION
    soundfont_path: Optional[str] = None
    device: Optional[str] = None

class TaskResponse(BaseModel):
    task_id: str
    status: str
    progress: int
    message: str
    result: Optional[Dict[str, Any]] = None

@app.post("/process", response_model=TaskResponse)
async def process_audio(req: ProcessRequest, background_tasks: BackgroundTasks):
    """
    Start an audio processing task.
    """
    if not os.path.exists(req.input_path):
        raise HTTPException(status_code=404, detail=f"Input file not found: {req.input_path}")

    task_id = str(uuid.uuid4())
    
    # Initialize task state
    tasks[task_id] = {
        "task_id": task_id,
        "status": TaskStatus.PENDING,
        "progress": 0,
        "message": "Queued",
        "result": None
    }

    # Update converter config for this request if provided
    # Note: This is not thread-safe if multiple requests come in with different configs.
    # Ideally, config should be passed to process() or we instantiate a new converter per request.
    # For now, we assume single-user local usage or consistent config.
    if req.soundfont_path:
        converter.soundfont_path = req.soundfont_path
    if req.device:
        converter.device = req.device

    # Define the task function
    def run_task(tid: str):
        tasks[tid]["status"] = TaskStatus.PROCESSING
        tasks[tid]["message"] = "Starting..."
        
        def progress_callback(p: int, msg: str):
            tasks[tid]["progress"] = p
            tasks[tid]["message"] = msg
            
        try:
            result = converter.process(
                input_path=req.input_path,
                mode=req.mode,
                model_type=req.model_type,
                progress_callback=progress_callback
            )
            tasks[tid]["status"] = TaskStatus.COMPLETED
            tasks[tid]["progress"] = 100
            tasks[tid]["message"] = "Completed"
            tasks[tid]["result"] = result
        except Exception as e:
            tasks[tid]["status"] = TaskStatus.FAILED
            tasks[tid]["message"] = str(e)
            # Log error
            print(f"Task {tid} failed: {e}")

    # Submit to background tasks
    background_tasks.add_task(run_task, task_id)
    
    return tasks[task_id]

@app.get("/status/{task_id}", response_model=TaskResponse)
async def get_status(task_id: str):
    """
    Get the status of a task.
    """
    if task_id not in tasks:
        raise HTTPException(status_code=404, detail="Task not found")
    
    return tasks[task_id]

@app.get("/tasks")
async def list_tasks():
    """
    List all tasks.
    """
    return list(tasks.values())

def start():
    """
    Entry point for starting the server programmatically.
    """
    uvicorn.run(app, host="0.0.0.0", port=8000)

if __name__ == "__main__":
    start()
