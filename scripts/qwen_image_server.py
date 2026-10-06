"""Qwen-Image-2.1 on this host. One GPU slot. Weights stay on C:\\nvme.

The 4080 Super has 16 GB. The full BF16 stack (7B DiT plus the Qwen3-VL 8B
text encoder) does not fit resident, so the pipeline uses CPU offload.
Default size is 1024. Native 2K stays behind QWEN_IMAGE_MAX=2048.
"""
import base64
import binascii
import ctypes
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import torch
from PIL import Image, UnidentifiedImageError

WEIGHTS = Path(os.environ.get("QWEN_IMAGE_WEIGHTS", r"C:\nvme\Qwen-Image-2.1"))
OUT = Path(os.environ.get("QWEN_IMAGE_OUT", r"C:\nvme\godbrain-sites\qwen-image"))
HOST = "127.0.0.1"
PORT = 8871
MAX_BODY = 15 * 1_048_576
MAX_IMAGE_BYTES = 10 * 1_048_576
MAX_IMAGE_PIXELS = 16_777_216
MAX_SIDE = int(os.environ.get("QWEN_IMAGE_MAX", "1024"))
WORKER_IMAGE_BYTES = max(MAX_IMAGE_BYTES, MAX_SIDE * MAX_SIDE * 4 + 1_048_576)
MAX_WORKER_BODY = MAX_BODY + (WORKER_IMAGE_BYTES * 4 + 2) // 3
PIPE = None
READY = False
PROGRESS_SINK = None
GENERATE_LOCK = threading.Lock()
PROGRESS_LOCK = threading.Lock()
JOBS_LOCK = threading.Lock()
JOBS = {}
MAX_JOBS = 8
PROGRESS = {"phase": "idle", "completed_steps": 0, "total_steps": 0,
            "steps_per_second": None, "seconds_per_step": None,
            "started_at": None, "finished_at": None, "first_step_at": None, "request_id": None}


def start_progress(steps, request_id=None):
    with PROGRESS_LOCK:
        PROGRESS.update(phase="preparing", completed_steps=0, total_steps=steps,
                        steps_per_second=None, seconds_per_step=None,
                        started_at=time.monotonic(), finished_at=None, first_step_at=None,
                        request_id=request_id)
    write_progress()


def step_progress(pipe, step, timestep, callback_kwargs):
    now = time.monotonic()
    with PROGRESS_LOCK:
        completed = step + 1
        total = pipe.num_timesteps
        PROGRESS.update(completed_steps=completed, total_steps=total,
                        phase="decoding" if completed == total else "denoising")
        if PROGRESS["first_step_at"] is None:
            PROGRESS["first_step_at"] = now
        elif completed > 1:
            duration = now - PROGRESS["first_step_at"]
            if duration > 0:
                PROGRESS["steps_per_second"] = (completed - 1) / duration
                PROGRESS["seconds_per_step"] = duration / (completed - 1)
    write_progress()
    return callback_kwargs


def finish_progress(phase):
    with PROGRESS_LOCK:
        PROGRESS.update(phase=phase, finished_at=time.monotonic())


def progress_snapshot():
    now = time.monotonic()
    with PROGRESS_LOCK:
        result = {key: PROGRESS[key] for key in
                  ("phase", "completed_steps", "total_steps", "steps_per_second", "seconds_per_step", "request_id")}
        started = PROGRESS["started_at"]
        end = PROGRESS["finished_at"] if PROGRESS["finished_at"] is not None else now
        result["elapsed_seconds"] = round(max(0, end - started), 1) if started is not None else 0
        return result


def write_json(path, payload):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    for attempt in range(5):
        try:
            temporary.replace(path)
            return
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(0.1)


def write_progress():
    if PROGRESS_SINK is not None:
        write_json(PROGRESS_SINK, progress_snapshot())


def set_phase(phase):
    with PROGRESS_LOCK:
        PROGRESS["phase"] = phase
    write_progress()


def load_pipe():
    global PIPE
    if PIPE is not None:
        return PIPE

    from diffusers.pipelines.qwenimage21.pipeline_qwenimage21 import QwenImage21Pipeline

    pipe = QwenImage21Pipeline.from_pretrained(str(WEIGHTS), dtype=torch.bfloat16)
    pipe.enable_model_cpu_offload()
    PIPE = pipe
    return pipe


class ChildJob:
    def __init__(self, process):
        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("flags", ctypes.c_uint32), ("minimum", ctypes.c_size_t),
                        ("maximum", ctypes.c_size_t), ("active", ctypes.c_uint32),
                        ("affinity", ctypes.c_size_t), ("priority", ctypes.c_uint32),
                        ("scheduling", ctypes.c_uint32)]

        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", ctypes.c_uint64 * 6),
                        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                        ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
        self.api.CreateJobObjectW.restype = ctypes.c_void_p
        self.api.SetInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.api.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.api.CloseHandle.argtypes = [ctypes.c_void_p]
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        try:
            if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
                raise ctypes.WinError(ctypes.get_last_error())
            if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
                raise ctypes.WinError(ctypes.get_last_error())
        except OSError:
            self.close()
            raise

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            if not self.api.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())


def _as_int(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError(f"{name} must be an integer")
    try:
        return int(str(value).strip())
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc


def clamp_side(value, default):
    try:
        n = int(value)
    except (TypeError, ValueError):
        n = default
    n = max(256, n)
    return min(n, MAX_SIDE)

def decode_input_image(value, byte_limit=None):
    if not isinstance(value, str) or not value:
        raise ValueError("image_base64 must be a non-empty base64 string")
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("image_base64 must be valid base64") from exc
    limit = MAX_IMAGE_BYTES if byte_limit is None else byte_limit
    if not raw or len(raw) > limit:
        raise ValueError(f"Image input must be between 1 byte and {limit / 1_048_576:g} MiB")
    try:
        with Image.open(io.BytesIO(raw)) as source:
            if source.format not in ("JPEG", "PNG", "WEBP"):
                raise ValueError("Image input must be JPEG, PNG, or WebP")
            if source.width * source.height > MAX_IMAGE_PIXELS:
                raise ValueError("Image input exceeds 16 megapixels")
            source.load()
            image = source.convert("RGB")
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
        raise ValueError("Image input is invalid or too large") from exc
    image.thumbnail((MAX_SIDE, MAX_SIDE))
    return image


def job_snapshot(request_id):
    with JOBS_LOCK:
        job = JOBS.get(request_id)
        return dict(job) if job is not None else None


def generate_image(request_id, prompt, input_image, width, height, steps, seed):
    start_progress(steps, request_id)
    set_phase("loading")
    pipe = load_pipe()
    set_phase("preparing")
    image = pipe(
        prompt=prompt, image=input_image, width=width, height=height,
        num_inference_steps=steps, generator=torch.Generator("cuda").manual_seed(seed),
        return_dict=False, callback_on_step_end=step_progress,
        callback_on_step_end_tensor_inputs=[],
    )[0][0]
    set_phase("saving")
    OUT.mkdir(parents=True, exist_ok=True)
    token = f"{int(time.time())}-{uuid.uuid4().hex[:8]}"
    dest = OUT / f"qwen-image-{token}-{width}x{height}.png"
    image.save(dest)
    return {"path": str(dest), "width": width, "height": height, "steps": steps, "seed": seed}


def run_worker(request_id, prompt, input_image, width, height, steps, seed):
    payload = {"request_id": request_id, "prompt": prompt, "width": width,
               "height": height, "steps": steps, "seed": seed}
    if input_image is not None:
        data = io.BytesIO()
        input_image.save(data, format="PNG")
        payload["image_base64"] = base64.b64encode(data.getvalue()).decode("ascii")
    with tempfile.TemporaryDirectory(prefix="qwen-image-job-") as directory:
        progress_path = Path(directory) / "progress.json"
        result_path = Path(directory) / "result.json"
        environment = os.environ.copy()
        environment["PYTHONPATH"] = os.pathsep.join(path for path in sys.path if path)
        process = subprocess.Popen(
            [sys._base_executable, "-u", str(Path(__file__).resolve()), "--worker",
             str(progress_path), str(result_path)], stdin=subprocess.PIPE, env=environment)
        job = None
        try:
            job = ChildJob(process)
            process.stdin.write(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
            process.stdin.close()
            deadline = time.monotonic() + 7200
            def sync_progress():
                if not progress_path.exists():
                    return
                if progress_path.stat().st_size > 64 * 1024:
                    raise ValueError("Image worker progress exceeds its bounded document.")
                progress = json.loads(progress_path.read_text(encoding="utf-8"))
                if progress.get("request_id") != request_id:
                    raise ValueError("Image worker returned a different request ID.")
                with PROGRESS_LOCK:
                    for key in ("phase", "completed_steps", "total_steps", "steps_per_second", "seconds_per_step"):
                        PROGRESS[key] = progress[key]
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Image worker exceeded its two-hour limit.")
                sync_progress()
                time.sleep(0.2)
            sync_progress()
            if not result_path.exists():
                raise RuntimeError(f"Image worker exited {process.returncode} without a result.")
            if result_path.stat().st_size > 64 * 1024:
                raise ValueError("Image worker result exceeds its bounded document.")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            if process.returncode != 0 or result.get("error"):
                raise RuntimeError(result.get("error") or f"Image worker exited {process.returncode}.")
            receipt = result["result"]
            if (not isinstance(receipt, dict) or set(receipt) != {"path", "width", "height", "steps", "seed"}
                    or not Path(receipt["path"]).is_file()):
                raise ValueError("Image worker returned an invalid saved receipt.")
            return receipt
        finally:
            try:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=15)
            finally:
                if job is not None:
                    job.close()


def run_generation(request_id, prompt, input_image, width, height, steps, seed):
    try:
        start_progress(steps, request_id)
        set_phase("loading")
        receipt = run_worker(request_id, prompt, input_image, width, height, steps, seed)
        finish_progress("done")
        with JOBS_LOCK:
            JOBS[request_id].update(status="done", result=receipt)
    except Exception as exc:
        finish_progress("failed")
        traceback.print_exc()
        with JOBS_LOCK:
            JOBS[request_id].update(status="failed", error=str(exc))
    finally:
        GENERATE_LOCK.release()


def worker_main(progress_path, result_path):
    global PROGRESS_SINK
    PROGRESS_SINK = progress_path
    try:
        raw = sys.stdin.buffer.read(MAX_WORKER_BODY + 1)
        if len(raw) > MAX_WORKER_BODY:
            raise ValueError("Image worker input exceeds its bounded payload.")
        payload = json.loads(raw.decode("utf-8"))
        image = decode_input_image(payload["image_base64"], WORKER_IMAGE_BYTES) if "image_base64" in payload else None
        receipt = generate_image(payload["request_id"], payload["prompt"], image,
                                 payload["width"], payload["height"], payload["steps"], payload["seed"])
        write_json(result_path, {"result": receipt})
        set_phase("unloading")
    except Exception as exc:
        traceback.print_exc()
        write_json(result_path, {"error": str(exc)})
        raise SystemExit(1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[qwen-image]", fmt % args, flush=True)

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError) as exc:
            self.close_connection = True
            self.log_message("response %s not delivered: %s (client disconnected)", code, type(exc).__name__)
            return False
        return True

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/v1/images/jobs/"):
            job = job_snapshot(path.removeprefix("/v1/images/jobs/"))
            if job is None:
                self._send(404, {"error": "Unknown or expired image request."})
                return
            if job["status"] == "running":
                progress = progress_snapshot()
                if progress["request_id"] == job["request_id"]:
                    job["progress"] = progress
            self._send(200, job)
            return
        if path != "/health":
            self._send(404, {"error": "not found"})
            return
        progress = progress_snapshot()
        loaded = GENERATE_LOCK.locked() and progress["phase"] in ("preparing", "denoising", "decoding", "saving", "unloading")
        self._send(200, {"ok": True, "ready": READY, "loaded": loaded, "busy": GENERATE_LOCK.locked(),
                         "max_side": MAX_SIDE, "weights": str(WEIGHTS), "progress": progress})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/v1/images/generations", "/generate"):
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except (TypeError, ValueError):
            self._send(400, {"error": "Invalid Content-Length header."})
            return
        if length < 1 or length > MAX_BODY:
            self._send(400, {"error": f"Request body must be between 1 and {MAX_BODY} bytes."})
            return
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(400, {"error": "Request body must be valid JSON."})
            return
        if not isinstance(req, dict):
            self._send(400, {"error": "Request body must be a JSON object."})
            return
        prompt = str(req.get("prompt") or "").strip()
        if not prompt:
            self._send(400, {"error": "prompt is required"})
            return
        size = req.get("size")
        if isinstance(size, str) and "x" in size.lower():
            w, h = size.lower().split("x", 1)
        else:
            w, h = req.get("width", 1024), req.get("height", 1024)
        try:
            width = clamp_side(w, 1024)
            height = clamp_side(h, 1024)
            steps = max(1, min(_as_int(req.get("num_inference_steps") or req.get("steps") or 40, "steps"), 40))
            seed = _as_int(req.get("seed") or 0, "seed")
            input_image = decode_input_image(req["image_base64"]) if "image_base64" in req else None
            asynchronous = req.get("async", False)
            if not isinstance(asynchronous, bool):
                raise ValueError("async must be a boolean")
            request_id = req.get("request_id", uuid.uuid4().hex)
            if not isinstance(request_id, str) or len(request_id) != 32:
                raise ValueError("request_id must contain 32 UUID hex characters")
            request_id = uuid.UUID(request_id).hex
        except ValueError as exc:
            self._send(400, {"error": str(exc)})
            return
        if not GENERATE_LOCK.acquire(blocking=False):
            self._send(409, {"error": "Qwen-Image-2.1 is already generating. Wait."})
            return
        with JOBS_LOCK:
            duplicate = request_id in JOBS
            if not duplicate:
                if len(JOBS) >= MAX_JOBS:
                    del JOBS[next(iter(JOBS))]
                JOBS[request_id] = {"request_id": request_id, "status": "running",
                                    "result": None, "error": None}
        if duplicate:
            GENERATE_LOCK.release()
            self._send(409, {"error": "request_id already exists; generation was not repeated."})
            return
        args = (request_id, prompt, input_image, width, height, steps, seed)
        if asynchronous:
            try:
                threading.Thread(target=run_generation, args=args, daemon=True).start()
            except (RuntimeError, MemoryError, OSError) as exc:
                traceback.print_exc()
                with JOBS_LOCK:
                    JOBS[request_id].update(status="failed", error=str(exc))
                GENERATE_LOCK.release()
                self._send(500, {"error": str(exc)})
                return
            self._send(202, {"request_id": request_id, "status": "running"})
            return
        run_generation(*args)
        job = job_snapshot(request_id)
        if job["status"] == "done":
            self._send(200, job["result"])
        else:
            self._send(500, {"error": job["error"]})


def main():
    global READY
    if not (WEIGHTS / "model_index.json").is_file():
        raise SystemExit(f"weights missing at {WEIGHTS}")
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"Qwen-Image-2.1 offload door http://{HOST}:{PORT}  max_side={MAX_SIDE}", flush=True)
    READY = True
    print("ready; weights load on request and unload after completion", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--worker":
        worker_main(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        main()
