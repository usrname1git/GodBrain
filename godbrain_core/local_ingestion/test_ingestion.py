from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from godbrain_core.local_ingestion.ingestion import (
    MAX_CHUNK_BYTES,
    MAX_FILE_BYTES,
    ExtractedDocument,
    IngestionError,
    build_payload,
    chunk_text,
    extract_file,
    legacy_keccak256,
    scan_sensitive_content,
    invoke_memory_store,
)


class FakeOCRReader:
    def readtext(self, data: bytes, detail: int) -> list[tuple[object, str, float]]:
        self.seen = (data, detail)
        return [([], "Hej world", 0.75)]


class LocalIngestionTests(unittest.TestCase):
    def test_text_payload_hashes_and_provenance_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "notes.md")
            path.write_bytes(b"Hello\r\nworld  \n")
            document = extract_file(path, text_language="en")
            first = build_payload(document, "research")
            second = build_payload(document, "research")

        self.assertEqual(first, second)
        self.assertEqual(first["raw_transcript"], "Hello\nworld")
        self.assertEqual(
            first["payload"]["provenance"]["source_hash"],
            legacy_keccak256(b"Hello\nworld"),
        )
        self.assertEqual(
            first["document"]["file_sha256"],
            hashlib.sha256(b"Hello\r\nworld  \n").hexdigest(),
        )
        self.assertEqual(first["document"]["content_sha256"], hashlib.sha256(b"Hello\nworld").hexdigest())
        self.assertNotIn(directory, str(first))
        self.assertEqual(first["extractor_id"], "Local-Document-Adapter")
        self.assertEqual(first["payload"]["claims"], [])

    def test_keccak_matches_memory_store_legacy_hash(self) -> None:
        self.assertEqual(
            legacy_keccak256(b""),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        )

    def test_chunking_uses_exact_bounded_utf8_ranges(self) -> None:
        text = ("a" * (MAX_CHUNK_BYTES - 3)) + "\n" + ("svenska \u00e5\u00e4\u00f6 " * 2000)
        chunks = chunk_text(text)
        encoded = text.encode("utf-8")
        self.assertGreater(len(chunks), 1)
        for index, chunk in enumerate(chunks):
            self.assertEqual(chunk["index"], index)
            self.assertEqual(chunk["count"], len(chunks))
            self.assertLessEqual(chunk["end_byte"] - chunk["start_byte"], MAX_CHUNK_BYTES)
            self.assertEqual(
                encoded[chunk["start_byte"] : chunk["end_byte"]].decode("utf-8"),
                chunk["text"],
            )

    def test_rejects_unsupported_and_magic_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            unsupported = Path(directory, "data.exe")
            unsupported.write_bytes(b"plain text")
            fake_image = Path(directory, "fake.png")
            fake_image.write_bytes(b"plain text")
            with self.assertRaisesRegex(IngestionError, "unsupported"):
                extract_file(unsupported)
            with self.assertRaisesRegex(IngestionError, "does not match"):
                extract_file(fake_image)

    def test_rejects_directory_empty_and_oversized_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            disguised_directory = Path(directory, "folder.txt")
            disguised_directory.mkdir()
            empty = Path(directory, "empty.txt")
            empty.touch()
            oversized = Path(directory, "oversized.txt")
            with oversized.open("wb") as stream:
                stream.truncate(MAX_FILE_BYTES + 1)
            with self.assertRaisesRegex(IngestionError, "regular file"):
                extract_file(disguised_directory)
            with self.assertRaisesRegex(IngestionError, "empty"):
                extract_file(empty)
            with self.assertRaisesRegex(IngestionError, "exceeds"):
                extract_file(oversized)

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory, "target.txt")
            target.write_text("safe", encoding="utf-8")
            link = Path(directory, "link.txt")
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest("symlink creation is not permitted")
            with self.assertRaisesRegex(IngestionError, "symlinks"):
                extract_file(link)

    def test_missing_easyocr_is_explicit_and_text_does_not_import_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            text = Path(directory, "text.txt")
            text.write_text("ordinary text", encoding="utf-8")
            with mock.patch("importlib.import_module", side_effect=AssertionError("must stay lazy")):
                extract_file(text)

            image = Path(directory, "image.png")
            image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)

            def missing(
                _device: str, _languages: object, _model_directory: str | None
            ) -> tuple[object, str]:
                raise IngestionError("image ingestion requires the optional EasyOCR dependencies")

            with self.assertRaisesRegex(IngestionError, "optional EasyOCR"):
                extract_file(image, ocr_loader=missing)
            with mock.patch(
                "godbrain_core.local_ingestion.ingestion.importlib.import_module",
                side_effect=ModuleNotFoundError("easyocr"),
            ):
                with self.assertRaisesRegex(IngestionError, "optional EasyOCR"):
                    extract_file(image)

    def test_ocr_provenance_includes_languages_backend_and_confidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory, "image.png")
            data = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
            image.write_bytes(data)
            reader = FakeOCRReader()
            document = extract_file(
                image,
                device="cpu",
                ocr_loader=lambda _device, _languages, _model_directory: (reader, "1.7.2"),
            )
            payload = build_payload(document)
        self.assertEqual(reader.seen, (data, 1))
        self.assertEqual(payload["document"]["languages"], ["en", "sv"])
        self.assertEqual(payload["document"]["backend"], "easyocr")
        self.assertEqual(payload["document"]["ocr_confidence"], 0.75)
        self.assertTrue(all(chunk["confidence"] == 0.75 for chunk in payload["chunks"]))

    def test_sensitive_fixtures_are_rejected_without_secret_in_error(self) -> None:
        fixtures = {
            "otp": "otpauth://totp/Example?secret=ABCDEFGHIJKLMNOP",
            "migration": "otpauth-migration://offline?data=AAAA",
            "private": "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----",
            "token": "Authorization: Bearer synthetic_token_value_123456",
            "assignment": "api_key=syntheticcredentialvalue",
            "line-separator": "heading\u2028api_key=syntheticcredentialvalue",
            "cr-separator": "heading\rapi_key=syntheticcredentialvalue",
        }
        for name, content in fixtures.items():
            with self.subTest(name=name):
                self.assertIsNotNone(scan_sensitive_content(content))
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory, f"{name}.txt")
                    path.write_text(content, encoding="utf-8")
                    with self.assertRaises(IngestionError) as raised:
                        extract_file(path)
                    self.assertNotIn("syntheticcredentialvalue", str(raised.exception))
                    self.assertNotIn("synthetic_token_value", str(raised.exception))

    def test_source_label_is_bounded(self) -> None:
        document = ExtractedDocument(
            display_name="a.txt",
            file_sha256="0" * 64,
            text="safe",
            extraction_method="utf-8",
            languages=("und",),
            backend="python-codecs",
            backend_version="3",
            confidence=None,
        )
        with self.assertRaisesRegex(IngestionError, "source label"):
            build_payload(document, "../private")

    def test_incomplete_success_receipt_is_rejected(self) -> None:
        process = mock.Mock()
        process.communicate.return_value = (b'{"status":"committed"}', b"")
        process.returncode = 0
        with mock.patch(
            "godbrain_core.local_ingestion.ingestion.subprocess.Popen",
            return_value=process,
        ):
            with self.assertRaisesRegex(IngestionError, "unexpected receipt"):
                invoke_memory_store({"bounded": True}, "memory-store.exe")


if __name__ == "__main__":
    unittest.main()
