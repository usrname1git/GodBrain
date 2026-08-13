from __future__ import annotations

import hashlib
import importlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_EXTRACTED_BYTES = 3 * 1024 * 1024
MAX_CHUNK_BYTES = 32 * 1024
MAX_PAYLOAD_BYTES = 14 * 1024 * 1024
MAX_CHUNKS = 256
EXTRACTOR_ID = "Local-Document-Adapter"
EXTRACTOR_VERSION = "1.0.0"
SCHEMA_VERSION = "1.1-document"

TEXT_EXTENSIONS = {".txt", ".md", ".rst", ".csv", ".json", ".yaml", ".yml"}
IMAGE_EXTENSIONS = {
    ".png": "png",
    ".jpg": "jpeg",
    ".jpeg": "jpeg",
    ".bmp": "bmp",
    ".gif": "gif",
    ".tif": "tiff",
    ".tiff": "tiff",
    ".webp": "webp",
}
OCR_LANGUAGES = {"en", "sv"}

_SENSITIVE_PATTERNS = (
    ("OTP URI", re.compile(r"(?i)\botpauth(?:-migration)?://")),
    (
        "private key",
        re.compile(r"-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"),
    ),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{40,255})\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("live secret key", re.compile(r"\b(?:sk_live_|rk_live_)[0-9A-Za-z]{16,}\b")),
    ("JWT", re.compile(r"\beyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\b")),
    ("bearer token", re.compile(r"(?i)\bbearer[ \t]+[A-Za-z0-9._~+/=-]{16,}")),
    (
        "credential assignment",
        re.compile(
            r"""(?im)^\s*(?:api[_-]?key|password|passwd|private[_-]?key|client[_-]?secret|"""
            r"""access[_-]?token|bearer[_-]?token)\s*[:=]\s*["']?[^\s"']{8,}"""
        ),
    ),
)


class IngestionError(RuntimeError):
    """A safe diagnostic that never includes extracted document content."""


@dataclass(frozen=True)
class ExtractedDocument:
    display_name: str
    file_sha256: str
    text: str
    extraction_method: str
    languages: tuple[str, ...]
    backend: str
    backend_version: str
    confidence: float | None


def _rotate_left(value: int, shift: int) -> int:
    shift %= 64
    return ((value << shift) | (value >> (64 - shift))) & ((1 << 64) - 1)


def _keccak_f1600(state: list[int]) -> None:
    rotations = (
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
        41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
    )
    round_constants = (
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
        0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
        0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
        0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    )
    mask = (1 << 64) - 1
    for constant in round_constants:
        columns = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        deltas = [columns[(x - 1) % 5] ^ _rotate_left(columns[(x + 1) % 5], 1) for x in range(5)]
        for y in range(5):
            for x in range(5):
                state[x + 5 * y] ^= deltas[x]
        permuted = [0] * 25
        for y in range(5):
            for x in range(5):
                permuted[y + 5 * ((2 * x + 3 * y) % 5)] = _rotate_left(
                    state[x + 5 * y], rotations[x + 5 * y]
                )
        for y in range(5):
            for x in range(5):
                state[x + 5 * y] = (
                    permuted[x + 5 * y]
                    ^ ((~permuted[(x + 1) % 5 + 5 * y]) & permuted[(x + 2) % 5 + 5 * y])
                ) & mask
        state[0] ^= constant


def legacy_keccak256(data: bytes) -> str:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    padded.extend(b"\x00" * ((rate - len(padded) % rate) % rate))
    padded[-1] |= 0x80
    state = [0] * 25
    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for lane in range(rate // 8):
            state[lane] ^= int.from_bytes(block[lane * 8 : lane * 8 + 8], "little")
        _keccak_f1600(state)
    output = b"".join(lane.to_bytes(8, "little") for lane in state[: rate // 8])
    return output[:32].hex()


def _is_reparse_point(file_stat: os.stat_result) -> bool:
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    attributes = getattr(file_stat, "st_file_attributes", 0)
    return bool(attributes & reparse_flag)


def _read_regular_file(path: Path) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise IngestionError("cannot inspect the supplied file") from exc
    if stat.S_ISLNK(before.st_mode) or _is_reparse_point(before):
        raise IngestionError("symlinks and reparse points are not accepted")
    if not stat.S_ISREG(before.st_mode):
        raise IngestionError("the supplied path is not a regular file")
    if before.st_size <= 0:
        raise IngestionError("the supplied file is empty")
    if before.st_size > MAX_FILE_BYTES:
        raise IngestionError(f"the supplied file exceeds the {MAX_FILE_BYTES} byte limit")

    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise IngestionError("the supplied file is unreadable") from exc
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or _is_reparse_point(opened):
            raise IngestionError("the supplied path is not a regular file")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise IngestionError("the supplied file changed while being opened")
        data = bytearray()
        while len(data) <= MAX_FILE_BYTES:
            part = os.read(descriptor, min(1024 * 1024, MAX_FILE_BYTES + 1 - len(data)))
            if not part:
                break
            data.extend(part)
    except OSError as exc:
        raise IngestionError("the supplied file could not be read") from exc
    finally:
        os.close(descriptor)
    if len(data) > MAX_FILE_BYTES:
        raise IngestionError(f"the supplied file exceeds the {MAX_FILE_BYTES} byte limit")
    return bytes(data)


def _image_type(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"BM"):
        return "bmp"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    if data.startswith((b"II*\x00", b"MM\x00*")):
        return "tiff"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def _load_easyocr(
    device: str, languages: Sequence[str], model_directory: str | None
) -> tuple[Any, str]:
    try:
        easyocr = importlib.import_module("easyocr")
    except ModuleNotFoundError as exc:
        raise IngestionError(
            "image ingestion requires the optional EasyOCR dependencies"
        ) from exc
    try:
        torch = importlib.import_module("torch")
    except ModuleNotFoundError as exc:
        raise IngestionError("the EasyOCR installation is missing its Torch dependency") from exc
    cuda_available = bool(torch.cuda.is_available())
    if device == "gpu" and not cuda_available:
        raise IngestionError("GPU OCR was requested but CUDA is unavailable")
    use_gpu = cuda_available if device == "auto" else device == "gpu"
    reader_options: dict[str, Any] = {"gpu": use_gpu, "download_enabled": False}
    if model_directory is not None:
        reader_options["model_storage_directory"] = model_directory
    try:
        reader = easyocr.Reader(list(languages), **reader_options)
    except (RuntimeError, ValueError, OSError) as exc:
        raise IngestionError("EasyOCR initialization failed") from exc
    return reader, str(getattr(easyocr, "__version__", "unknown"))


def _extract_ocr(
    data: bytes,
    device: str,
    languages: Sequence[str],
    model_directory: str | None,
    loader: Callable[[str, Sequence[str], str | None], tuple[Any, str]],
) -> tuple[str, float, str]:
    reader, backend_version = loader(device, languages, model_directory)
    try:
        results = reader.readtext(data, detail=1)
    except (RuntimeError, ValueError, OSError) as exc:
        raise IngestionError("EasyOCR extraction failed") from exc
    lines: list[str] = []
    confidences: list[float] = []
    extracted_bytes = 0
    for result in results:
        if not isinstance(result, (list, tuple)) or len(result) < 3:
            raise IngestionError("EasyOCR returned an invalid result")
        text = str(result[1]).strip()
        try:
            confidence = float(result[2])
        except (TypeError, ValueError, OverflowError) as exc:
            raise IngestionError("EasyOCR returned an invalid confidence") from exc
        if not math.isfinite(confidence) or confidence < 0 or confidence > 1:
            raise IngestionError("EasyOCR returned an invalid confidence")
        if text:
            extracted_bytes += len(text.encode("utf-8")) + 1
            if extracted_bytes > MAX_EXTRACTED_BYTES:
                raise IngestionError("OCR extraction exceeds the extracted-text limit")
            lines.append(text)
            confidences.append(confidence)
    if not lines:
        raise IngestionError("OCR extraction produced no text")
    return "\n".join(lines), sum(confidences) / len(confidences), backend_version


def scan_sensitive_content(text: str) -> str | None:
    text = "\n".join(text.splitlines())
    for category, pattern in _SENSITIVE_PATTERNS:
        if pattern.search(text):
            return category
    return None


def normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n")
    normalized = "\n".join(line.rstrip() for line in normalized.split("\n")).strip()
    normalized = re.sub(r"\n{4,}", "\n\n\n", normalized)
    return normalized


def extract_file(
    path: str | os.PathLike[str],
    *,
    device: str = "cpu",
    ocr_languages: Sequence[str] = ("en", "sv"),
    text_language: str = "und",
    ocr_model_directory: str | None = None,
    ocr_loader: Callable[[str, Sequence[str], str | None], tuple[Any, str]] = _load_easyocr,
) -> ExtractedDocument:
    file_path = Path(path)
    display_name = _safe_display_name(file_path.name)
    if scan_sensitive_content(display_name) is not None:
        raise IngestionError("sensitive content rejected in the supplied file name")
    extension = file_path.suffix.lower()
    if extension not in TEXT_EXTENSIONS and extension not in IMAGE_EXTENSIONS:
        raise IngestionError("unsupported file type")
    if device not in {"cpu", "gpu", "auto"}:
        raise IngestionError("OCR device must be cpu, gpu, or auto")
    languages = tuple(dict.fromkeys(ocr_languages))
    if not languages or any(language not in OCR_LANGUAGES for language in languages):
        raise IngestionError("OCR languages are limited to en and sv")

    data = _read_regular_file(file_path)
    file_hash = hashlib.sha256(data).hexdigest()
    if extension in TEXT_EXTENSIONS:
        if b"\x00" in data[:8192] or _image_type(data) is not None:
            raise IngestionError("text file content is not UTF-8-oriented text")
        try:
            extracted = data.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise IngestionError("text file is not valid UTF-8") from exc
        if any(
            unicodedata.category(character) == "Cc" and character not in "\t\n\r"
            for character in extracted
        ):
            raise IngestionError("text file contains disallowed control characters")
        method = "utf-8"
        document_languages = (text_language,)
        backend = "python-codecs"
        backend_version = sys.version.split()[0]
        confidence = None
    else:
        detected = _image_type(data)
        if detected != IMAGE_EXTENSIONS[extension]:
            raise IngestionError("image content does not match its supported type")
        extracted, confidence, backend_version = _extract_ocr(
            data, device, languages, ocr_model_directory, ocr_loader
        )
        method = "easyocr"
        document_languages = languages
        backend = "easyocr"

    sensitive_category = scan_sensitive_content(extracted)
    if sensitive_category is not None:
        raise IngestionError(f"sensitive content rejected ({sensitive_category})")
    normalized = normalize_text(extracted)
    if not normalized:
        raise IngestionError("extraction produced no text")
    if scan_sensitive_content(normalized) is not None:
        raise IngestionError("sensitive content rejected after normalization")
    if len(normalized.encode("utf-8")) > MAX_EXTRACTED_BYTES:
        raise IngestionError(f"extracted text exceeds the {MAX_EXTRACTED_BYTES} byte limit")
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", backend_version):
        raise IngestionError("extraction backend returned an invalid version")
    return ExtractedDocument(
        display_name=display_name,
        file_sha256=file_hash,
        text=normalized,
        extraction_method=method,
        languages=document_languages,
        backend=backend,
        backend_version=backend_version,
        confidence=confidence,
    )


def _safe_display_name(name: str) -> str:
    safe = "".join(character if _is_safe_display_name_character(character) else "_" for character in name)
    safe = safe.strip()
    safe = safe.encode("utf-8")[:128].decode("utf-8", errors="ignore")
    if not safe or safe in {".", ".."}:
        raise IngestionError("file name has no safe display representation")
    return safe


def _is_safe_display_name_character(character: str) -> bool:
    codepoint = ord(character)
    return (
        character not in "/\\:"
        and codepoint > 0x1F
        and not 0x7F <= codepoint <= 0x9F
        and codepoint not in {0x2028, 0x2029}
    )


def _safe_source_label(label: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", label):
        raise IngestionError("source label must be 1-64 letters, digits, dots, underscores, or hyphens")
    if scan_sensitive_content(label) is not None:
        raise IngestionError("sensitive content rejected in the source label")
    return label


def chunk_text(text: str, max_bytes: int = MAX_CHUNK_BYTES) -> list[dict[str, Any]]:
    if max_bytes <= 0 or max_bytes > MAX_CHUNK_BYTES:
        raise IngestionError(f"chunk size must be between 1 and {MAX_CHUNK_BYTES} bytes")
    encoded = text.encode("utf-8")
    chunks: list[dict[str, Any]] = []
    start = 0
    while start < len(encoded):
        end = min(len(encoded), start + max_bytes)
        while end > start and end < len(encoded) and encoded[end] & 0xC0 == 0x80:
            end -= 1
        if end == start:
            raise IngestionError("chunk size cannot contain one UTF-8 character")
        segment = encoded[start:end].decode("utf-8")
        if end < len(encoded):
            consumed = 0
            preferred = 0
            for character in segment:
                consumed += len(character.encode("utf-8"))
                if character.isspace() and consumed >= max_bytes // 2:
                    preferred = consumed
            if preferred:
                end = start + preferred
                segment = encoded[start:end].decode("utf-8")
        stripped_left = segment.lstrip()
        content_start = end - len(stripped_left.encode("utf-8"))
        stripped = stripped_left.rstrip()
        content_end = content_start + len(stripped.encode("utf-8"))
        if content_start < content_end:
            chunks.append(
                {
                    "start_byte": content_start,
                    "end_byte": content_end,
                    "text": encoded[content_start:content_end].decode("utf-8"),
                }
            )
        start = end
    if not chunks or len(chunks) > MAX_CHUNKS:
        raise IngestionError(f"extracted text exceeds the {MAX_CHUNKS} chunk limit")
    count = len(chunks)
    for index, chunk in enumerate(chunks):
        chunk["index"] = index
        chunk["count"] = count
    return chunks


def build_payload(document: ExtractedDocument, source_label: str = "local") -> dict[str, Any]:
    label = _safe_source_label(source_label)
    display_name = _safe_display_name(document.display_name)
    raw = document.text.encode("utf-8")
    source_hash = legacy_keccak256(raw)
    content_hash = hashlib.sha256(raw).hexdigest()
    chunks = chunk_text(document.text)
    for chunk in chunks:
        if document.confidence is not None:
            chunk["confidence"] = document.confidence
    payload = {
        "extractor_id": EXTRACTOR_ID,
        "extractor_version": (
            f"{EXTRACTOR_VERSION}+{document.backend}-{document.backend_version}"
        ),
        "schema_version": SCHEMA_VERSION,
        "degraded": False,
        "payload": {
            "trust_tier": "candidate",
            "provenance": {
                "source_id": f"local-document:{label}:{display_name}",
                "source_type": "local_document",
                "source_hash": source_hash,
                "language": ",".join(document.languages),
                "prompt_hash": hashlib.sha256(b"not-applicable").hexdigest(),
                "model_id": "not-applicable",
                "model_hash": hashlib.sha256(b"").hexdigest(),
                "llm_temperature": 0.0,
            },
            "claims": [],
            "core_concepts": [],
            "opsec_candidates": [],
        },
        "raw_transcript": document.text,
        "document": {
            "source_label": label,
            "display_name": display_name,
            "file_sha256": document.file_sha256,
            "content_sha256": content_hash,
            "extraction_method": document.extraction_method,
            "languages": list(document.languages),
            "backend": document.backend,
            "backend_version": document.backend_version,
            "chunk_count": len(chunks),
        },
        "chunks": chunks,
    }
    if document.confidence is not None:
        payload["document"]["ocr_confidence"] = document.confidence
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_PAYLOAD_BYTES:
        raise IngestionError("Memory Store payload exceeds the bounded adapter limit")
    return payload


def invoke_memory_store(
    payload: dict[str, Any],
    executable: str | os.PathLike[str],
    *,
    timeout_seconds: float = 45,
) -> dict[str, Any]:
    command = [os.fspath(executable)]
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
    except OSError as exc:
        raise IngestionError("could not start the Memory Store executable") from exc
    try:
        stdout, _stderr = process.communicate(encoded, timeout=timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise IngestionError("Memory Store invocation timed out") from exc
    if len(stdout) > 64 * 1024:
        raise IngestionError("Memory Store returned an oversized response")
    try:
        response = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise IngestionError("Memory Store returned an invalid response") from exc
    if process.returncode != 0:
        category = response.get("error") if isinstance(response, dict) else None
        if isinstance(category, str) and category.isprintable() and len(category) <= 256:
            raise IngestionError(f"Memory Store rejected the document ({category})")
        raise IngestionError("Memory Store rejected the document")
    required_strings = ("run_id", "record_id", "version", "schema_version", "timestamp")
    valid_counts = all(
        isinstance(response.get(field), int)
        and not isinstance(response.get(field), bool)
        and response[field] >= 0
        for field in ("insert_count", "update_count")
    ) if isinstance(response, dict) else False
    if (
        not isinstance(response, dict)
        or response.get("status") not in {"committed", "idempotent_noop"}
        or any(not isinstance(response.get(field), str) or not response[field] for field in required_strings)
        or not valid_counts
    ):
        raise IngestionError("Memory Store returned an unexpected receipt")
    return response
