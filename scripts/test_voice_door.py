import io
import json
from pathlib import Path
import tempfile
import threading
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request
import wave

import voice_door as voice
import numpy as np


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
        with voice._status_lock:
            voice._component_results.clear()

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

    def test_tower_readiness_requires_explicit_idle_vision_health(self):
        for payload, expected in (
            ({"vision": True, "busy": False}, True),
            ({"vision": True, "busy": True}, False),
            ({"vision": True}, False),
            ({"vision": True, "busy": "false"}, False),
            ({"vision": False, "busy": False}, False),
            ({"vision": "true", "busy": False}, False),
            ([], False),
        ):
            with self.subTest(payload=payload):
                response = io.BytesIO(json.dumps(payload).encode("utf-8"))
                with patch.object(voice.urllib.request, "urlopen", return_value=response):
                    self.assertIs(voice.tower_ready(), expected)
        with patch.object(voice.urllib.request, "urlopen", side_effect=OSError("fixture down")):
            self.assertFalse(voice.tower_ready())

    def test_ocr_uses_cpu_when_tower_is_busy_and_preserves_idle_tower(self):
        self.write_settings(True)
        for busy in (True, False):
            with self.subTest(busy=busy):
                handler = object.__new__(voice.VoiceHandler)
                handler.repo = self.repo
                handler.image_bytes = Mock(return_value=(b"fixture-image", "image/jpeg"))
                handler.send_json = Mock()
                response = io.BytesIO(json.dumps({"vision": True, "busy": busy}).encode("utf-8"))
                with patch.object(voice.urllib.request, "urlopen", return_value=response), \
                        patch.object(voice, "ocr_cpu", return_value="cpu fixture") as cpu, \
                        patch.object(voice, "ocr_tower", return_value="tower fixture") as tower:
                    handler.ocr_request()
                    result = handler.send_json.call_args.args[0]
                    if busy:
                        cpu.assert_called_once_with(b"fixture-image", ".jpg")
                        tower.assert_not_called()
                        self.assertEqual(result["engine"], "cpu")
                        self.assertIn("busy", result["note"])
                    else:
                        tower.assert_called_once_with(b"fixture-image", "image/jpeg")
                        cpu.assert_not_called()
                        self.assertEqual(result["engine"], "qwen")

    def test_cpu_ocr_disables_downloads_and_surfaces_missing_assets(self):
        from PIL import Image
        output = io.BytesIO()
        Image.new("RGB", (2, 3), (10, 20, 30)).save(output, format="PNG")
        image = output.getvalue()
        def readtext(pixels, detail):
            self.assertIsInstance(pixels, np.ndarray)
            self.assertEqual(pixels.shape, (3, 2, 3))
            self.assertEqual(pixels[0, 0].tolist(), [30, 20, 10])
            self.assertTrue(pixels.flags.c_contiguous)
            self.assertEqual(detail, 0)
            return ["fixture text"]
        reader = Mock(readtext=Mock(side_effect=readtext))
        factory = Mock(return_value=reader)
        with patch.dict(sys.modules, {"easyocr": SimpleNamespace(Reader=factory)}):
            self.assertEqual(voice.ocr_cpu(image, ".png"), "fixture text")
            factory.assert_called_once_with(["en", "sv"], gpu=False, verbose=False, download_enabled=False)
            factory.side_effect = FileNotFoundError("Missing local OCR weights; downloads disabled")
            with self.assertRaisesRegex(FileNotFoundError, "Missing local OCR weights"):
                voice.ocr_cpu(image, ".png")

    def test_cpu_ocr_rejects_invalid_images_before_loading_weights(self):
        factory = Mock()
        with patch.dict(sys.modules, {"easyocr": SimpleNamespace(Reader=factory)}):
            with self.assertRaisesRegex(ValueError, "decodable"):
                voice.ocr_cpu(b"not an image", ".jpg")
        factory.assert_not_called()

    def test_cpu_ocr_applies_exif_orientation(self):
        from PIL import Image
        output = io.BytesIO()
        image = Image.new("RGB", (2, 3), (10, 20, 30))
        exif = image.getexif()
        exif[274] = 6
        image.save(output, format="PNG", exif=exif)
        reader = Mock()
        reader.readtext.return_value = ["rotated text"]
        with patch.dict(sys.modules, {"easyocr": SimpleNamespace(Reader=Mock(return_value=reader))}):
            self.assertEqual(voice.ocr_cpu(output.getvalue(), ".png"), "rotated text")
        self.assertEqual(reader.readtext.call_args.args[0].shape, (2, 3, 3))

    def test_component_health_is_passive_and_preserves_runtime_failure(self):
        with patch.object(voice.importlib.util, "find_spec", return_value=object()), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(voice, "load_whisper") as load, \
                patch.object(voice, "ocr_cpu") as cpu, \
                patch.object(voice, "synthesize") as tts:
            self.assertTrue(all(row["state"] == "available" for row in voice.component_status().values()))
            voice.record_component("ocr_cpu", "unready", "fixture image loader failed")
            self.assertEqual(voice.component_status()["ocr_cpu"]["detail"], "fixture image loader failed")
            voice.record_component("ocr_cpu", "ready", "Last CPU image-text request succeeded")
            self.assertEqual(voice.component_status()["ocr_cpu"]["state"], "ready")
            load.assert_not_called()
            cpu.assert_not_called()
            tts.assert_not_called()
        with patch.object(voice.importlib.util, "find_spec", return_value=None), \
                patch.object(Path, "is_file", return_value=False):
            self.assertTrue(all(row["state"] == "unready" for row in voice.component_status().values()))

    def test_local_weight_directory_overrides_are_used_without_loading_models(self):
        import subprocess
        environment = dict(voice.os.environ, GODBRAIN_WHISPER_DIR=str(self.repo / "whisper"),
                           GODBRAIN_PIPER_VOICES_DIR=str(self.repo / "voices"))
        probe = subprocess.run(
            [sys.executable, "-B", "-c",
             "import json, voice_door as v; print(json.dumps([str(v.WHISPER), str(v.VOICES)]))"],
            cwd=Path(voice.__file__).parent, env=environment, capture_output=True, text=True,
            timeout=10, check=True,
        )
        self.assertEqual(json.loads(probe.stdout), [str(self.repo / "whisper"), str(self.repo / "voices")])

    def test_stt_assets_and_loader_require_local_tokenizer_without_model_initialization(self):
        weights = self.repo / "whisper"
        weights.mkdir()
        factory = Mock()
        with patch.object(voice, "WHISPER", weights), patch.object(voice, "_whisper", None), \
                patch.object(voice.importlib.util, "find_spec", return_value=object()), \
                patch.dict(sys.modules, {"faster_whisper": SimpleNamespace(WhisperModel=factory)}):
            for name in voice.WHISPER_FILES:
                (weights / name).write_bytes(b"fixture")
            self.assertEqual(voice.component_status()["stt"]["state"], "available")
            for name in voice.WHISPER_FILES:
                with self.subTest(missing=name):
                    (weights / name).unlink()
                    health = voice.component_status()["stt"]
                    self.assertEqual(health["state"], "unready")
                    self.assertIn(name, health["detail"])
                    with self.assertRaisesRegex(RuntimeError, name):
                        voice.load_whisper()
                    factory.assert_not_called()
                    (weights / name).write_bytes(b"fixture")
            self.assertIs(voice.load_whisper(), factory.return_value)
            self.assertIs(voice.load_whisper(), factory.return_value)
            factory.assert_called_once_with(str(weights), device="cpu", compute_type="int8",
                                            cpu_threads=8, local_files_only=True)

    def test_http_ocr_failure_is_visible_in_health_and_clears_after_success(self):
        self.write_settings(False)
        handler = type("FixtureVoiceHandler", (voice.VoiceHandler,), {"repo": self.repo})
        server = voice.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            with patch.object(voice, "note"), \
                    patch.object(voice.importlib.util, "find_spec", return_value=object()), \
                    patch.object(Path, "is_file", return_value=True), \
                    patch.object(voice, "ocr_cpu", side_effect=[RuntimeError("fixture loader failed"), "fixture text"]):
                request = urllib.request.Request(url + "/ocr", data=b"image", method="POST")
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(request, timeout=3)
                self.assertEqual(error.exception.code, 503)
                error.exception.close()
                with urllib.request.urlopen(url + "/health", timeout=3) as response:
                    component = json.loads(response.read())["components"]["ocr_cpu"]
                self.assertEqual(component, {
                    "state": "unready",
                    "detail": "CPU backend failed (RuntimeError); see the authenticated response for details.",
                })
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(json.loads(response.read())["text"], "fixture text")
                with urllib.request.urlopen(url + "/health", timeout=3) as response:
                    self.assertEqual(json.loads(response.read())["components"]["ocr_cpu"]["state"], "ready")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_public_health_hides_backend_details_for_all_remote_post_components(self):
        self.write_settings(False)

        class RemoteFixture(voice.VoiceHandler):
            expected_key = "fixture-key"

            def setup(self):
                super().setup()
                self.client_address = ("192.0.2.10", self.client_address[1])

        RemoteFixture.repo = self.repo
        server = voice.ThreadingHTTPServer(("127.0.0.1", 0), RemoteFixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_address[1]}"
        private_detail = r"fixture stderr at C:\private\synthetic-assets; private diagnostic content"
        try:
            with patch.object(voice, "note"), \
                    patch.object(voice.importlib.util, "find_spec", return_value=object()), \
                    patch.object(Path, "is_file", return_value=True):
                for path, component, backend, body, success in (
                    ("/v1/audio/transcriptions", "stt", "transcribe", b"RIFFfixture", "fixture"),
                    ("/v1/audio/speech", "tts", "synthesize", b'{"input":"fixture"}', b"RIFFfixture"),
                    ("/ocr", "ocr_cpu", "ocr_cpu", b"fixture", "fixture"),
                ):
                    with self.subTest(component=component), patch.object(
                        voice, backend, side_effect=[RuntimeError(private_detail), success]
                    ) as operation:
                        unauthenticated = urllib.request.Request(url + path, data=body, method="POST")
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen(unauthenticated, timeout=3)
                        self.assertEqual(error.exception.code, 401)
                        error.exception.close()
                        operation.assert_not_called()
                        request = urllib.request.Request(
                            url + path, data=body, headers={"X-API-Key": "fixture-key"}, method="POST")
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen(request, timeout=3)
                        self.assertEqual(error.exception.code, 503)
                        self.assertEqual(json.loads(error.exception.read())["error"], private_detail)
                        error.exception.close()
                        with urllib.request.urlopen(url + "/health", timeout=3) as response:
                            raw = response.read()
                        self.assertNotIn(private_detail.encode("utf-8"), raw)
                        self.assertNotIn(b"synthetic-assets", raw)
                        self.assertNotIn(b"private diagnostic content", raw)
                        self.assertEqual(json.loads(raw)["components"][component], {
                            "state": "unready",
                            "detail": "CPU backend failed (RuntimeError); see the authenticated response for details.",
                        })
                        with urllib.request.urlopen(request, timeout=3) as response:
                            response.read()
                        with urllib.request.urlopen(url + "/health", timeout=3) as response:
                            self.assertEqual(json.loads(response.read())["components"][component]["state"], "ready")
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
