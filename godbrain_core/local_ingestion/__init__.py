"""Secure local document adapter for the Alexandria Memory Store."""

from .ingestion import (
    MAX_CHUNK_BYTES,
    MAX_EXTRACTED_BYTES,
    MAX_FILE_BYTES,
    IngestionError,
    build_payload,
    extract_file,
    scan_sensitive_content,
)

__all__ = [
    "MAX_CHUNK_BYTES",
    "MAX_EXTRACTED_BYTES",
    "MAX_FILE_BYTES",
    "IngestionError",
    "build_payload",
    "extract_file",
    "scan_sensitive_content",
]
