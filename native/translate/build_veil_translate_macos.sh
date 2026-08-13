#!/usr/bin/env bash
# Build libveil_translate.dylib for macOS arm64 and prove it translates.
#
#   native/translate/build_veil_translate_macos.sh [dest_dir]
#
# One file, not three. CTranslate2 and SentencePiece are folded in statically
# because a translation feature that ships as an engine plus a tokeniser plus
# their transitive halves is three chances to arrive incomplete — and this
# repository has already lost days to exactly that with the call engine.
#
# Prereqs, both built where this script expects them — and both with the
# prefix-map flags, which are part of the recipe and not a nicety:
#   CTranslate2 (static):  CT2_SRC/build-macos-static/libctranslate2.a
#     mobile/build-ios.sh's flags with BUILD_SHARED_LIBS=OFF, on the host
#   SentencePiece (static): SPM_SRC/build-macos-arm64/src/libsentencepiece.a
#     cmake -DSPM_ENABLE_SHARED=OFF -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_TCMALLOC=OFF \
#           -DCMAKE_C_FLAGS="-ffile-prefix-map=$SPM_SRC=/sentencepiece" \
#           -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SPM_SRC=/sentencepiece"
#
# Without them the .app named a third checkout 51 times: darts_clone throws
# with __FILE__ and a line number baked into the message, so every one of those
# exception strings inside libsentencepiece.a carries the absolute path of
# whoever built it. They are .rodata in a static archive, so no flag on the
# link below can take them out — this script links those archives, it does not
# compile them. Measured on the bundled dylib: 51 -> 0.
#
# SentencePiece pulls in abseil AND protobuf through FetchContent, so the link
# takes every static library under its build tree. That is not tidy, but it is
# honest: those objects are what the tokeniser needs, and discovering them by
# glob beats a hand-written list that goes stale the next time upstream adds
# one.
set -euo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT2_SRC="${CT2_SRC:-$HOME/Projects/veilnetwork/CTranslate2}"
SPM_SRC="${SPM_SRC:-$HOME/Projects/veilnetwork/sentencepiece}"
CT2_BUILD="${CT2_BUILD:-$CT2_SRC/build-macos-static}"
SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-macos-arm64}"
DEST="${1:-$SRCDIR/Frameworks}"

CT2_LIB="$CT2_BUILD/libctranslate2.a"
SPM_LIB="$SPM_BUILD/src/libsentencepiece.a"
[ -f "$CT2_LIB" ] || { echo "no $CT2_LIB — build CTranslate2 static first" >&2; exit 1; }
[ -f "$SPM_LIB" ] || { echo "no $SPM_LIB — build SentencePiece static first" >&2; exit 1; }

ABSL_INC="$SPM_BUILD/_deps/abseil-cpp-src"
[ -d "$ABSL_INC" ] || { echo "no abseil sources at $ABSL_INC — SentencePiece fetches them at configure time" >&2; exit 1; }

# The version string is not available from any CTranslate2 header, so it is
# read from the source of truth upstream keeps it in.
CT2_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$CT2_SRC/python/ctranslate2/version.py" | head -1)"
CT2_VERSION="${CT2_VERSION:-unknown}"
echo "==> ctranslate2 $CT2_VERSION"

# Everything SentencePiece's build produced, minus the trainer (we never train)
# and protoc (a compiler, not a runtime).
SPM_LIBS="$(find "$SPM_BUILD" -name '*.a' ! -name '*train*' ! -name 'libprotoc*' | tr '\n' ' ')"
[ -n "$SPM_LIBS" ] || { echo "no static libraries under $SPM_BUILD" >&2; exit 1; }

# Ruy, cpuinfo and friends are separate archives in a static CTranslate2 build.
# A shared build hides this: the .dylib has already absorbed them, so linking
# libctranslate2.a alone fails on ruy::Allocator with no hint that the fix is
# "collect the rest of the tree".
CT2_DEP_LIBS="$(find "$CT2_BUILD" -name '*.a' ! -name 'libctranslate2.a' | tr '\n' ' ')"

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# What this compile CAN keep out of the artifact: its own paths. Mirrors the
# android script; the archives are the other half, and they are the recipe
# above rather than anything reachable from here.
PREFIX_MAPS=(
  "-ffile-prefix-map=$CT2_SRC=/ctranslate2"
  "-ffile-prefix-map=$SPM_SRC=/sentencepiece"
  "-ffile-prefix-map=$(cd "$SRCDIR/../.." && pwd)=/xveil"
  "-ffile-prefix-map=$HOME=/build"
)

clang++ -std=c++17 -O2 -fPIC -c "$SRCDIR/veil_translate.cc" \
  -I"$SRCDIR" -I"$CT2_SRC/include" -I"$SPM_SRC/src" -I"$SPM_SRC" -I"$ABSL_INC" \
  "${PREFIX_MAPS[@]}" \
  -DVEIL_TRANSLATE_CT2_VERSION="\"$CT2_VERSION\"" \
  -o "$TMP/veil_translate.o"

# -framework CoreFoundation: abseil's time-zone lookup calls CFTimeZone on
# Apple platforms, and without it the link fails on six CF symbols that have
# nothing to do with translation.
clang++ -std=c++17 -dynamiclib -o "$DEST/libveil_translate.dylib" \
  "$TMP/veil_translate.o" \
  -Wl,-force_load,"$CT2_LIB" $CT2_DEP_LIBS $SPM_LIBS \
  -framework Accelerate -framework CoreFoundation \
  -install_name @rpath/libveil_translate.dylib

# Build the selftest against the finished library — the same way the app will
# use it, through dlopen'able exports rather than the objects.
clang "$SRCDIR/selftest.c" -I"$SRCDIR" -L"$DEST" -lveil_translate \
  -Wl,-rpath,"$DEST" -o "$TMP/selftest"

echo "==> $DEST/libveil_translate.dylib"
ls -la "$DEST/libveil_translate.dylib"
nm -gU "$DEST/libveil_translate.dylib" | grep -c ' T _veil_translate' \
  | xargs -I{} echo "exports {} veil_translate_* entry points"

MODEL="${VEIL_TRANSLATE_TEST_MODEL:-$HOME/Projects/veilnetwork/ct2-model}"
if [ -d "$MODEL" ]; then
  echo "==> selftest against $MODEL"
  "$TMP/selftest" "$MODEL"
else
  echo "==> selftest NOT RUN: no model at $MODEL"
  echo "    set VEIL_TRANSLATE_TEST_MODEL to a CTranslate2 model directory"
  echo "    containing source.spm and target.spm. The library is built but"
  echo "    nothing has checked that it translates."
fi
