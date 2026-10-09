"""CPU speech door for the iPhone and the desk.

STT is faster-whisper, TTS is Piper, and OCR is EasyOCR. None of them see
the GPU. If the 27B profile has Vision set, an OCR call tries the model
already on :8888 and falls back to EasyOCR when that tower is down.
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ["CUDA_VISIBLE_DEVICES"] = ""

WHISPER = Path(r"C:\nvme\faster-whisper-large-v3")
VOICES = Path(r"C:\nvme\piper-voices")
DEFAULT_VOICE = "en_US-lessac-medium"
MAX_BODY = 25 * 1024 * 1024
MAX_SPEECH = 4000
_lock = threading.Lock()
_whisper = None


def note(message: str) -> None:
    path = Path(__file__).resolve().parents[1] / "logs" / "voice-door.log"
    try:
        path.parent.mkdir(exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"{stamp} {message}\n")
    except OSError:
        pass


def prefer_tower(repo: Path) -> bool:
    path = repo / "logs" / "desk-model-settings.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return bool(data["profiles"]["27b"]["Vision"])
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return False


def tower_ready() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:8888/health", timeout=2) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return bool(payload.get("vision"))
    except (OSError, ValueError, TypeError):
        return False


def secret_ok(presented: str, expected: str) -> bool:
    if not expected or not presented:
        return False
    left = hashlib.sha256(presented.encode("utf-8")).digest()
    right = hashlib.sha256(expected.encode("utf-8")).digest()
    return hmac.compare_digest(left, right)


def header_value(headers, name: str) -> str:
    return headers.get(name) or ""


def authorized(handler, expected: str) -> bool:
    peer = handler.client_address[0]
    if peer in ("127.0.0.1", "::1"):
        return True
    presented = header_value(handler.headers, "X-API-Key")
    bearer = header_value(handler.headers, "Authorization")
    if bearer.lower().startswith("bearer "):
        presented = presented or bearer[7:].strip()
    return secret_ok(presented, expected)


def read_body(handler) -> bytes:
    length = int(handler.headers.get("Content-Length") or "0")
    if length <= 0 or length > MAX_BODY:
        raise ValueError("request body is empty or larger than 25 MB")
    return handler.rfile.read(length)


def query_value(path: str, name: str) -> str:
    query = path.split("?", 1)[1] if "?" in path else ""
    for bit in query.split("&"):
        key, sep, value = bit.partition("=")
        if sep and key == name:
            return urllib.parse.unquote_plus(value).strip()[:16]
    return ""


def decode_image_body(body: bytes, content_type: str) -> bytes:
    kind = content_type.split(";", 1)[0].strip().lower()
    if kind.startswith("multipart/"):
        parts = multipart_parts(content_type, body)
        image = parts.get("file") or parts.get("image")
        if not image:
            raise ValueError("form field file is empty")
        return image
    if kind == "application/json":
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("image json is unreadable") from exc
        raw = payload.get("image") or payload.get("file") or ""
        if not isinstance(raw, str) or not raw.strip():
            raise ValueError("json field image is empty")
        try:
            image = base64.b64decode(raw, validate=False)
        except (ValueError, binascii.Error) as exc:
            raise ValueError("json field image is not base64") from exc
        if not image:
            raise ValueError("json field image is empty")
        return image
    if not body:
        raise ValueError("request body is empty or larger than 25 MB")
    return body


def multipart_parts(content_type: str, body: bytes):
    marker = "boundary="
    if marker not in content_type:
        raise ValueError("multipart body has no boundary")
    boundary = content_type.split(marker, 1)[1].split(";", 1)[0].strip().strip('"')
    token = ("--" + boundary).encode("utf-8")
    parts = {}
    for chunk in body.split(token):
        if not chunk or chunk in (b"--", b"--\r\n"):
            continue
        chunk = chunk.strip(b"\r\n")
        if chunk.endswith(b"--"):
            chunk = chunk[:-2].rstrip(b"\r\n")
        head, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        disposition = head.decode("utf-8", "replace")
        name = ""
        for bit in disposition.split(";"):
            bit = bit.strip()
            if bit.lower().startswith("name="):
                name = bit.split("=", 1)[1].strip().strip('"')
        if name:
            parts[name] = data.removesuffix(b"\r\n")
    return parts


def load_whisper():
    global _whisper
    with _lock:
        if _whisper is None:
            from faster_whisper import WhisperModel
            _whisper = WhisperModel(str(WHISPER), device="cpu", compute_type="int8", cpu_threads=8)
        return _whisper


def transcribe(audio: bytes, suffix: str, language: str) -> str:
    if not WHISPER.is_dir():
        raise RuntimeError(f"missing Whisper weights at {WHISPER}")
    fd, name = tempfile.mkstemp(suffix=suffix or ".wav")
    os.close(fd)
    path = Path(name)
    try:
        path.write_bytes(audio)
        model = load_whisper()
        kwargs = {"vad_filter": True, "beam_size": 1}
        if language:
            kwargs["language"] = language
        segments, _info = model.transcribe(str(path), **kwargs)
        return " ".join(segment.text.strip() for segment in segments).strip()
    finally:
        path.unlink(missing_ok=True)


def synthesize(text: str, voice: str) -> bytes:
    stem = voice if (VOICES / f"{voice}.onnx").is_file() else DEFAULT_VOICE
    model = VOICES / f"{stem}.onnx"
    config = VOICES / f"{stem}.onnx.json"
    if not model.is_file() or not config.is_file():
        raise RuntimeError(f"missing Piper voice {stem}")
    fd, name = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    path = Path(name)
    try:
        completed = subprocess.run(
            [sys.executable, "-m", "piper", "-m", str(model), "-c", str(config), "-f", str(path)],
            input=text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        if completed.returncode != 0 or not path.is_file() or path.stat().st_size == 0:
            detail = completed.stderr.decode("utf-8", "replace")[-400:]
            raise RuntimeError(detail or "piper failed")
        return path.read_bytes()
    finally:
        path.unlink(missing_ok=True)


def ocr_cpu(image: bytes, suffix: str) -> str:
    import easyocr
    fd, name = tempfile.mkstemp(suffix=suffix or ".png")
    os.close(fd)
    path = Path(name)
    try:
        path.write_bytes(image)
        reader = easyocr.Reader(["en", "sv"], gpu=False, verbose=False)
        lines = reader.readtext(str(path), detail=0)
        return "\n".join(str(line) for line in lines).strip()
    finally:
        path.unlink(missing_ok=True)


def ocr_tower(image: bytes, mime: str) -> str:
    with urllib.request.urlopen("http://127.0.0.1:8888/v1/models", timeout=3) as response:
        models = json.loads(response.read().decode("utf-8"))
    model = models["data"][0]["id"]
    encoded = base64.b64encode(image).decode("ascii")
    body = {
        "model": model,
        "temperature": 0,
        "max_tokens": 1024,
        "stream": False,
        "tool_choice": "none",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "Transcribe every visible text line. Output only that text."},
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{encoded}"}},
            ],
        }],
    }
    request = urllib.request.Request(
        "http://127.0.0.1:8888/v1/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return str(payload["choices"][0]["message"]["content"]).strip()


class VoiceHandler(BaseHTTPRequestHandler):
    repo = Path(".")
    expected_key = ""
    server_port = 8001

    def log_message(self, fmt, *args):
        sys.stderr.write("voice %s %s\n" % (self.command, self.path.split("?", 1)[0]))

    def refuse(self, code: int, detail: str):
        body = json.dumps({"error": detail}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload, code=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def guard(self) -> bool:
        if authorized(self, self.expected_key):
            return True
        self.refuse(401, "missing or wrong X-API-Key")
        return False

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/health":
            self.refuse(404, "not found")
            return
        self.send_json({
            "ok": True,
            "service": "voice",
            "device": "cpu",
            "port": self.server_port,
            "bind": "tailnet" if self.server.server_address[0] == "0.0.0.0" else "loopback",
            "stt": "faster-whisper",
            "tts": "piper",
            "ocr": "qwen" if prefer_tower(self.repo) else "cpu",
        })

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        kind = header_value(self.headers, "Content-Type").split(";", 1)[0]
        length = self.headers.get("Content-Length") or "0"
        note(f"POST {path} bytes={length} type={kind or 'none'}")
        if not self.guard():
            note(f"POST {path} rejected")
            return
        try:
            if path == "/v1/audio/transcriptions":
                self.transcribe_request()
            elif path == "/v1/audio/speech":
                self.speech_request()
            elif path in ("/ocr", "/ingest/image"):
                self.ocr_request()
            else:
                self.refuse(404, "not found")
        except ValueError as exc:
            self.refuse(400, str(exc))
        except Exception as exc:
            self.refuse(503, str(exc)[:400])

    def audio_bytes(self):
        body = read_body(self)
        kind = header_value(self.headers, "Content-Type")
        language = query_value(self.path, "language")
        if kind.split(";", 1)[0].strip().lower().startswith("multipart/"):
            parts = multipart_parts(kind, body)
            audio = parts.get("file") or parts.get("audio")
            if not audio:
                raise ValueError("form field file is empty")
            if not language:
                raw = parts.get("language") or b""
                language = raw.decode("utf-8", "replace").strip()[:16]
            return audio, ".bin", language
        suffix = ".wav" if body.startswith(b"RIFF") else ".m4a"
        return body, suffix, language

    def transcribe_request(self):
        audio, suffix, language = self.audio_bytes()
        if language and not language.replace("-", "").isalpha():
            raise ValueError("language must be a short name such as sv or en")
        self.send_json({"text": transcribe(audio, suffix, language)})

    def speech_request(self):
        payload = json.loads(read_body(self).decode("utf-8"))
        text = str(payload.get("input") or "").strip()
        if not text or len(text) > MAX_SPEECH:
            raise ValueError("input must be 1 to 4000 characters")
        voice = str(payload.get("voice") or DEFAULT_VOICE)
        if not voice.replace("_", "").replace("-", "").isalnum():
            raise ValueError("unknown voice")
        audio = synthesize(text, voice)
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(audio)))
        self.end_headers()
        self.wfile.write(audio)

    def image_bytes(self):
        body = read_body(self)
        image = decode_image_body(body, header_value(self.headers, "Content-Type"))
        if image.startswith(b"\x89PNG"):
            return image, "image/png"
        return image, "image/jpeg"

    def ocr_request(self):
        image, mime = self.image_bytes()
        engine = "cpu"
        note = ""
        if prefer_tower(self.repo) and tower_ready():
            try:
                text = ocr_tower(image, mime)
                engine = "qwen"
            except (OSError, ValueError, KeyError, TypeError) as exc:
                text = ocr_cpu(image, ".png" if mime == "image/png" else ".jpg")
                note = str(exc)[:200]
        else:
            if prefer_tower(self.repo):
                note = "Qwen vision tower is off; CPU OCR answered"
            text = ocr_cpu(image, ".png" if mime == "image/png" else ".jpg")
        self.send_json({"text": text, "engine": engine, "note": note})


def serve(repo: Path, port: int):
    key = os.environ.get("X-API-Key") or os.environ.get("GODBRAIN_API_KEY") or ""
    host = "0.0.0.0" if key else "127.0.0.1"
    VoiceHandler.repo = repo
    VoiceHandler.expected_key = key
    VoiceHandler.server_port = port
    server = ThreadingHTTPServer((host, port), VoiceHandler)
    print(f"voice door {host}:{port} ocr={'qwen' if prefer_tower(repo) else 'cpu'}", flush=True)
    server.serve_forever()


def self_test() -> int:
    root = Path(tempfile.mkdtemp(prefix="voice-door-"))
    logs = root / "logs"
    logs.mkdir()
    (logs / "desk-model-settings.json").write_text(
        json.dumps({"version": 1, "profiles": {"27b": {"Vision": False}}}), encoding="utf-8")
    VoiceHandler.repo = root
    VoiceHandler.expected_key = "test-key"
    server = ThreadingHTTPServer(("127.0.0.1", 0), VoiceHandler)
    port = server.server_address[1]
    VoiceHandler.server_port = port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as response:
            health = json.loads(response.read().decode("utf-8"))
        if health.get("service") != "voice" or health.get("device") != "cpu" or health.get("ocr") != "cpu":
            raise RuntimeError(f"health {health}")
        (logs / "desk-model-settings.json").write_text(
            json.dumps({"version": 1, "profiles": {"27b": {"Vision": True}}}), encoding="utf-8")
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as response:
            health = json.loads(response.read().decode("utf-8"))
        if health.get("ocr") != "qwen":
            raise RuntimeError("vision preference did not change OCR mode")
        request = urllib.request.Request(f"http://127.0.0.1:{port}/ocr", data=b"", method="POST")
        try:
            urllib.request.urlopen(request, timeout=3)
            raise RuntimeError("empty OCR was accepted")
        except urllib.error.HTTPError as exc:
            if exc.code != 400:
                raise
        if query_value("/v1/audio/transcriptions?language=sv", "language") != "sv":
            raise RuntimeError("language query was dropped")
        raw = b"\xff\xd8\xff\xd9"
        if decode_image_body(raw, "application/octet-stream") != raw:
            raise RuntimeError("file body was rejected")
        encoded = base64.b64encode(raw).decode("ascii")
        if decode_image_body(json.dumps({"image": encoded}).encode(), "application/json") != raw:
            raise RuntimeError("base64 image was rejected")
        bad = urllib.request.Request(
            f"http://127.0.0.1:{port}/ocr",
            data=b'{"image":"!!!!"}',
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(bad, timeout=3)
            raise RuntimeError("bad base64 was accepted")
        except urllib.error.HTTPError as exc:
            if exc.code != 400:
                raise
        print("voice-door self-test ok", flush=True)
        return 0
    finally:
        server.shutdown()
        thread.join(timeout=3)


def main():
    if "--self-test" in sys.argv:
        try:
            raise SystemExit(self_test())
        except Exception as exc:
            print(f"voice-door self-test failed: {exc}", file=sys.stderr)
            raise SystemExit(1)
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8001)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    serve(args.repo, args.port)


if __name__ == "__main__":
    main()
