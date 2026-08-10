#!/usr/bin/env bash
# Build libveil_translate.so for android-arm64 and prove it translates ON THE
# DEVICE, not merely that it linked.
#
#   native/translate/build_veil_translate_android.sh [dest_dir]
#
# Prereqs, both cross-built for the same ABI:
#   CTranslate2 (static):  CT2_SRC/dist/android-arm64-v8a-static/*.a
#     CT2_BUILD_SHARED=OFF mobile/build-android.sh
#   SentencePiece (static): SPM_SRC/build-android-arm64/src/libsentencepiece.a
#     cmake with the NDK toolchain AND -DSPM_PROTOC_EXECUTABLE=<host protoc>
#
# That last flag is not optional and not obvious. SentencePiece generates C++
# from .proto at build time; cross-compiling builds protoc for the TARGET and
# then tries to run it on the host, which fails as "Error 126" — an exec format
# error dressed up as a make failure. SPM_PROTOC_EXECUTABLE points at a protoc
# that can actually run here; the one from the host build of SentencePiece
# does.
#
# The result needs libomp.so beside it, because CTranslate2 for Android is
# built against the NDK's OpenMP. It is copied here for the same reason the
# engine build copies it: a missing libomp is a load failure whose message
# says nothing about translation.
set -euo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/26.3.11579264}"
API="${ANDROID_API:-24}"
CT2_SRC="${CT2_SRC:-$HOME/Projects/veilnetwork/CTranslate2}"
SPM_SRC="${SPM_SRC:-$HOME/Projects/veilnetwork/sentencepiece}"
CT2_DIST="${CT2_DIST:-$CT2_SRC/dist/android-arm64-v8a-static}"
SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-android-arm64}"
DEST="${1:-$SRCDIR/jniLibs/arm64-v8a}"

TC="$NDK/toolchains/llvm/prebuilt"
HOST="$(ls "$TC" 2>/dev/null | head -1)"
CLANGXX="$TC/$HOST/bin/clang++"
[ -x "$CLANGXX" ] || { echo "no NDK clang++ at $CLANGXX" >&2; exit 1; }
[ -f "$CT2_DIST/libctranslate2.a" ] || { echo "no $CT2_DIST/libctranslate2.a — run CT2_BUILD_SHARED=OFF mobile/build-android.sh in $CT2_SRC" >&2; exit 1; }
[ -f "$SPM_BUILD/src/libsentencepiece.a" ] || { echo "no libsentencepiece.a in $SPM_BUILD — cross-build SentencePiece first" >&2; exit 1; }

ABSL_INC="$SPM_BUILD/_deps/abseil-cpp-src"
[ -d "$ABSL_INC" ] || { echo "no abseil sources at $ABSL_INC" >&2; exit 1; }

CT2_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$CT2_SRC/python/ctranslate2/version.py" | head -1)"
CT2_VERSION="${CT2_VERSION:-unknown}"

# Every archive from both trees. CTranslate2's static build leaves ruy,
# cpuinfo and spdlog separate; SentencePiece drags in abseil and protobuf.
CT2_LIBS="$(find "$CT2_DIST" -name '*.a' | tr '\n' ' ')"
SPM_LIBS="$(find "$SPM_BUILD" -name '*.a' ! -name '*train*' ! -name 'libprotoc*' | tr '\n' ' ')"

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

"$CLANGXX" --target="aarch64-linux-android$API" -std=c++17 -O2 -fPIC -c \
  "$SRCDIR/veil_translate.cc" \
  -I"$SRCDIR" -I"$CT2_SRC/include" -I"$SPM_SRC/src" -I"$SPM_SRC" -I"$ABSL_INC" \
  -DVEIL_TRANSLATE_CT2_VERSION="\"$CT2_VERSION\"" \
  -o "$TMP/veil_translate.o"

OMP="$(find "$NDK/toolchains/llvm/prebuilt"/*/lib/clang/*/lib/linux/aarch64 -name 'libomp.so' 2>/dev/null | head -1)"
[ -n "$OMP" ] || { echo "no libomp.so under $NDK" >&2; exit 1; }
cp "$OMP" "$DEST/"

# -Wl,--whole-archive around the engine: the C ABI below references only a
# fraction of it directly, and the linker would drop the rest — including the
# int8 kernels reached through Ruy's dispatch tables rather than by name.
"$CLANGXX" --target="aarch64-linux-android$API" -std=c++17 -shared -fPIC \
  -o "$DEST/libveil_translate.so" \
  "$TMP/veil_translate.o" \
  -Wl,--whole-archive "$CT2_DIST/libctranslate2.a" -Wl,--no-whole-archive \
  $CT2_LIBS $SPM_LIBS \
  -L"$DEST" -lomp -static-libstdc++ \
  -Wl,-soname,libveil_translate.so -llog -lm

# Strip. The NDK keeps debug information in a Release build, which here is the
# difference between 62 MB and something an APK can carry — and an APK is
# exactly where this is going. --strip-unneeded, not --strip-all: the dynamic
# symbol table is the ABI, and the export check below would be the thing that
# noticed if this ever removed it.
STRIP="$TC/$HOST/bin/llvm-strip"
if [ -x "$STRIP" ]; then
  before="$(wc -c < "$DEST/libveil_translate.so" | tr -d ' ')"
  "$STRIP" --strip-unneeded "$DEST/libveil_translate.so"
  after="$(wc -c < "$DEST/libveil_translate.so" | tr -d ' ')"
  echo "==> stripped: $((before / 1048576)) MB -> $((after / 1048576)) MB"
else
  echo "==> NOT STRIPPED: no llvm-strip at $STRIP — the library carries its debug info"
fi

echo "==> $DEST"
ls -la "$DEST"

NM="$TC/$HOST/bin/llvm-nm"
exported="$("$NM" -D --defined-only "$DEST/libveil_translate.so" 2>/dev/null | grep -c 'T veil_translate' || true)"
[ "$exported" -ge 5 ] || { echo "::error::only $exported veil_translate_* entry points exported" >&2; exit 1; }
echo "exports $exported veil_translate_* entry points"

# The selftest is an Android binary; running it needs a device. Built either
# way, because a build that produces an unrunnable test still tells us the ABI
# links.
"$CLANGXX" --target="aarch64-linux-android$API" "$SRCDIR/selftest.c" \
  -I"$SRCDIR" -L"$DEST" -lveil_translate -o "$DEST/selftest"

MODEL="${VEIL_TRANSLATE_TEST_MODEL:-}"
if [ -z "$MODEL" ] || ! command -v adb >/dev/null || [ -z "$(adb devices | sed -n '2p')" ]; then
  echo "==> selftest NOT RUN: needs a connected device and VEIL_TRANSLATE_TEST_MODEL"
  echo "    the library is built and its exports checked, but nothing has"
  echo "    confirmed it translates on an actual phone."
  exit 0
fi

echo "==> selftest on device"
remote=/data/local/tmp/veil-translate
adb shell "rm -rf $remote && mkdir -p $remote/model" >/dev/null
adb push "$DEST/libveil_translate.so" "$DEST/libomp.so" "$DEST/selftest" "$remote/" >/dev/null
for f in "$MODEL"/*; do adb push "$f" "$remote/model/" >/dev/null; done
adb shell "cd $remote && chmod 755 selftest && LD_LIBRARY_PATH=$remote ./selftest model; echo DEVICE_RC=\$?" \
  | tee "$TMP/device.log"
grep -q 'DEVICE_RC=0' "$TMP/device.log" || { echo "::error::the selftest failed on the device" >&2; exit 1; }
