#!/usr/bin/env python3
"""Read-only setup diagnostics. No network requests and no imports of speech models."""
import argparse
import json
import platform
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check_environment(root=ROOT):
    runtime = root / "runtime"
    checks = []

    def add(name, ok, fix, required=True):
        checks.append(dict(name=name, ok=bool(ok), required=required, fix="" if ok else fix))

    add("Apple Silicon macOS", platform.system() == "Darwin" and platform.machine() == "arm64", "Use an Apple Silicon Mac; other platforms are not currently supported.")
    for tool in ["git", "swift", "uv", "ffmpeg"]:
        add(tool, shutil.which(tool), "Install Command Line Tools (xcode-select --install) and brew install uv ffmpeg.")
    add("Free disk space (10 GB for setup)", shutil.disk_usage(root).free >= 10 * 1024**3, "Free at least 10 GB for dependencies, downloads, and temporary files.", required=False)
    python = runtime / ".venv/bin/python"
    add("Python runtime", python.is_file(), "Run ./scripts/setup.sh.")
    add("GPT-SoVITS source", (runtime / "GPT-SoVITS/GPT_SoVITS/TTS_infer_pack/TTS.py").is_file(), "Run ./scripts/setup.sh.")
    for model in ["s1v3.ckpt", "v2Pro/s2Gv2ProPlus.pth", "chinese-hubert-base/pytorch_model.bin", "chinese-roberta-wwm-ext-large/pytorch_model.bin"]:
        path = runtime / "GPT-SoVITS/GPT_SoVITS/pretrained_models" / model
        add(model, path.is_file() and path.stat().st_size > 0, "Run ./scripts/setup.sh to download missing weights.")
    try:
        voices = json.loads((runtime / "starter-voices.json").read_text())
        valid = bool(voices) and all(Path(v["referencePath"]).is_file() for v in voices)
    except (OSError, ValueError, TypeError, KeyError):
        valid = False
    add("Reference voices", valid, "Run ./scripts/setup.sh; rebuild if you moved the project folder.")
    add("Microphone driver (optional for preview)", Path("/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver").is_dir(), "Finish calls, then run ./scripts/install-driver.sh. Preview works without it.", required=False)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Machine-readable report; does not include personal file paths")
    args = parser.parse_args()
    checks = check_environment()
    if args.json:
        print(json.dumps(dict(checks=checks), indent=2))
    else:
        for item in checks:
            state = "OK" if item["ok"] else "MISSING" if item["required"] else "OPTIONAL"
            print(f"{state:8} {item['name']}")
            if item["fix"]:
                print(f"         {item['fix']}")
    return 0 if all(c["ok"] for c in checks if c["required"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
