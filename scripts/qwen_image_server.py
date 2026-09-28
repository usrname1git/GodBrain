"""Qwen-Image-2.1 on this host. One GPU slot. Weights stay on C:\\nvme.

The 4080 Super has 16 GB. The full BF16 stack (7B DiT plus the Qwen3-VL 8B
text encoder) does not fit resident, so the pipeline uses CPU offload.
Default size is 1024. Native 2K stays behind QWEN_IMAGE_MAX=2048.
"""
import json
import os
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import torch

WEIGHTS = Path(os.environ.get("QWEN_IMAGE_WEIGHTS", r"C:\nvme\Qwen-Image-2.1"))
OUT = Path(os.environ.get("QWEN_IMAGE_OUT", r"C:\nvme\godbrain-sites\qwen-image"))
HOST = "127.0.0.1"
PORT = 8871
MAX_BODY = 1_048_576
MAX_SIDE = int(os.environ.get("QWEN_IMAGE_MAX", "1024"))
PIPE = None
GENERATE_LOCK = threading.Lock()


def load_pipe():
    global PIPE
    if PIPE is not None:
        return PIPE
    from diffusers import QwenImage21Pipeline

    pipe = QwenImage21Pipeline.from_pretrained(str(WEIGHTS), torch_dtype=torch.bfloat16)
    pipe.enable_model_cpu_offload()
    PIPE = pipe
    return pipe


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[qwen-image]", fmt % args, flush=True)

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/health":
            self._send(404, {"error": "not found"})
            return
        self._send(200, {"ok": True, "ready": PIPE is not None, "max_side": MAX_SIDE, "weights": str(WEIGHTS)})

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
        except ValueError as exc:
            self._send(400, {"error": str(exc)})
            return
        try:
            with GENERATE_LOCK:
                pipe = load_pipe()
                image = pipe(
                    prompt=prompt,
                    width=width,
                    height=height,
                    num_inference_steps=steps,
                    generator=torch.Generator("cuda").manual_seed(seed),
                ).images[0]
                OUT.mkdir(parents=True, exist_ok=True)
                token = f"{int(time.time())}-{uuid.uuid4().hex[:8]}"
                dest = OUT / f"qwen-image-{token}-{width}x{height}.png"
                image.save(dest)
            self._send(200, {"path": str(dest), "width": width, "height": height, "steps": steps, "seed": seed})
        except Exception as exc:
            traceback.print_exc()
            self._send(500, {"error": str(exc)})


def main():
    if not (WEIGHTS / "model_index.json").is_file():
        raise SystemExit(f"weights missing at {WEIGHTS}")
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"Qwen-Image-2.1 offload door http://{HOST}:{PORT}  max_side={MAX_SIDE}", flush=True)
    print("Loading the pipeline onto the 4080 with CPU offload. First load is slow.", flush=True)
    load_pipe()
    print("ready", flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
