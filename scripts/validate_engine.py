#!/usr/bin/env python3
"""Exercise the actual JSON protocol and actual models; save measurements and WAVs."""
from pathlib import Path
import argparse
import json
import os
import selectors
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
args = parser.parse_args()
output = ROOT / "runtime" / ("validation-" + args.device)
output.mkdir(parents=True, exist_ok=True)
profiles = json.loads((ROOT / "runtime/starter-voices.json").read_text())
texts = {"en": "Hello! My voice is running locally on this Mac.", "zh": "你好，这是在这台电脑上生成的语音。", "ja": "こんにちは。この音声はパソコンで生成しています。"}
env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", PYTORCH_ENABLE_MPS_FALLBACK="1")
log = (output / "engine.log").open("w")
p = subprocess.Popen([str(ROOT / "runtime/.venv/bin/python"), "-u", str(ROOT / "engine/worker.py"), "--root", str(ROOT), "--device", args.device, "--output", str(output)],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, env=env, text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(p.stdout, selectors.EVENT_READ)
started = time.monotonic()
results = []


def event(timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if selector.select(timeout=1):
            line = p.stdout.readline()
            if not line:
                raise RuntimeError(f"Worker exited: {p.poll()}. See {output / 'engine.log'}")
            value = json.loads(line)
            print(json.dumps(value, ensure_ascii=False), flush=True)
            if value["type"] in {"error", "fatal"}:
                raise RuntimeError(value.get("message"))
            return value
        if p.poll() is not None:
            raise RuntimeError(f"Worker exited: {p.returncode}. See {output / 'engine.log'}")
    raise TimeoutError("Worker timed out")


try:
    while event()["type"] != "ready":
        pass
    load_seconds = time.monotonic() - started
    # Repeat English at the end to separate first-run warmup from steady state.
    for voice in profiles + profiles[:1]:
        job = dict(type="synthesize", id=str(uuid.uuid4()), text=texts[voice["language"]], language=voice["language"], speed=1, voice=voice)
        p.stdin.write(json.dumps(job, ensure_ascii=False) + "\n"); p.stdin.flush()
        while True:
            value = event()
            if value["type"] == "complete":
                import soundfile as sf
                import numpy as np
                audio, sr = sf.read(value["path"])
                assert np.isfinite(audio).all() and np.max(np.abs(audio)) > 0.01
                assert len(audio) / sr > 0.5
                results.append(dict(language=voice["language"], **value, rms=float(np.sqrt(np.mean(audio**2)))))
                break
    report = dict(device=args.device, loadSeconds=load_seconds, results=results)
    (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
finally:
    p.terminate()
    try: p.wait(timeout=10)
    except subprocess.TimeoutExpired: p.kill()
    log.close()
