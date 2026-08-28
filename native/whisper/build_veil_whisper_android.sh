#!/usr/bin/env bash
# Build libveil_whisper.so for ONE Android ABI: the veil_whisper wrapper linked
# against a prebuilt CPU whisper.cpp (built with the same NDK). Drop the result
# into that ABI's jniLibs (gitignored artifact).
#
# ANDROID_ABI picks it: arm64-v8a (default), armeabi-v7a, x86_64. It selects
# THREE things that have to move together — the clang target triple, the
# whisper.cpp build directory, and the jniLibs destination. Letting one be
# overridden without the others is how an arm64 library lands in the x86_64
# folder, where nothing notices until a device refuses to load it.
#
# Prereq: whisper.cpp built for THAT ABI at WHISPER_BUILD_DIR (default
# build-android-<abi>, with the plain `build-android` accepted for arm64 so an
# existing tree keeps working):
#   NDK=~/Library/Android/sdk/ndk/26.3.11579264
#   cmake -B build-android-arm64-v8a \
#     -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
#     -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
#   cmake --build build-android-arm64-v8a -j
#
# Usage: ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/26.3.11579264 \
#        WHISPER_SRC=~/Projects/veilnetwork/whisper.cpp \
#        [ANDROID_ABI=x86_64] ./build_veil_whisper_android.sh [dest_dir]
set -euo pipefail

# ABI -> (clang triple, jniLibs dir). android-26 for all three: the wrapper is
# built against the same platform level as whisper.cpp above.
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
case "$ANDROID_ABI" in
  arm64-v8a)   ABI_TRIPLE=aarch64-linux-android26 ;;
  armeabi-v7a) ABI_TRIPLE=armv7a-linux-androideabi26 ;;
  x86_64)      ABI_TRIPLE=x86_64-linux-android26 ;;
  *) echo "unknown ANDROID_ABI=$ANDROID_ABI (arm64-v8a|armeabi-v7a|x86_64)" >&2; exit 2 ;;
esac

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/26.3.11579264}"
WHISPER_SRC="${WHISPER_SRC:-$HOME/Projects/veilnetwork/whisper.cpp}"
# Per-ABI by default; the un-suffixed directory is still accepted for arm64 so
# a tree built before this took an ABI keeps working.
if [ -n "${WHISPER_BUILD_DIR:-}" ]; then
  BUILD="$WHISPER_BUILD_DIR"
elif [ -d "$WHISPER_SRC/build-android-$ANDROID_ABI" ]; then
  BUILD="$WHISPER_SRC/build-android-$ANDROID_ABI"
elif [ "$ANDROID_ABI" = arm64-v8a ]; then
  BUILD="$WHISPER_SRC/build-android"
else
  BUILD="$WHISPER_SRC/build-android-$ANDROID_ABI"
fi
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One pin for all four platforms; see the long note in the file.
# shellcheck source=native/whisper/whisper_pin.sh
. "$SRCDIR/whisper_pin.sh"
require_whisper_pin "$WHISPER_SRC"
DEST="${1:-$SRCDIR/../../android/app/src/main/jniLibs/$ANDROID_ABI}"
mkdir -p "$DEST"

TC="$NDK/toolchains/llvm/prebuilt"
HOST="$(ls "$TC" | head -1)"
CLANGXX="$TC/$HOST/bin/clang++"
[ -x "$CLANGXX" ] || { echo "no NDK clang++ at $CLANGXX" >&2; exit 1; }
[ -f "$BUILD/src/libwhisper.a" ] || { echo "no libwhisper.a in $BUILD — build whisper.cpp for $ANDROID_ABI first" >&2; exit 1; }

LIBS="$(find "$BUILD/src" "$BUILD/ggml" -name '*.a' 2>/dev/null | tr '\n' ' ')"
echo "==> $ANDROID_ABI ($ABI_TRIPLE), whisper from $BUILD"
echo "==> linking with: $LIBS"

"$CLANGXX" --target="$ABI_TRIPLE" -std=c++17 -O2 -fPIC -shared \
  -o "$DEST/libveil_whisper.so" \
  "$SRCDIR/veil_whisper.cc" \
  -I"$WHISPER_SRC/include" -I"$WHISPER_SRC/ggml/include" \
  $LIBS \
  -static-libstdc++ \
  -Wl,-soname,libveil_whisper.so -llog -lm

"$TC/$HOST/bin/llvm-strip" --strip-unneeded "$DEST/libveil_whisper.so" 2>/dev/null || true
echo "==> done: $DEST/libveil_whisper.so ($(du -h "$DEST/libveil_whisper.so" | cut -f1))"
"$TC/$HOST/bin/llvm-nm" -D --defined-only "$DEST/libveil_whisper.so" 2>/dev/null | grep -c " T veil_whisper_" | xargs echo "exported veil_whisper_* symbols:"

# Stage the exact model expected by the Android packaging task. It remains a
# gitignored build artifact; Gradle verifies the same digest again before it is
# admitted into an APK/AAB. CI may instead point XVEIL_WHISPER_MODEL_SRC at its
# artifact cache.
MODEL_SRC="${XVEIL_WHISPER_MODEL_SRC:-$WHISPER_SRC/models/ggml-base-q5_1.bin}"
MODEL_DEST="$SRCDIR/models/ggml-base-q5_1.bin"
MODEL_SHA256="422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
if [ -f "$MODEL_SRC" ]; then
  if command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256="$(shasum -a 256 "$MODEL_SRC" | awk '{print $1}')"
  else
    ACTUAL_SHA256="$(sha256sum "$MODEL_SRC" | awk '{print $1}')"
  fi
  [ "$ACTUAL_SHA256" = "$MODEL_SHA256" ] || {
    echo "unexpected whisper model SHA-256: $ACTUAL_SHA256" >&2
    exit 1
  }
  mkdir -p "$(dirname "$MODEL_DEST")"
  cp "$MODEL_SRC" "$MODEL_DEST"
  echo "==> staged verified Android whisper model: $MODEL_DEST"
else
  echo "warning: no whisper model at $MODEL_SRC; release packaging will fail" >&2
fi
