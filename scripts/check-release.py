#!/usr/bin/env python3
"""Check tracked source hygiene and relative documentation links before packaging."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]


def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    failures = []
    forbidden = {"runtime", "build", ".build", ".venv", "experimental", "__pycache__", "generated"}
    for name in filter(None, paths):
        path = Path(name)
        if forbidden.intersection(path.parts) or path.name == ".env" or path.name.startswith(".env.") or path.suffix in {".ckpt", ".pth", ".onnx", ".partial", ".pkg", ".dmg"}:
            failures.append(f"Private/generated source path: {name}")
        if path.suffix in {".wav", ".flac", ".mp3"} and name != "docs/assets/hello.wav":
            failures.append(f"Unreviewed audio asset: {name}")
        if path.suffix == ".md":
            source = ROOT / path
            if not source.exists():
                failures.append(f"Missing tracked file: {name}")
                continue
            links = re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", source.read_text())
            links += re.findall(r'<img[^>]+src="([^"]+)"', source.read_text())
            for link in links:
                if "://" in link or link.startswith("#") or link.startswith("mailto:"):
                    continue
                target = unquote(link.split("#", 1)[0]).strip("<>")
                if target and not (source.parent / target).exists():
                    failures.append(f"Broken relative link: {name} -> {target}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("PASS tracked source hygiene and relative documentation links")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
