#!/usr/bin/env python3
"""Package committed source, checksums, and build instructions. Never bundles local models or user data."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/release")
    args = parser.parse_args()
    # Ignored runtime/build files are expected; staged or unstaged source must be committed.
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT):
        raise SystemExit("Commit source changes before packaging so the release is reproducible.")
    subprocess.run(["python3", str(ROOT / "scripts/check-release.py")], cwd=ROOT, check=True)
    version = (ROOT / "VERSION").read_text().strip()
    prefix = f"local-tts-mic-{version}"
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f"{prefix}-source.tar.gz"
    subprocess.run(["git", "archive", "--format=tar.gz", f"--prefix={prefix}/", "-o", str(archive.resolve()), "HEAD"], cwd=ROOT, check=True)
    with tarfile.open(archive) as contents:
        names = contents.getnames()
        forbidden = ["runtime", "build", ".build", ".venv", ".env", "experimental"]
        if any(any(part in forbidden for part in Path(name).parts[1:]) or name.endswith((".ckpt", ".pth", ".onnx", ".partial")) for name in names):
            archive.unlink()
            raise SystemExit("Release includes private/generated files. Review tracked sources.")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
    print(archive)
    print("Source preview only. Build locally; an ad-hoc app is not a portable/notarized download.")


if __name__ == "__main__":
    main()
