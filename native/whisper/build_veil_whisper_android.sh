#!/usr/bin/env bash
# Build libveil_whisper.so for android-arm64: the veil_whisper wrapper linked
# against a prebuilt CPU whisper.cpp (built with the same NDK). Drop the result
# into the app's jniLibs (gitignored artifact).
#
# Prereq: whisper.cpp built for android at WHISPER_BUILD_DIR:
#   NDK=~/Library/Android/sdk/ndk/26.3.11579264
#   cmake -B build-android -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
#     -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
#   cmake --build build-android -j
#
# Usage: ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/26.3.11579264 \
#        WHISPER_SRC=~/Projects/veilnetwork/whisper.cpp ./build_veil_whisper_android.sh [dest_dir]
set -euo pipefail

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/26.3.11579264}"
WHISPER_SRC="${WHISPER_SRC:-$HOME/Projects/veilnetwork/whisper.cpp}"
BUILD="${WHISPER_BUILD_DIR:-$WHISPER_SRC/build-android}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$SRCDIR/jniLibs/arm64-v8a}"
mkdir -p "$DEST"

TC="$NDK/toolchains/llvm/prebuilt"
HOST="$(ls "$TC" | head -1)"
CLANGXX="$TC/$HOST/bin/clang++"
[ -x "$CLANGXX" ] || { echo "no NDK clang++ at $CLANGXX" >&2; exit 1; }
[ -f "$BUILD/src/libwhisper.a" ] || { echo "no libwhisper.a in $BUILD — build whisper.cpp for android first" >&2; exit 1; }

LIBS="$(find "$BUILD/src" "$BUILD/ggml" -name '*.a' 2>/dev/null | tr '\n' ' ')"
echo "==> linking with: $LIBS"

"$CLANGXX" --target=aarch64-linux-android26 -std=c++17 -O2 -fPIC -shared \
  -o "$DEST/libveil_whisper.so" \
  "$SRCDIR/veil_whisper.cc" \
  -I"$WHISPER_SRC/include" -I"$WHISPER_SRC/ggml/include" \
  $LIBS \
  -static-libstdc++ \
  -Wl,-soname,libveil_whisper.so -llog -lm

"$TC/$HOST/bin/llvm-strip" --strip-unneeded "$DEST/libveil_whisper.so" 2>/dev/null || true
echo "==> done: $DEST/libveil_whisper.so ($(du -h "$DEST/libveil_whisper.so" | cut -f1))"
"$TC/$HOST/bin/llvm-nm" -D --defined-only "$DEST/libveil_whisper.so" 2>/dev/null | grep -c " T veil_whisper_" | xargs echo "exported veil_whisper_* symbols:"
