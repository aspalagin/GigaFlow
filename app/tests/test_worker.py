import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import uuid

import numpy as np

spec = importlib.util.spec_from_file_location("worker", Path(__file__).parents[1] / "worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class ChunkTests(unittest.TestCase):
    def test_long_audio_covered_once_and_split_inside_pause(self):
        audio = np.ones(51 * 16000, dtype=np.float32) * 0.2
        audio[18 * 16000:19 * 16000] = 0
        ranges = worker.chunk_ranges(audio, np)
        self.assertEqual(ranges[0][0], 0)
        self.assertEqual(ranges[-1][1], len(audio))
        self.assertTrue(18 * 16000 <= ranges[0][1] <= 19 * 16000)
        self.assertTrue(all(0 < end - start <= 20 * 16000 for start, end in ranges))
        self.assertTrue(all(a[1] == b[0] for a, b in zip(ranges, ranges[1:])))
        self.assertEqual(sum(end - start for start, end in ranges), len(audio))

    def test_silence_gate_is_conservative(self):
        self.assertFalse(worker.has_signal(np.zeros(16000, dtype=np.float32), np))
        self.assertFalse(worker.has_signal(np.ones(16000, dtype=np.float32) * 1e-5, np))
        signal = np.sin(np.arange(16000) * 0.1).astype(np.float32) * .01
        self.assertTrue(worker.has_signal(signal, np))


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # Match main(): macOS TemporaryDirectory may use /var while resolve()
        # canonicalizes files to /private/var. The worker's allowlist is canonical.
        self.root = Path(self.tmp.name).resolve()
        self.audio_dir = self.root / "recordings"
        self.audio_dir.mkdir()
        self.path = self.audio_dir / "sample.caf"
        self.path.write_bytes(b"test")
        self.request_id = str(uuid.uuid4())
        self.request = {"type": "transcribe", "id": self.request_id, "path": str(self.path)}

    def tearDown(self):
        self.tmp.cleanup()

    def test_path_escape_and_symlink_escape_rejected(self):
        outside = self.root / "outside.wav"
        outside.write_bytes(b"test")
        link = self.audio_dir / "linked.wav"
        link.symlink_to(outside)
        for path in (outside, link, self.audio_dir / ".." / "outside.wav"):
            with self.assertRaises(worker.RequestError):
                worker.validate_request(dict(self.request, path=str(path)), self.audio_dir)

    def test_invalid_uuid_and_relative_path_rejected(self):
        for field, value in (("id", "not-a-uuid"), ("path", "sample.caf")):
            with self.assertRaises(worker.RequestError):
                worker.validate_request(dict(self.request, **{field: value}), self.audio_dir)

    def test_bad_requests_and_inference_error_do_not_end_stream(self):
        class FakeRecognizer:
            count = 0
            def transcribe(self, _):
                self.count += 1
                if self.count == 1:
                    raise RuntimeError("secret transcript must not be logged")
                return "Привет!", 1.2

        payload = "not json\n" + "x" * (worker.MAX_REQUEST_BYTES + 1) + "\n"
        payload += json.dumps(self.request) + "\n" + json.dumps(self.request) + "\n"
        output, logs = io.StringIO(), io.StringIO()
        import contextlib
        with contextlib.redirect_stderr(logs):
            worker.serve(io.StringIO(payload), output, self.audio_dir, FakeRecognizer())
        results = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r["type"] for r in results], ["error", "error", "error", "result"])
        self.assertEqual(results[-1]["id"], self.request_id)
        self.assertEqual(results[-1]["text"], "Привет!")
        self.assertNotIn("secret", logs.getvalue())

    def test_overlong_audio_rejected_before_loading_samples(self):
        class Header:
            samplerate = 16000
            channels = 1
            def __len__(self):
                return int((worker.MAX_DURATION + 1) * self.samplerate)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self, **kwargs):
                raise AssertionError("Must reject oversized header before allocating audio")

        from types import SimpleNamespace
        recognizer = worker.Recognizer.__new__(worker.Recognizer)
        recognizer.sf = SimpleNamespace(SoundFile=lambda raw: Header())
        with self.assertRaisesRegex(worker.RequestError, "120"):
            recognizer.transcribe(self.path)


if __name__ == "__main__":
    unittest.main()
