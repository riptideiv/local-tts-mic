#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build .build/clang-cache
if [ ! -f build/AppIcon.icns ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
    swift -module-cache-path "$PWD/.build/clang-cache" scripts/make_icon.swift "$PWD/build/AppIcon.iconset"
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
