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
