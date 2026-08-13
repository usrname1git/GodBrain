from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .ingestion import IngestionError, build_payload, extract_file, invoke_memory_store


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Securely extract explicitly supplied local text/images and submit them to Alexandria."
    )
    parser.add_argument("files", nargs="+", help="regular files to ingest (directories and links are rejected)")
    parser.add_argument(
        "--memory-store",
        default=os.environ.get("MONGO_STORE_PATH", "godbrain_core/memory_store/memory-store.exe"),
        help="path to the Go memory-store executable (default: MONGO_STORE_PATH or repository build path)",
    )
    parser.add_argument("--source-label", default="local", help="safe durable label; absolute paths are never stored")
    parser.add_argument(
        "--device",
        choices=("cpu", "gpu", "auto"),
        default="cpu",
        help="EasyOCR device selection for images (default: cpu)",
    )
    parser.add_argument(
        "--ocr-languages",
        default="en,sv",
        help="comma-separated EasyOCR languages from the bounded en/sv set (default: en,sv)",
    )
    parser.add_argument(
        "--ocr-model-dir",
        default=os.environ.get("EASYOCR_MODULE_PATH"),
        help="existing EasyOCR model directory; model downloads are disabled",
    )
    parser.add_argument(
        "--text-language",
        choices=("und", "en", "sv", "mixed"),
        default="und",
        help="provenance language for UTF-8 text files (default: und)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="extract, scan, and build bounded payloads without invoking Memory Store",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    languages = tuple(language.strip() for language in args.ocr_languages.split(",") if language.strip())
    try:
        prepared = [
            (
                Path(file_name).name,
                build_payload(
                    extract_file(
                        file_name,
                        device=args.device,
                        ocr_languages=languages,
                        text_language=args.text_language,
                        ocr_model_directory=args.ocr_model_dir,
                    ),
                    args.source_label,
                ),
            )
            for file_name in args.files
        ]
        if args.validate_only:
            for display_name, payload in prepared:
                print(
                    f"validated {display_name}: "
                    f"sha256={payload['document']['content_sha256']} chunks={len(payload['chunks'])}"
                )
            return 0
        for display_name, payload in prepared:
            receipt = invoke_memory_store(payload, args.memory_store)
            print(f"ingested {display_name}: status={receipt['status']} run_id={receipt['run_id']}")
        return 0
    except IngestionError as exc:
        print(f"ingestion failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
