"""Qwen-Image-2.1 on this host. One GPU slot. Weights stay on C:\\nvme.

The 4080 Super has 16 GB. The full BF16 stack (7B DiT plus the Qwen3-VL 8B
text encoder) does not fit resident, so the pipeline uses CPU offload.
Default size is 1024. Native 2K stays behind QWEN_IMAGE_MAX=2048.
"""
import json
import os
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import torch

WEIGHTS = Path(os.environ.get("QWEN_IMAGE_WEIGHTS", r"C:\nvme\Qwen-Image-2.1"))
OUT = Path(os.environ.get("QWEN_IMAGE_OUT", r"C:\nvme\godbrain-sites\qwen-image"))
HOST = os.environ.get("QWEN_IMAGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("QWEN_IMAGE_PORT", "8871"))
MAX_SIDE = int(os.environ.get("QWEN_IMAGE_MAX", "1024"))
PIPE = None


def load_pipe():
    global PIPE
    if PIPE is not None:
        return PIPE
    from diffusers import QwenImage21Pipeline

    pipe = QwenImage21Pipeline.from_pretrained(str(WEIGHTS), torch_dtype=torch.bfloat16)
    pipe.enable_model_cpu_offload()
    PIPE = pipe
    return pipe


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
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError as exc:
            self._send(400, {"error": str(exc)})
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
        width = clamp_side(w, 1024)
        height = clamp_side(h, 1024)
        steps = max(1, min(int(req.get("num_inference_steps") or req.get("steps") or 40), 40))
        seed = int(req.get("seed") or 0)
        try:
            pipe = load_pipe()
            image = pipe(
                prompt=prompt,
                width=width,
                height=height,
                num_inference_steps=steps,
                generator=torch.Generator("cuda").manual_seed(seed),
            ).images[0]
            OUT.mkdir(parents=True, exist_ok=True)
            dest = OUT / f"qwen-image-{seed}-{width}x{height}.png"
            image.save(dest)
            self._send(200, {"path": str(dest), "width": width, "height": height, "steps": steps})
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
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
