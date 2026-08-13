#!/usr/bin/env bash
# Build libveil_translate.a for iOS (arm64), device or Simulator.
#
#   native/translate/build_veil_translate_ios.sh [--simulator] [dest_dir]
#
# One archive, not four. On iOS the engine is linked INTO the app binary, so
# what ships is whatever the linker pulled in — and a set of archives is a set
# of chances for one to be forgotten. libtool folds CTranslate2, SentencePiece
# and this wrapper into a single file that either links or does not.
#
# TWO archives, though, because there are two platforms. `--simulator` produces
# libveil_translate-sim.a beside the device one. An arm64 device slice and an
# arm64 Simulator slice are the same instruction set and different platforms in
# the Mach-O load commands (2 = iOS, 7 = iOS Simulator); the linker will not mix
# them, and `lipo` cannot fuse them because that would mean two arm64 members in
# one file. So they are separate builds from separate trees, each verified
# against the platform IT claims — a check that only asks "is this iOS" passes
# on the wrong one, and the wrong one fails at link with a message about
# building for iOS Simulator but linking an object built for iOS.
#
# Prereqs, cross-built for the matching platform. Both are built on demand when
# missing, which is how the Simulator gets built at all — nothing else in the
# tree knows the SentencePiece incantation:
#
#   device     CT2_SRC/build-ios-arm64/libctranslate2.a          (mobile/build-ios.sh)
#              SPM_SRC/build-ios-arm64/src/libsentencepiece.a
#   simulator  CT2_SRC/build-ios-sim-arm64/libctranslate2.a      (mobile/build-ios.sh --simulator)
#              SPM_SRC/build-ios-sim-arm64/src/libsentencepiece.a
#
# SentencePiece needs three things to configure for iOS at all, and none is
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
#   * For the Simulator, CMAKE_OSX_SYSROOT=iphonesimulator. With
#     CMAKE_SYSTEM_NAME=iOS already set, naming the SDK is what makes CMake emit
#     the `-simulator` triple suffix. Pointing only at the Simulator SDK's
#     headers gets a DEVICE build that compiles and archives and cannot be
#     linked into a Simulator app.
#
# The invocation lives here rather than in the SentencePiece checkout because
# that checkout is pristine upstream — the shim it needs is a file in THIS repo.
set -euo pipefail

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT2_SRC="${CT2_SRC:-$HOME/Projects/veilnetwork/CTranslate2}"
SPM_SRC="${SPM_SRC:-$HOME/Projects/veilnetwork/sentencepiece}"
TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"

SIM=0
if [ "${1:-}" = "--simulator" ]; then SIM=1; shift; fi

if [ "$SIM" = 1 ]; then
  SDKNAME=iphonesimulator
  TRIPLE="arm64-apple-ios$TARGET-simulator"
  CT2_BUILD="${CT2_BUILD:-$CT2_SRC/build-ios-sim-arm64}"
  SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-ios-sim-arm64}"
  ARCHIVE=libveil_translate-sim.a
  WANT_PLATFORM=7
  WANT_PLATFORM_NAME="iOS Simulator"
else
  SDKNAME=iphoneos
  TRIPLE="arm64-apple-ios$TARGET"
  CT2_BUILD="${CT2_BUILD:-$CT2_SRC/build-ios-arm64}"
  SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-ios-arm64}"
  ARCHIVE=libveil_translate.a
  WANT_PLATFORM=2
  WANT_PLATFORM_NAME="iOS device"
fi
DEST="${1:-$SRCDIR/Frameworks}"

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# --- prerequisites, built on demand -----------------------------------------

if [ ! -f "$CT2_BUILD/libctranslate2.a" ]; then
  [ -x "$CT2_SRC/mobile/build-ios.sh" ] \
    || { echo "no $CT2_BUILD/libctranslate2.a and no $CT2_SRC/mobile/build-ios.sh to make it" >&2; exit 1; }
  echo "==> building CTranslate2 for $WANT_PLATFORM_NAME"
  if [ "$SIM" = 1 ]; then
    IOS_DEPLOYMENT_TARGET="$TARGET" "$CT2_SRC/mobile/build-ios.sh" --simulator
  else
    IOS_DEPLOYMENT_TARGET="$TARGET" "$CT2_SRC/mobile/build-ios.sh"
  fi
fi
[ -f "$CT2_BUILD/libctranslate2.a" ] || { echo "still no $CT2_BUILD/libctranslate2.a" >&2; exit 1; }

if [ ! -f "$SPM_BUILD/src/libsentencepiece.a" ]; then
  # A protoc that runs HERE. Anything else and the build makes one for the
  # target, runs it, and reports "Error 126" from deep inside make.
  PROTOC="${SPM_PROTOC:-}"
  if [ -z "$PROTOC" ]; then
    for c in "$SPM_SRC"/build-macos-arm64/_deps/protobuf-build/protoc \
             "$SPM_SRC"/build-host/_deps/protobuf-build/protoc; do
      [ -x "$c" ] && { PROTOC="$c"; break; }
    done
  fi
  [ -n "$PROTOC" ] || PROTOC="$(command -v protoc || true)"
  [ -x "$PROTOC" ] || {
    echo "no host protoc for the SentencePiece cross build." >&2
    echo "  Build SentencePiece for this machine first (cmake -B $SPM_SRC/build-macos-arm64)," >&2
    echo "  or set SPM_PROTOC=/path/to/protoc. Without it the cross build compiles a" >&2
    echo "  protoc for the TARGET and tries to run it here, which surfaces as Error 126." >&2
    exit 1; }

  echo "==> building SentencePiece for $WANT_PLATFORM_NAME (protoc: $PROTOC)"
  cmake -S "$SPM_SRC" -B "$SPM_BUILD" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDKNAME" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_PROJECT_INCLUDE_BEFORE="$SRCDIR/cmake/ios_shim.cmake" \
    -DSPM_PROTOC_EXECUTABLE="$PROTOC" \
    -DSPM_ENABLE_SHARED=OFF -DSPM_BUILD_TEST=OFF \
    -DSPM_ENABLE_NFKC_COMPILE=OFF -DSPM_ENABLE_TCMALLOC=OFF \
    -DCMAKE_C_FLAGS="-ffile-prefix-map=$SPM_SRC=/sentencepiece" \
    -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SPM_SRC=/sentencepiece" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$SPM_BUILD" -j "$jobs"
fi
[ -f "$SPM_BUILD/src/libsentencepiece.a" ] || { echo "still no libsentencepiece.a in $SPM_BUILD" >&2; exit 1; }

ABSL_INC="$SPM_BUILD/_deps/abseil-cpp-src"
[ -d "$ABSL_INC" ] || { echo "no abseil sources at $ABSL_INC" >&2; exit 1; }

CT2_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$CT2_SRC/python/ctranslate2/version.py" | head -1)"
CT2_VERSION="${CT2_VERSION:-unknown}"
echo "==> ctranslate2 $CT2_VERSION, $WANT_PLATFORM_NAME ($TRIPLE)"

SDK="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
CLANGXX="$(xcrun --sdk "$SDKNAME" --find clang++)"

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Same maps as the android and macos scripts. iOS is the platform where this
# matters most and is hardest to see: the output is a static archive that gets
# -force_load'ed into Runner, so a path baked into an object here travels all
# the way into the app binary rather than being resolved away at link time.
#
# NOT MEASURED on iOS. The SentencePiece configure above carries the same flag
# and that one WAS measured, on macOS, where it took the bundled translate
# dylib from 51 hits to 0 — but nobody has rebuilt the iOS archives since, so
# the staged libveil_translate.a still measures 132. Rebuild it to find out.
PREFIX_MAPS=(
  "-ffile-prefix-map=$CT2_SRC=/ctranslate2"
  "-ffile-prefix-map=$SPM_SRC=/sentencepiece"
  "-ffile-prefix-map=$(cd "$SRCDIR/../.." && pwd)=/xveil"
  "-ffile-prefix-map=$HOME=/build"
)

"$CLANGXX" -target "$TRIPLE" -isysroot "$SDK" \
  -std=c++17 -O2 -fPIC -c "$SRCDIR/veil_translate.cc" \
  -I"$SRCDIR" -I"$CT2_SRC/include" -I"$SPM_SRC/src" -I"$SPM_SRC" -I"$ABSL_INC" \
  "${PREFIX_MAPS[@]}" \
  -DVEIL_TRANSLATE_CT2_VERSION="\"$CT2_VERSION\"" \
  -o "$TMP/veil_translate.o"

# Every archive from both trees: a static CTranslate2 leaves ruy, cpuinfo and
# spdlog separate, and SentencePiece drags in abseil and protobuf.
#
# `libprotobuf-lite.a` is EXCLUDED: it is a strict subset of libprotobuf.a and
# ships the same object files under the same names. Folding both put two
# `arena.cc.o` members into one archive, which nothing noticed until the archive
# was actually `-force_load`ed into Runner -- 838 duplicate symbols. Without
# force_load the linker picks one member and the problem never appears, which is
# why the archive passed every check it had: right architecture, right platform,
# right entry points, and unlinkable.
LIBS=(
  "$TMP/veil_translate.o"
  $(find "$CT2_BUILD" -name '*.a')
  $(find "$SPM_BUILD" -name '*.a' ! -name '*train*' ! -name 'libprotoc*' \
        ! -name 'libprotobuf-lite.a')
)
xcrun libtool -static -o "$DEST/$ARCHIVE" "${LIBS[@]}" 2>/dev/null

echo "==> $DEST/$ARCHIVE"
ls -la "$DEST/$ARCHIVE"

# Verify the artifact, not the exit status — a cross build is exactly where a
# green build means least, because this host cannot run what it just produced.
arch="$(lipo -info "$DEST/$ARCHIVE" 2>/dev/null | sed 's/.*: //')"
case "$arch" in
  *arm64*) ;;
  *) echo "::error::not arm64 — it is ${arch:-unreadable}" >&2; exit 1 ;;
esac

# Every entry point the Dart side looks up, by name, out of the header — a bare
# count passes when one name is missing and another is duplicated.
wanted="$(grep -oE 'veil_translate[a-z_]*\(' "$SRCDIR/veil_translate.h" | tr -d '(' | sort -u)"
[ -n "$wanted" ] || { echo "::error::no entry points declared in veil_translate.h" >&2; exit 1; }
found="$(nm "$DEST/$ARCHIVE" 2>/dev/null | sed -n 's/.* T _\(veil_translate[a-z_]*\)$/\1/p' | sort -u)"
missing="$(comm -23 <(echo "$wanted") <(echo "$found"))"
[ -z "$missing" ] || {
  echo "::error::the archive is missing entry points the Dart side looks up:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  exit 1; }
exported="$(echo "$found" | wc -l | tr -d ' ')"

# The platform, from a member's load commands. A device archive is arm64 too,
# and folds, and passes every check above, and then cannot be linked into a
# Simulator app — so the platform asserted is the one THIS invocation asked for,
# never merely "some flavour of iOS".
member="$(ar t "$DEST/$ARCHIVE" | grep '^veil_translate' | head -1)"
( cd "$TMP" && ar x "$DEST/$ARCHIVE" "$member" )
got_platform="$(otool -l "$TMP/$member" \
  | awk '/LC_BUILD_VERSION/{b=1;next} b&&/^ *platform /{print $2; exit}')"
if [ "$got_platform" != "$WANT_PLATFORM" ]; then
  case "${got_platform:-none}" in
    2) built="an iOS device" ;; 7) built="the iOS Simulator" ;;
    1) built="macOS" ;; none) built="no Apple platform at all" ;;
    *) built="platform $got_platform" ;;
  esac
  echo "::error::asked for $WANT_PLATFORM_NAME, $member was built for $built" >&2
  exit 1
fi
minos="$(otool -l "$TMP/$member" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"

# The arm64 Simulator did not exist before iOS 14 — there was no Apple Silicon
# Mac to run it on — so the toolchain RAISES anything lower and stamps 14.0.
# Verified rather than assumed: -target arm64-apple-ios13.0-simulator emits
# minos 14.0 while x86_64-apple-ios13.0-simulator emits 13.0. Expecting the
# number that was asked for would fail every correct arm64 Simulator build.
want_minos="$TARGET"
[ "$SIM" = 1 ] && want_minos="$(printf '%s\n14.0\n' "$TARGET" | sort -V | tail -1)"
[ "${minos%.0}" = "${want_minos%.0}" ] || {
  echo "::error::deployment target is $minos, expected $want_minos" >&2; exit 1; }

echo "ios: arm64 archive for $WANT_PLATFORM_NAME (platform $got_platform), $exported entry points, deployment target $minos"

# The link, emitted rather than committed.
#
# Nothing in the app's own Objective-C or Swift references these symbols --
# Dart looks them up at runtime out of the process image -- so a plain link
# drops every one of them and `DynamicLibrary.process()` finds nothing. It has
# to be `-force_load`.
#
# But translation is OPTIONAL, and a `-force_load` written into the Xcode
# project breaks the build outright for anyone who has not produced this
# archive. veilclient-ffi can be linked that way because it is mandatory; this
# cannot.
#
# So the flags live in an xcconfig that only exists once an archive does, and
# Runner's xcconfig pulls it in with `#include?` -- the optional form, which
# Xcode skips silently when the file is absent. Someone who never ran this
# script gets a working build with no Translate affordance, which is exactly
# what the Dart side already reports when the symbols are missing.
#
# The file is rewritten from WHAT IS ON DISK, not from which invocation just
# ran. Building only the Simulator archive must not silently un-link the device
# one, and re-running the device build must not drop the Simulator's entry.
XCCONFIG="$SRCDIR/../../ios/Flutter/TranslateLink.xcconfig"
if [ ! -d "$(dirname "$XCCONFIG")" ]; then
  echo "==> no ios/Flutter directory; skipping the link flags"
  exit 0
fi

have_device=0; [ -f "$DEST/libveil_translate.a" ] && have_device=1
have_sim=0;    [ -f "$DEST/libveil_translate-sim.a" ] && have_sim=1

if [ "$have_device" = 0 ] && [ "$have_sim" = 0 ]; then
  rm -f "$XCCONFIG"
  echo "==> no archives; removed $XCCONFIG"
  exit 0
fi

{
  cat <<'EOF'
// GENERATED by native/translate/build_veil_translate_ios.sh -- do not edit.
// Absent when no archive has been built; Runner includes it with `#include?`
// so that absence is a working build without translation.
//
// Accelerate is CTranslate2's GEMM backend on Apple platforms and
// CoreFoundation is abseil's time-zone lookup: both are referenced from
// inside the archive, so the final link needs them named here.
// -export_dynamic is not optional either, and it is the half that is easy to
// miss. In a DEBUG build Xcode splits the app into a launcher and
// Runner.debug.dylib, and a dylib exports its symbols by default -- so the
// entry points were there and `DynamicLibrary.process()` found them. A
// RELEASE build is one executable, an executable exports nothing by default,
// and STRIP_STYLE=all removes what is left. The engine code was inside the
// binary and unreachable: translation would have worked all through
// development and quietly disappeared in the build that ships.
//
// Device and Simulator need DIFFERENT archives -- same arm64, different
// platform in the Mach-O load commands -- so the archive is selected by SDK.
// Only the SDKs whose archive exists on disk get flags at all: the base
// VEIL_TRANSLATE_LDFLAGS is EMPTY, and an SDK that falls through to it links a
// working app with no translation. That is what makes a half-built tree
// harmless. Naming an archive that is not there would be worse than useless --
// `-force_load` with a missing path is a hard link error, so the one-sided
// case would break the build it was supposed to leave alone.
VEIL_TRANSLATE_COMMON_LDFLAGS = -lc++ -framework Accelerate -framework CoreFoundation -Wl,-export_dynamic

VEIL_TRANSLATE_LDFLAGS =
EOF
  if [ "$have_device" = 1 ]; then
    cat <<'EOF'

VEIL_TRANSLATE_ARCHIVE[sdk=iphoneos*] = $(SRCROOT)/../native/translate/Frameworks/libveil_translate.a
VEIL_TRANSLATE_LDFLAGS[sdk=iphoneos*] = -force_load $(VEIL_TRANSLATE_ARCHIVE) $(VEIL_TRANSLATE_COMMON_LDFLAGS)
EOF
  else
    echo
    echo "// No device archive: run native/translate/build_veil_translate_ios.sh"
  fi
  if [ "$have_sim" = 1 ]; then
    cat <<'EOF'

VEIL_TRANSLATE_ARCHIVE[sdk=iphonesimulator*] = $(SRCROOT)/../native/translate/Frameworks/libveil_translate-sim.a
VEIL_TRANSLATE_LDFLAGS[sdk=iphonesimulator*] = -force_load $(VEIL_TRANSLATE_ARCHIVE) $(VEIL_TRANSLATE_COMMON_LDFLAGS)
EOF
  else
    echo
    echo "// No Simulator archive: run native/translate/build_veil_translate_ios.sh --simulator"
  fi
  cat <<'EOF'

OTHER_LDFLAGS = $(inherited) $(VEIL_TRANSLATE_LDFLAGS)
EOF
} > "$XCCONFIG"

echo "==> $XCCONFIG (device: $have_device, simulator: $have_sim)"
