#!/usr/bin/env bash
# Build libveil_translate.a for iOS (device, arm64).
#
#   native/translate/build_veil_translate_ios.sh [dest_dir]
#
# One archive, not four. On iOS the engine is linked INTO the app binary, so
# what ships is whatever the linker pulled in — and a set of archives is a set
# of chances for one to be forgotten. libtool folds CTranslate2, SentencePiece
# and this wrapper into a single file that either links or does not.
#
# Prereqs, both cross-built for iOS arm64:
#   CTranslate2:  CT2_SRC/build-ios-arm64/libctranslate2.a  (mobile/build-ios.sh)
#   SentencePiece: SPM_SRC/build-ios-arm64/src/libsentencepiece.a
#
# SentencePiece needs two things to configure for iOS at all, and neither is
# obvious:
#
#   * SPM_PROTOC_EXECUTABLE pointing at a protoc that runs on THIS machine.
#     Cross-compiling otherwise builds protoc for the target and then tries to
#     run it here, which fails as "Error 126" — an exec format error wearing a
#     make error's clothes.
#   * cmake/ios_shim.cmake, injected with CMAKE_PROJECT_INCLUDE_BEFORE.
#     SentencePiece calls set_xcode_property(), a macro from the community
#     ios-cmake toolchain it assumes everyone targeting iOS uses. With CMake's
#     own CMAKE_SYSTEM_NAME=iOS the call is undefined and configuration stops.
#     The shim defines it as a no-op; the Xcode target attributes it would set
#     have nothing to apply to when the archive is linked by hand.
set -euo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT2_SRC="${CT2_SRC:-$HOME/Projects/veilnetwork/CTranslate2}"
SPM_SRC="${SPM_SRC:-$HOME/Projects/veilnetwork/sentencepiece}"
CT2_BUILD="${CT2_BUILD:-$CT2_SRC/build-ios-arm64}"
SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-ios-arm64}"
TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"
DEST="${1:-$SRCDIR/Frameworks}"

[ -f "$CT2_BUILD/libctranslate2.a" ] || { echo "no $CT2_BUILD/libctranslate2.a — run mobile/build-ios.sh in $CT2_SRC" >&2; exit 1; }
[ -f "$SPM_BUILD/src/libsentencepiece.a" ] || { echo "no libsentencepiece.a in $SPM_BUILD — cross-build SentencePiece for iOS first" >&2; exit 1; }

ABSL_INC="$SPM_BUILD/_deps/abseil-cpp-src"
[ -d "$ABSL_INC" ] || { echo "no abseil sources at $ABSL_INC" >&2; exit 1; }

CT2_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$CT2_SRC/python/ctranslate2/version.py" | head -1)"
CT2_VERSION="${CT2_VERSION:-unknown}"
echo "==> ctranslate2 $CT2_VERSION"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANGXX="$(xcrun --sdk iphoneos --find clang++)"

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

"$CLANGXX" -target "arm64-apple-ios$TARGET" -isysroot "$SDK" \
  -std=c++17 -O2 -fPIC -c "$SRCDIR/veil_translate.cc" \
  -I"$SRCDIR" -I"$CT2_SRC/include" -I"$SPM_SRC/src" -I"$SPM_SRC" -I"$ABSL_INC" \
  -DVEIL_TRANSLATE_CT2_VERSION="\"$CT2_VERSION\"" \
  -o "$TMP/veil_translate.o"

# Every archive from both trees: a static CTranslate2 leaves ruy, cpuinfo and
# spdlog separate, and SentencePiece drags in abseil and protobuf.
LIBS=(
  "$TMP/veil_translate.o"
  $(find "$CT2_BUILD" -name '*.a')
  $(find "$SPM_BUILD" -name '*.a' ! -name '*train*' ! -name 'libprotoc*')
)
xcrun libtool -static -o "$DEST/libveil_translate.a" "${LIBS[@]}" 2>/dev/null

echo "==> $DEST/libveil_translate.a"
ls -la "$DEST/libveil_translate.a"

# Verify the artifact, not the exit status — a cross build is exactly where a
# green build means least, because this host cannot run what it just produced.
arch="$(lipo -info "$DEST/libveil_translate.a" 2>/dev/null | sed 's/.*: //')"
case "$arch" in
  *arm64*) ;;
  *) echo "::error::not arm64 — it is ${arch:-unreadable}" >&2; exit 1 ;;
esac

exported="$(nm "$DEST/libveil_translate.a" 2>/dev/null | grep -c 'T _veil_translate' || true)"
[ "$exported" -ge 5 ] || { echo "::error::only $exported veil_translate_* entry points in the archive" >&2; exit 1; }

# The platform, from a member's load commands. An archive built for macOS by
# accident is arm64 too, and links, and then fails on a device.
member="$(ar t "$DEST/libveil_translate.a" | grep '^veil_translate' | head -1)"
( cd "$TMP" && ar x "$DEST/libveil_translate.a" "$member" )
if otool -l "$TMP/$member" | grep -q 'platform 2'; then
  minos="$(otool -l "$TMP/$member" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
  echo "ios: arm64 archive, $exported entry points, deployment target $minos"
else
  echo "::error::$member was not built for iOS" >&2
  exit 1
fi
