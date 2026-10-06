import base64
import io
import json
import os
import random
import sys
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

from PIL import Image

import qwen_image_server as server
real_load_pipe = server.load_pipe
real_run_worker = server.run_worker


def export_phone_health(phase, health):
    destination = os.environ.get("GODBRAIN_PHONE_IMAGE_HEALTH_FIXTURE")
    if destination:
        path = Path(destination)
        samples = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        samples[phase] = health
        path.write_text(json.dumps(samples), encoding="utf-8")


def encoded_image(fmt="PNG", size=(32, 32)):
    data = io.BytesIO()
    Image.new("RGB", size, (20, 40, 60)).save(data, format=fmt)
    return base64.b64encode(data.getvalue()).decode("ascii")


class ImageServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.pipe = Mock(return_value=([Image.new("RGB", (256, 256))],))
        self.patches = [
            patch.object(server, "OUT", Path(self.temp.name)),
            patch.object(server, "PIPE", self.pipe),
            patch.object(server, "READY", True),
            patch.object(server, "JOBS", {}),
            patch.object(server, "load_pipe", return_value=self.pipe),
            patch.object(server, "run_worker", side_effect=lambda *args: server.generate_image(*args)),
            patch.object(server.torch, "Generator", return_value=Mock()),
            patch.object(server.Handler, "log_message", return_value=None),
        ]
        for item in self.patches:
            item.start()
        server.start_progress(0)
        with server.PROGRESS_LOCK:
            server.PROGRESS.update(phase="idle", started_at=None)
        self.http = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=3)
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def request(self, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.url + path, data=data, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as response:
            return response.code, json.load(response)

    def test_text_generation_keeps_existing_receipt(self):
        status, receipt = self.request("/v1/images/generations", {"prompt": "fixture"})
        self.assertEqual(status, 200)
        self.assertEqual(set(receipt), {"path", "width", "height", "steps", "seed"})
        self.assertTrue(Path(receipt["path"]).is_file())
        self.assertIsNone(self.pipe.call_args.kwargs["image"])
        self.assertEqual(self.pipe.call_args.kwargs["num_inference_steps"], 40)
        self.assertIs(self.pipe.call_args.kwargs["callback_on_step_end"], server.step_progress)
        self.assertEqual(self.pipe.call_args.kwargs["callback_on_step_end_tensor_inputs"], [])
        self.assertEqual(self.request("/health")[1]["progress"]["phase"], "done")

    def test_idle_health_reports_image_identity_without_loading_weights(self):
        status, health = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(health["model"], "Qwen-Image-2.1")
        self.assertIs(health["ready"], True)
        self.assertIs(health["busy"], False)
        self.assertIs(health["loaded"], False)
        server.load_pipe.assert_not_called()
        export_phone_health("idle", health)

    def test_image_edit_forwards_decoded_pixels_and_prompt(self):
        status, receipt = self.request(
            "/v1/images/generations",
            {"prompt": "Make this profile picture half cyborg", "image_base64": encoded_image(),
             "width": 256, "height": 256, "steps": 1},
        )
        self.assertEqual(status, 200)
        args = self.pipe.call_args.kwargs
        self.assertEqual(args["prompt"], "Make this profile picture half cyborg")
        self.assertEqual(args["image"].mode, "RGB")
        self.assertEqual(args["image"].getpixel((0, 0)), (20, 40, 60))
        self.assertTrue(Path(receipt["path"]).is_file())

    def test_invalid_image_inputs_fail_before_generation(self):
        values = [None, "", [], "not base64!", base64.b64encode(b"not an image").decode(),
                  encoded_image("GIF")]
        for value in values:
            with self.subTest(value=type(value).__name__):
                status, receipt = self.request(
                    "/generate", {"prompt": "fixture", "image_base64": value}
                )
                self.assertEqual(status, 400)
                self.assertIn("error", receipt)
        self.pipe.assert_not_called()

    def test_image_byte_and_pixel_limits(self):
        with patch.object(server, "MAX_IMAGE_BYTES", 1):
            status, _ = self.request(
                "/generate", {"prompt": "fixture", "image_base64": encoded_image()}
            )
            self.assertEqual(status, 400)
        with patch.object(server, "MAX_IMAGE_PIXELS", 100):
            status, _ = self.request(
                "/generate", {"prompt": "fixture", "image_base64": encoded_image()}
            )
            self.assertEqual(status, 400)
        self.pipe.assert_not_called()

    def test_image_is_bounded_to_max_side(self):
        with patch.object(server, "MAX_SIDE", 16):
            image = server.decode_input_image(encoded_image(size=(64, 32)))
        self.assertEqual(image.size, (16, 8))

    def test_health_remains_responsive_and_second_generate_is_rejected(self):
        entered = threading.Event()
        release = threading.Event()
        result = []

        def slow_generate(**kwargs):
            entered.set()
            if not release.wait(timeout=5):
                raise RuntimeError("fixture did not release generation")
            return ([Image.new("RGB", (256, 256))],)

        self.pipe.side_effect = slow_generate
        client = threading.Thread(
            target=lambda: result.append(self.request("/generate", {"prompt": "fixture"}))
        )
        client.start()
        try:
            self.assertTrue(entered.wait(timeout=3))
            status, health = self.request("/health")
            self.assertEqual(status, 200)
            self.assertTrue(health["busy"])
            self.assertEqual(health["model"], "Qwen-Image-2.1")
            self.assertIs(health["loaded"], True)
            export_phone_health("busy", health)
            self.assertEqual(health["progress"]["phase"], "preparing")
            self.assertEqual(health["progress"]["completed_steps"], 0)
            self.assertEqual(health["progress"]["total_steps"], 40)
            self.assertIsNone(health["progress"]["steps_per_second"])
            status, receipt = self.request("/generate", {"prompt": "second fixture"})
            self.assertEqual(status, 409)
            self.assertIn("already generating", receipt["error"])
            self.assertEqual(self.request("/health")[1]["progress"]["phase"], "preparing")
        finally:
            release.set()
            client.join(timeout=5)
        self.assertEqual(result[0][0], 200)
        self.assertFalse(self.request("/health")[1]["busy"])

    def test_progress_uses_step_intervals_and_freezes_elapsed_at_completion(self):
        pipe = SimpleNamespace(num_timesteps=3)
        callback_data = {}
        with patch.object(server.time, "monotonic", return_value=100.0) as clock:
            server.start_progress(3)
            clock.return_value = 110.0
            self.assertIs(server.step_progress(pipe, 0, 10, callback_data), callback_data)
            first = server.progress_snapshot()
            self.assertEqual(first["phase"], "denoising")
            self.assertEqual(first["completed_steps"], 1)
            self.assertEqual(first["total_steps"], 3)
            self.assertEqual(first["elapsed_seconds"], 10)
            self.assertIsNone(first["steps_per_second"])
            clock.return_value = 120.0
            server.step_progress(pipe, 1, 5, callback_data)
            second = server.progress_snapshot()
            self.assertAlmostEqual(second["steps_per_second"], 0.1)
            self.assertEqual(second["seconds_per_step"], 10)
            clock.return_value = 150.0
            server.step_progress(pipe, 2, 0, callback_data)
            final = server.progress_snapshot()
            self.assertEqual(final["phase"], "decoding")
            self.assertEqual(final["completed_steps"], 3)
            self.assertAlmostEqual(final["steps_per_second"], 0.05)
            self.assertEqual(final["seconds_per_step"], 20)
            clock.return_value = 160.0
            server.finish_progress("done")
            clock.return_value = 200.0
            self.assertEqual(server.progress_snapshot()["elapsed_seconds"], 60)
            server.start_progress(1)
            fresh = server.progress_snapshot()
            self.assertEqual(fresh["phase"], "preparing")
            self.assertEqual(fresh["completed_steps"], 0)
            self.assertEqual(fresh["elapsed_seconds"], 0)
            self.assertIsNone(fresh["steps_per_second"])
            self.assertIsNone(fresh["seconds_per_step"])

    def test_generation_error_is_visible_and_retry_resets_progress(self):
        def fail_generation(**kwargs):
            server.step_progress(SimpleNamespace(num_timesteps=40), 0, 10, {})
            raise RuntimeError("fixture generation failure")

        self.pipe.side_effect = fail_generation
        with patch.object(server.traceback, "print_exc"):
            status, receipt = self.request("/generate", {"prompt": "fixture"})
        self.assertEqual(status, 500)
        self.assertEqual(receipt["error"], "fixture generation failure")
        health = self.request("/health")[1]
        self.assertFalse(health["busy"])
        self.assertEqual(health["progress"]["phase"], "failed")
        self.assertEqual(health["progress"]["completed_steps"], 1)
        self.pipe.side_effect = None
        status, _ = self.request("/generate", {"prompt": "retry fixture", "steps": 1})
        self.assertEqual(status, 200)
        progress = self.request("/health")[1]["progress"]
        self.assertEqual(progress["phase"], "done")
        self.assertEqual(progress["completed_steps"], 0)
        self.assertEqual(progress["total_steps"], 1)

    def test_health_tracks_pipeline_callbacks_and_image_saving(self):
        observed = []
        normal_save = Image.Image.save

        def tracked_generate(**kwargs):
            pipe = SimpleNamespace(num_timesteps=2)
            callback = kwargs["callback_on_step_end"]
            for step in range(2):
                callback(pipe, step, 2 - step, {})
                observed.append(self.request("/health")[1])
            return ([Image.new("RGB", (256, 256))],)

        def tracked_save(image, *args, **kwargs):
            observed.append(self.request("/health")[1])
            return normal_save(image, *args, **kwargs)

        self.pipe.side_effect = tracked_generate
        self.assertEqual(self.request("/health")[1]["progress"]["phase"], "idle")
        with patch.object(Image.Image, "save", autospec=True, side_effect=tracked_save):
            status, _ = self.request("/generate", {"prompt": "fixture", "steps": 2})
        self.assertEqual(status, 200)
        self.assertEqual([health["progress"]["phase"] for health in observed],
                         ["denoising", "decoding", "saving"])
        self.assertTrue(all(health["busy"] for health in observed))
        done = self.request("/health")[1]
        self.assertFalse(done["busy"])
        self.assertEqual(done["progress"]["phase"], "done")
        self.assertEqual(done["progress"]["completed_steps"], 2)
        self.assertGreater(done["progress"]["steps_per_second"], 0)

    def test_body_cap_is_enforced(self):
        with patch.object(server, "MAX_BODY", 1):
            status, receipt = self.request("/generate", {"prompt": "fixture"})
        self.assertEqual(status, 400)
        self.assertIn("Request body", receipt["error"])
        self.pipe.assert_not_called()

    def test_load_uses_dtype_and_keeps_cpu_offload(self):
        module = ModuleType("diffusers.pipelines.qwenimage21.pipeline_qwenimage21")
        module.QwenImage21Pipeline = SimpleNamespace(from_pretrained=Mock(return_value=self.pipe))
        with patch.dict(sys.modules, {module.__name__: module}), patch.object(server, "PIPE", None):
            self.assertIs(real_load_pipe(), self.pipe)
            self.assertIs(real_load_pipe(), self.pipe)
        module.QwenImage21Pipeline.from_pretrained.assert_called_once_with(
            str(server.WEIGHTS), dtype=server.torch.bfloat16)
        self.pipe.enable_model_cpu_offload.assert_called_once_with()

    def fake_handler(self):
        handler = server.Handler.__new__(server.Handler)
        for name in ("send_response", "send_header", "end_headers", "log_message"):
            setattr(handler, name, Mock())
        handler.wfile = Mock()
        handler.close_connection = False
        return handler

    def test_disconnected_clients_are_logged_for_headers_and_body(self):
        for stage in ("end_headers", "write"):
            for error in (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
                with self.subTest(stage=stage, error=error):
                    handler = self.fake_handler()
                    target = handler.wfile.write if stage == "write" else handler.end_headers
                    target.side_effect = error("fixture disconnect")
                    self.assertFalse(handler._send(200, {"ok": True}))
                    self.assertTrue(handler.close_connection)
                    handler.log_message.assert_called_once_with(
                        "response %s not delivered: %s (client disconnected)", 200, error.__name__)
        handler = self.fake_handler()
        handler.wfile.write.side_effect = OSError("unexpected fixture write failure")
        with self.assertRaisesRegex(OSError, "unexpected"):
            handler._send(200, {"ok": True})

    def test_lost_receipt_connection_does_not_mark_saved_image_failed(self):
        handler = self.fake_handler()
        handler.path = "/generate"
        body = json.dumps({"prompt": "fixture"}).encode()
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler.wfile.write.side_effect = BrokenPipeError("fixture disconnect")
        handler.do_POST()
        handler.send_response.assert_called_once_with(200)
        self.assertEqual(server.progress_snapshot()["phase"], "done")
        self.assertFalse(server.GENERATE_LOCK.locked())
        self.assertEqual(len(list(server.OUT.glob("*.png"))), 1)

    def test_async_receipt_is_quick_correlated_and_does_not_queue(self):
        entered = threading.Event()
        release = threading.Event()
        request_id = "a" * 32

        def slow_generate(**kwargs):
            entered.set()
            if not release.wait(timeout=5):
                raise RuntimeError("fixture release missing")
            return ([Image.new("RGB", (256, 256))],)

        self.pipe.side_effect = slow_generate
        try:
            status, accepted = self.request("/generate", {
                "prompt": "fixture", "async": True, "request_id": request_id})
            self.assertEqual(status, 202)
            self.assertEqual(accepted["request_id"], request_id)
            self.assertTrue(entered.wait(timeout=3))
            job = self.request(f"/v1/images/jobs/{request_id}")[1]
            self.assertEqual(job["status"], "running")
            self.assertEqual(job["progress"]["request_id"], request_id)
            self.assertEqual(self.request("/generate", {"prompt": "other", "async": True})[0], 409)
        finally:
            release.set()
            for _ in range(100):
                if not server.GENERATE_LOCK.locked():
                    break
                threading.Event().wait(0.01)
        job = self.request(f"/v1/images/jobs/{request_id}")[1]
        self.assertEqual(job["status"], "done")
        self.assertTrue(Path(job["result"]["path"]).is_file())
        self.assertEqual(self.request("/generate", {
            "prompt": "duplicate", "request_id": request_id})[0], 409)
        self.pipe.assert_called_once()

    def test_jobs_are_bounded_and_invalid_requests_fail_explicitly(self):
        with patch.object(server, "MAX_JOBS", 2):
            for number in range(3):
                self.assertEqual(self.request("/generate", {
                    "prompt": "fixture", "request_id": f"{number:032x}"})[0], 200)
        self.assertEqual(len(server.JOBS), 2)
        self.assertEqual(self.request("/v1/images/jobs/" + "0" * 32)[0], 404)
        for payload in ({"async": "yes"}, {"request_id": None}, {"request_id": "z" * 32}):
            self.assertEqual(self.request("/generate", {"prompt": "fixture", **payload})[0], 400)

    def test_worker_failure_is_explicit_and_releases_gpu_slot(self):
        server.run_worker.side_effect = RuntimeError("fixture worker failure")
        with patch.object(server.traceback, "print_exc"):
            status, receipt = self.request("/generate", {"prompt": "fixture"})
        self.assertEqual(status, 500)
        self.assertEqual(receipt["error"], "fixture worker failure")
        self.assertFalse(server.GENERATE_LOCK.locked())

    def test_failed_job_assignment_kills_and_reaps_created_worker(self):
        process = Mock()
        process.poll.return_value = None
        with patch.object(server.subprocess, "Popen", return_value=process), \
             patch.object(server, "ChildJob", side_effect=OSError("fixture job setup failed")):
            with self.assertRaisesRegex(OSError, "job setup failed"):
                real_run_worker("a" * 32, "fixture", None, 256, 256, 1, 0)
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=15)

    def test_internal_2k_png_can_exceed_public_input_byte_limit(self):
        size = 2048
        image = Image.frombytes("RGB", (size, size), random.Random(0).randbytes(size * size * 3))
        data = io.BytesIO()
        image.save(data, format="PNG")
        self.assertGreater(len(data.getvalue()), server.MAX_IMAGE_BYTES)
        encoded = base64.b64encode(data.getvalue()).decode("ascii")
        with patch.object(server, "MAX_SIDE", size):
            with self.assertRaisesRegex(ValueError, "10 MiB"):
                server.decode_input_image(encoded)
            restored = server.decode_input_image(encoded, size * size * 4 + 1_048_576)
        self.assertEqual(restored.size, image.size)
        self.assertEqual(restored.tobytes(), image.tobytes())

    def test_atomic_progress_write_retries_sharing_conflicts_but_fails_loudly(self):
        path = Path(self.temp.name) / "progress.json"
        replace = Path.replace
        calls = []

        def shared_once(source, destination):
            calls.append(destination)
            if len(calls) == 1:
                raise PermissionError("fixture reader sharing conflict")
            return replace(source, destination)

        with patch.object(Path, "replace", shared_once), patch.object(server.time, "sleep"):
            server.write_json(path, {"phase": "denoising"})
        self.assertEqual(json.loads(path.read_text()), {"phase": "denoising"})
        self.assertEqual(len(calls), 2)
        with patch.object(Path, "replace", side_effect=PermissionError("fixture access denied")), \
             patch.object(server.time, "sleep"):
            with self.assertRaisesRegex(PermissionError, "access denied"):
                server.write_json(path, {"phase": "saving"})
        self.assertEqual(json.loads(path.read_text()), {"phase": "denoising"})

    @unittest.skipUnless(sys.platform == "win32", "Windows exact-child Job Object")
    def test_closing_job_kills_only_owned_worker(self):
        process = subprocess.Popen([sys._base_executable, "-c", "import time; time.sleep(30)"])
        unrelated = subprocess.Popen([sys._base_executable, "-c", "import time; time.sleep(30)"])
        job = None
        try:
            job = server.ChildJob(process)
            job.close()
            process.wait(timeout=5)
            self.assertIsNotNone(process.returncode)
            self.assertIsNone(unrelated.poll())
        finally:
            if unrelated.poll() is None:
                unrelated.kill()
                unrelated.wait(timeout=5)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if job is not None:
                job.close()


if __name__ == "__main__":
    unittest.main()
