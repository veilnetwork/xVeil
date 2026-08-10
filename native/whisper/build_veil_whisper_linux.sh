#!/usr/bin/env bash
# Build libveil_whisper.so for linux-x64: the veil_whisper wrapper statically
# linked against a CPU whisper.cpp. Runs ON an x86_64 Linux host (Flutter does
# not cross-compile Linux; use the same VM that runs `flutter build linux`).
# Drop the result into native/whisper/linux/ (gitignored artifact) — the app's
# linux/CMakeLists.txt bundles it (plus a ggml model placed next to it) into
# the Flutter bundle's lib/ dir, where the Dart side resolves both.
#
# Portability: whisper.cpp is configured with GGML_NATIVE=OFF (no
# -march=native) + an explicit AVX/AVX2/FMA/F16C baseline so the artifact runs
# on any 2013+ x86-64 CPU, and GGML_OPENMP=OFF so there is no libgomp runtime
# dependency (ggml falls back to its own thread pool).
#
# Prereq: a whisper.cpp checkout at WHISPER_SRC (this script configures+builds
# the static CPU libs itself when missing):
#   git clone https://github.com/ggml-org/whisper.cpp
#
# Usage: WHISPER_SRC=~/whisper.cpp ./build_veil_whisper_linux.sh [dest_dir]
set -euo pipefail

WHISPER_SRC="${WHISPER_SRC:-$HOME/whisper.cpp}"
BUILD="${WHISPER_BUILD_DIR:-$WHISPER_SRC/build-linux}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One pin for all four platforms; see the long note in the file.
# shellcheck source=native/whisper/whisper_pin.sh
. "$SRCDIR/whisper_pin.sh"
require_whisper_pin "$WHISPER_SRC"
DEST="${1:-$SRCDIR/linux}"
mkdir -p "$DEST"

[ -d "$WHISPER_SRC" ] || { echo "no whisper.cpp checkout at $WHISPER_SRC" >&2; exit 1; }

if [ ! -f "$BUILD/src/libwhisper.a" ]; then
  echo "==> building whisper.cpp static CPU libs ($BUILD)"
  cmake -S "$WHISPER_SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON \
    -DGGML_F16C=ON -DGGML_OPENMP=OFF
  cmake --build "$BUILD" -j"$(nproc)"
fi

# All the whisper.cpp static archives (whisper + ggml split libs). Group them
# so archive ordering never matters.
LIBS="$(find "$BUILD/src" "$BUILD/ggml" -name '*.a' 2>/dev/null | tr '\n' ' ')"
[ -n "$LIBS" ] || { echo "no static libs under $BUILD" >&2; exit 1; }
echo "==> linking with: $LIBS"

# ELF export control: only veil_whisper_* global (mirrors libveil_media.so).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/exports.map" <<'MAP'
{ global: veil_whisper_*; local: *; };
MAP

# shellcheck disable=SC2086
g++ -std=c++17 -O2 -fPIC -shared -o "$DEST/libveil_whisper.so" \
  "$SRCDIR/veil_whisper.cc" \
  -I"$WHISPER_SRC/include" -I"$WHISPER_SRC/ggml/include" \
  -Wl,--start-group $LIBS -Wl,--end-group \
  -Wl,--gc-sections -Wl,--version-script,"$TMP/exports.map" \
  -Wl,-soname,libveil_whisper.so \
  -lpthread -lm

strip --strip-unneeded "$DEST/libveil_whisper.so" 2>/dev/null || true
echo "==> done: $DEST/libveil_whisper.so ($(du -h "$DEST/libveil_whisper.so" | cut -f1))"
nm -D --defined-only "$DEST/libveil_whisper.so" | grep -c " T veil_whisper_" \
  | xargs echo "exported veil_whisper_* symbols:"
