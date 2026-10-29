"""Exercise actual worker command dispatch with a tiny fake pipeline, without importing torch."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def test_late_cancel_does_not_stop_a_different_active_job():
    # Import in a child: worker intentionally redirects fd 1 for its JSON protocol.
    code = r'''import io, json, sys
from pathlib import Path
from worker import Worker
class Pipeline:
    stops = 0
    def stop(self): self.stops += 1
w = Worker(Path("."), "cpu", Path("."))
w.pipeline = Pipeline()
w.active_id = "second"
w.pending_ids = {"second", "queued"}
sys.stdin = io.StringIO("\n".join(json.dumps(c) for c in [
    {"type": "cancel", "id": "first"},
    {"type": "cancel", "id": "queued"},
    {"type": "cancel", "id": "second"}]) + "\n")
# Reader calls os._exit at EOF, so inspect state exactly at that boundary.
import os
def finish(code):
    assert w.pipeline.stops == 1, w.pipeline.stops
    assert w.cancelled == {"queued", "second"}, w.cancelled
    raise SystemExit(code)
os._exit = finish
w.reader()
'''
    result = subprocess.run([sys.executable, "-c", code], env=dict(os.environ, PYTHONPATH=str(ROOT / "engine")), capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr


def test_model_switches_clear_reference_and_symbol_caches_and_recover_from_bad_pairs():
    code = r'''from pathlib import Path
from types import SimpleNamespace
from worker import Worker
class Pipeline:
    def __init__(self):
        self.configs = SimpleNamespace(version="v2ProPlus")
        self.prompt_cache = {"phones": [999], "ref_audio_path": "same.wav", "raw_audio": "old", "refer_spec": ["old"]}
        self.calls = []
        self.fail_gpt = False
    def init_vits_weights(self, path):
        assert self.prompt_cache["ref_audio_path"] is None
        assert self.prompt_cache["phones"] is None
        assert self.prompt_cache["refer_spec"] == []
        assert "raw_audio" not in self.prompt_cache
        self.calls.append(("sovits", path))
        self.configs.version = "v1" if "v1" in path else "v2ProPlus"
    def init_t2s_weights(self, path):
        self.calls.append(("gpt", path))
        assert self.configs.version == ("v1" if "v1" in path else "v2ProPlus")
        if self.fail_gpt: raise RuntimeError("invalid GPT checkpoint")
w = Worker(Path("."), "cpu", Path("."))
w.pipeline = Pipeline()
w.TTS_Config = SimpleNamespace(default_configs={"v1": {"t2s_weights_path": "v1.ckpt", "vits_weights_path": "v1.pth"}, "v2ProPlus": {"t2s_weights_path": "pro.ckpt", "vits_weights_path": "pro.pth"}})
w.loaded_pair = ("pro.ckpt", "pro.pth")
w.select_weights({"modelVersion": "v1"})
assert w.loaded_pair == ("v1.ckpt", "v1.pth")
assert w.pipeline.calls == [("sovits", "v1.pth"), ("gpt", "v1.ckpt")]
w.select_weights({"modelVersion": "v1"})
assert len(w.pipeline.calls) == 2  # Repeated use does not reload.
w.pipeline.prompt_cache.update(phones=[1], ref_audio_path="same.wav", refer_spec=["v1"], raw_audio="v1")
w.select_weights({"modelVersion": "v2ProPlus"})
assert w.loaded_pair == ("pro.ckpt", "pro.pth")
try:
    w.select_weights({"modelVersion": "v1", "gptPath": "pro.ckpt", "sovitsPath": "pro.pth"})
    raise AssertionError("A mislabeled cached pair was accepted")
except ValueError: pass
w.pipeline.fail_gpt = True
try:
    w.select_weights({"modelVersion": "v1"})
    raise AssertionError("Bad checkpoint accepted")
except RuntimeError: pass
assert w.loaded_pair is None
w.pipeline.fail_gpt = False
w.select_weights({"modelVersion": "v2ProPlus"})
assert w.loaded_pair == ("pro.ckpt", "pro.pth")
try:
    w.select_weights({"modelVersion": "v1", "gptPath": "v1.ckpt", "sovitsPath": "pro.pth"})
    raise AssertionError("Mislabeled architecture accepted")
except ValueError: pass
assert w.loaded_pair is None
w.select_weights({"modelVersion": "v1"})
assert w.loaded_pair == ("v1.ckpt", "v1.pth")
'''
    result = subprocess.run([sys.executable, "-c", code], env=dict(os.environ, PYTHONPATH=str(ROOT / "engine")), capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
