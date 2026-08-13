#!/usr/bin/env bash
# Build libveil_whisper.dylib for macOS (arm64): the thin veil_whisper wrapper
# statically linked against a prebuilt whisper.cpp (CPU). Bundle it into the app
# like the other dylibs (scripts/bundle-macos-dylibs.sh) — Dart resolves the
# veil_whisper_* symbols via the loaded image.
#
# Prereq: whisper.cpp checked out + built static (CPU) at WHISPER_SRC:
#   cmake -B build-mac -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF \
#         -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
#         -DCMAKE_C_FLAGS="-ffile-prefix-map=$WHISPER_SRC=/whisper.cpp" \
#         -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$WHISPER_SRC=/whisper.cpp"
#   cmake --build build-mac -j
#
# The two prefix-map flags are not optional and cannot be added here. GGML_ASSERT
# expands __FILE__, so every ggml source path is a .rodata string inside
# libggml-*.a — fifteen of them reached the shipped .app naming the checkout,
# and therefore the account. This script links those archives; it does not
# compile them, so CXXFLAGS reaching this clang++ cannot remove what is already
# baked in. Whoever builds whisper.cpp owns that, which is why the recipe is
# here rather than a flag below. Measured: 15 -> 0 with the flags, on the dylib
# that goes into the bundle.
#
# Usage: WHISPER_SRC=~/Projects/veilnetwork/whisper.cpp ./build_veil_whisper_macos.sh [dest_dir]
set -euo pipefail

WHISPER_SRC="${WHISPER_SRC:-$HOME/Projects/veilnetwork/whisper.cpp}"
BUILD="${WHISPER_BUILD_DIR:-$WHISPER_SRC/build-mac}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One pin for all four platforms; see the long note in the file.
# shellcheck source=native/whisper/whisper_pin.sh
. "$SRCDIR/whisper_pin.sh"
require_whisper_pin "$WHISPER_SRC"
DEST="${1:-$SRCDIR/Frameworks}"
mkdir -p "$DEST"

[ -f "$BUILD/src/libwhisper.a" ] || { echo "no libwhisper.a in $BUILD — build whisper.cpp first" >&2; exit 1; }

# All the whisper.cpp static archives (whisper + ggml split libs).
LIBS="$(find "$BUILD/src" "$BUILD/ggml" -name '*.a' 2>/dev/null | tr '\n' ' ')"
echo "==> linking with: $LIBS"

clang++ -std=c++17 -O2 -dynamiclib -o "$DEST/libveil_whisper.dylib" \
  "$SRCDIR/veil_whisper.cc" \
  -I"$WHISPER_SRC/include" -I"$WHISPER_SRC/ggml/include" \
  $LIBS \
  -install_name @rpath/libveil_whisper.dylib \
  -framework Accelerate -framework Foundation -framework Metal \
  -framework MetalKit -framework CoreFoundation

echo "==> done: $DEST/libveil_whisper.dylib ($(du -h "$DEST/libveil_whisper.dylib" | cut -f1))"
nm -gU "$DEST/libveil_whisper.dylib" | grep -c "T _veil_whisper_" | xargs echo "exported veil_whisper_* symbols:"
