#!/usr/bin/env python3
"""Actual worker cancellation, invalid-input recovery, and imported checkpoint tests."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "runtime/validation-lifecycle"
out.mkdir(parents=True, exist_ok=True)
voice = json.loads((ROOT / "runtime/starter-voices.json").read_text())[0]
log = (out / "engine.log").open("w")
env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
p = subprocess.Popen([str(ROOT / "runtime/.venv/bin/python"), "-u", str(ROOT / "engine/worker.py"), "--output", str(out)],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1, env=env)
selector = selectors.DefaultSelector(); selector.register(p.stdout, selectors.EVENT_READ)


def receive():
    if not selector.select(timeout=180):
        raise TimeoutError("Worker stalled")
    line = p.stdout.readline()
    if not line: raise RuntimeError("Worker exited")
    value = json.loads(line)
    print(json.dumps(value, ensure_ascii=False), flush=True)
    assert value["type"] != "fatal", value
    return value


def send(command):
    p.stdin.write(json.dumps(command, ensure_ascii=False) + "\n"); p.stdin.flush()


def job(text, selected=None, language="en"):
    return dict(type="synthesize", id=str(uuid.uuid4()), text=text, language=language, speed=1.0, voice=selected or voice)


def terminal():
    while True:
        value = receive()
        if value["type"] in {"error", "complete", "cancelled"}: return value


try:
    while receive()["type"] != "ready": pass
    bad = job(" "); send(bad)
    assert terminal()["type"] == "error"
    long = job("Hello! " + "This message should stop before the next sentence is spoken. " * 12)
    send(long)
    while receive()["type"] != "audio": pass
    send(dict(type="cancel", id=long["id"]))
    assert terminal()["type"] == "cancelled"
    imported = dict(voice,
        gptPath=str(ROOT / "runtime/GPT-SoVITS/GPT_SoVITS/pretrained_models/s1v3.ckpt"),
        sovitsPath=str(ROOT / "runtime/GPT-SoVITS/GPT_SoVITS/pretrained_models/v2Pro/s2Gv2ProPlus.pth"))
    send(job("The worker recovered after cancellation.", imported))
    assert terminal()["type"] == "complete"
    send(job("Hello. こんにちは。你好。", language="auto"))
    assert terminal()["type"] == "complete"
    (out / "report.json").write_text(json.dumps(dict(invalidInputRecovery=True, cancellation=True, checkpointImport=True, mixedLanguages=True), indent=2))
finally:
    p.terminate()
    try: p.wait(timeout=10)
    except subprocess.TimeoutExpired: p.kill()
    log.close()
