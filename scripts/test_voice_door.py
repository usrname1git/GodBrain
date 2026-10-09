import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import wave

import voice_door as voice


def form_body(payload, name="file"):
    return (
        b'--fixture-boundary\r\nContent-Disposition: form-data; name="'
        + name.encode("ascii")
        + b'"; filename="clip;notes.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'
        + payload
        + b"\r\n--fixture-boundary--\r\n"
    )


class MultipartTests(unittest.TestCase):
    content_type = 'multipart/form-data; boundary="fixture-boundary"'

    def test_binary_payload_is_preserved_exactly(self):
        for payload in (b"a\r", b"a\n", b"a\r\n", b"a--", b"\r\na\r\n\r\n", bytes(range(256)),
                        b"prefix--fixture-boundarysuffix", b"data\r\n--fixture-boundarysuffix\r\nmore"):
            with self.subTest(payload=payload):
                parts = voice.multipart_parts(self.content_type, form_body(payload))
                self.assertEqual(parts["file"], payload)
                self.assertEqual(voice.decode_image_body(form_body(payload), self.content_type), payload)

    def test_multiple_fields_are_extracted_without_trimming(self):
        body = form_body(b"\r\nimage--").removesuffix(b"--fixture-boundary--\r\n")
        body += (
            b'--fixture-boundary\r\nContent-Disposition: form-data; name="language"\r\n\r\n'
            b"sv\r\n--fixture-boundary--\r\n"
        )
        self.assertEqual(voice.multipart_parts(self.content_type, body),
                         {"file": b"\r\nimage--", "language": b"sv"})

    def test_wav_final_sample_is_not_trimmed(self):
        for sample in (b"\r\n", b"--", b"\0\0"):
            with self.subTest(sample=sample):
                output = io.BytesIO()
                with wave.open(output, "wb") as writer:
                    writer.setnchannels(1)
                    writer.setsampwidth(2)
                    writer.setframerate(16000)
                    writer.writeframes(b"\0\0" + sample)
                audio = output.getvalue()
                extracted = voice.multipart_parts(self.content_type, form_body(audio))["file"]
                self.assertEqual(extracted, audio)
                with wave.open(io.BytesIO(extracted), "rb") as reader:
                    self.assertEqual(reader.readframes(reader.getnframes()), b"\0\0" + sample)

    def test_malformed_framing_is_rejected(self):
        for content_type, body in (
            ("multipart/form-data", form_body(b"data")),
            (self.content_type, b"not a multipart body"),
            (self.content_type, form_body(b"data").removesuffix(b"--fixture-boundary--\r\n")),
            (self.content_type + "\r\nInjected: header", form_body(b"data")),
        ):
            with self.subTest(content_type=content_type, body=body):
                with self.assertRaises(ValueError):
                    voice.multipart_parts(content_type, body)


class VoiceSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="voice-settings-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "logs").mkdir()
        self.settings = self.repo / "logs" / "desk-model-settings.json"

    def write_settings(self, vision):
        self.settings.write_text(
            json.dumps({"version": 1, "profiles": {"27b": {"Vision": vision}}}), encoding="utf-8")

    def test_boolean_preferences_and_missing_preference(self):
        self.assertFalse(voice.prefer_tower(self.repo))
        for value in (False, True):
            self.write_settings(value)
            self.assertIs(voice.prefer_tower(self.repo), value)
        self.settings.write_text('{"version":1,"profiles":{"27b":{}}}', encoding="utf-8")
        self.assertFalse(voice.prefer_tower(self.repo))

    def test_non_boolean_preferences_are_rejected(self):
        for value in ("false", "true", 0, 1, None, {}, []):
            with self.subTest(value=value):
                self.write_settings(value)
                with self.assertRaisesRegex(RuntimeError, "Vision.*true or false"):
                    voice.prefer_tower(self.repo)

    def test_invalid_configuration_is_not_silently_defaulted(self):
        for text in ("not json", "[]", '{"version":1,"profiles":[]}',
                     '{"version":1,"profiles":{"27b":[]}}'):
            with self.subTest(text=text):
                self.settings.write_text(text, encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    voice.prefer_tower(self.repo)
        self.settings.write_bytes(b"\xff")
        with self.assertRaises(RuntimeError):
            voice.prefer_tower(self.repo)
        with patch.object(Path, "read_text", side_effect=PermissionError("fixture")):
            with self.assertRaises(RuntimeError):
                voice.prefer_tower(self.repo)

    def test_invalid_settings_fail_before_binding_a_listener(self):
        self.write_settings("false")
        handler = type("FixtureVoiceHandler", (voice.VoiceHandler,), {})
        with patch.object(voice, "VoiceHandler", handler), patch.object(voice, "ThreadingHTTPServer") as server:
            with self.assertRaises(RuntimeError):
                voice.serve(self.repo, 0)
            server.assert_not_called()

    def test_invalid_settings_return_explicit_http_errors_without_ocr(self):
        self.write_settings("false")
        handler = type("FixtureVoiceHandler", (voice.VoiceHandler,), {"repo": self.repo})
        server = voice.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            with patch.object(voice, "note"), patch.object(voice, "ocr_cpu") as cpu, \
                    patch.object(voice, "ocr_tower") as tower, patch.object(voice, "tower_ready") as ready:
                for request in (
                    urllib.request.Request(url + "/health"),
                    urllib.request.Request(url + "/ocr", data=b"fixture-image", method="POST"),
                ):
                    with self.subTest(url=request.full_url):
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen(request, timeout=3)
                        self.assertEqual(error.exception.code, 503)
                        self.assertIn("Vision", json.loads(error.exception.read())["error"])
                        error.exception.close()
                cpu.assert_not_called()
                tower.assert_not_called()
                ready.assert_not_called()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_audio_http_passes_exact_uploaded_bytes_to_transcription(self):
        handler = type("FixtureVoiceHandler", (voice.VoiceHandler,), {"repo": self.repo})
        server = voice.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        audio = b"RIFFfixture-audio\r\n--"
        body = form_body(audio)
        url = f"http://127.0.0.1:{server.server_address[1]}/v1/audio/transcriptions?language=sv"
        request = urllib.request.Request(
            url, data=body, headers={"Content-Type": MultipartTests.content_type}, method="POST")
        try:
            with patch.object(voice, "note"), patch.object(voice, "transcribe", return_value="fixture") as transcribe:
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(json.loads(response.read())["text"], "fixture")
                transcribe.assert_called_once_with(audio, ".bin", "sv")
                for malformed in (b"not multipart", body.removesuffix(b"--fixture-boundary--\r\n")):
                    request = urllib.request.Request(
                        url, data=malformed, headers={"Content-Type": MultipartTests.content_type}, method="POST")
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(request, timeout=3)
                    self.assertEqual(error.exception.code, 400)
                    self.assertIn("multipart", json.loads(error.exception.read())["error"])
                    error.exception.close()
                self.assertEqual(transcribe.call_count, 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
