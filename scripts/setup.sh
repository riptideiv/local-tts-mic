#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'Local TTS Mic currently supports Apple Silicon Macs only.' >&2; exit 1
fi
case "${1:-}" in
    ''|--include-jsut) ;;
    *) echo 'Usage: ./scripts/setup.sh [--include-jsut]' >&2; exit 2 ;;
esac
xcode-select -p >/dev/null 2>&1 || { echo 'Install Command Line Tools: xcode-select --install'; exit 1; }
# Prevent CLI and in-app repair from modifying the same environment concurrently.
mkdir -p runtime
if ! mkdir runtime/.setup-lock 2>/dev/null; then
    echo 'Setup is already running. If it was interrupted, remove runtime/.setup-lock and retry.' >&2; exit 1
fi
trap 'rmdir "$ROOT/runtime/.setup-lock"' EXIT
UPSTREAM=b4570b876f5c086819ba84e3215472733c6a7b70
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v uv >/dev/null || { echo 'Install uv first: brew install uv'; exit 1; }
command -v ffmpeg >/dev/null || { echo 'Install ffmpeg first: brew install ffmpeg'; exit 1; }
mkdir -p runtime
if [ ! -d runtime/GPT-SoVITS/.git ]; then
    git init runtime/GPT-SoVITS
    git -C runtime/GPT-SoVITS remote add origin https://github.com/RVC-Boss/GPT-SoVITS.git
fi
git -C runtime/GPT-SoVITS fetch origin "$UPSTREAM" --depth 1
git -C runtime/GPT-SoVITS checkout --detach "$UPSTREAM"
uv venv --python 3.11 --allow-existing runtime/.venv
uv pip sync --python runtime/.venv/bin/python requirements.lock
if [ "${1:-}" = --include-jsut ]; then
    runtime/.venv/bin/python scripts/download_assets.py --include-jsut
else
    runtime/.venv/bin/python scripts/download_assets.py
fi
echo "Setup complete. Run ./scripts/build.sh, then open 'build/Local TTS Mic.app'."

