#!/bin/bash
# Offline native + small Python tests; never downloads speech models or installs a driver.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -n "${LOCALSPEAK_TEST_PYTHON:-}" ]; then
    TEST_PYTHON="$LOCALSPEAK_TEST_PYTHON"
elif [ -x .venv/bin/python ]; then
    TEST_PYTHON="$PWD/.venv/bin/python"
elif [ -x runtime/.venv/bin/python ]; then
    TEST_PYTHON="$PWD/runtime/.venv/bin/python"
else
    echo 'Run uv venv --python 3.11 && uv pip install pytest, or set LOCALSPEAK_TEST_PYTHON.' >&2; exit 1
fi
"$TEST_PYTHON" -m pytest Tests -q
swift test --disable-sandbox --jobs 2
./scripts/build-driver.sh
./scripts/test-driver-sanitizers.sh
