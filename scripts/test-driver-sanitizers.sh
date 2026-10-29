#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sanitized
ditto build/LocalSpeakMic.driver build/sanitized/LocalSpeakMic.driver
xcrun clang -std=c11 -O1 -g -fblocks -fvisibility=hidden -fsanitize=address,undefined -fno-omit-frame-pointer \
  -mmacosx-version-min=14.0 -I driver -bundle -framework CoreAudio -framework CoreFoundation \
  driver/generated/LocalSpeakMic.c -Wl,-exported_symbol,_LocalSpeakMic_Create \
  -o build/sanitized/LocalSpeakMic.driver/Contents/MacOS/LocalSpeakMic
codesign --force --sign - build/sanitized/LocalSpeakMic.driver
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Wall -Wextra -Werror -I Sources/CMicTransport/include \
  Tests/Driver/driver_test.c Sources/CMicTransport/MicTransport.c \
  -framework CoreAudio -framework CoreFoundation -o build/sanitized/driver-test
build/sanitized/driver-test "$PWD/build/sanitized/LocalSpeakMic.driver" | tee build/sanitizer-report.txt
xcrun clang -std=c11 -O1 -g -fsanitize=thread -Wall -Wextra -Werror \
  -I Sources/CMicTransport/include Tests/Driver/transport_threads.c \
  Sources/CMicTransport/MicTransport.c -framework CoreAudio -o build/transport-threads
build/transport-threads | tee build/thread-sanitizer-report.txt
