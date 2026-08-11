#!/usr/bin/env bash
# Does the built iOS app actually offer the translation entry points?
#
#   scripts/check-ios-translate-link.sh [--simulator | path/to/Runner.app]
#
# Not "was the archive built" and not "did the build succeed" — both were true
# while the shipped binary offered nothing. The Dart side resolves these out of
# the PROCESS IMAGE, so the only question that matters is whether the finished
# app exports them, and the only way to answer it is to look inside the app.
#
# Two ways it went wrong here, neither visible from the build's exit code:
#
#   * The archive folded libprotobuf.a AND libprotobuf-lite.a, which carry the
#     same object files. Nothing noticed until `-force_load` pulled in every
#     member: 838 duplicate symbols. Without force_load the linker picks one
#     and the archive looks fine.
#   * DEBUG splits the app into a launcher and Runner.debug.dylib, and a dylib
#     exports by default — so debug worked. RELEASE is one executable, which
#     exports nothing by default, and STRIP_STYLE=all removes the rest. The
#     engine was inside the binary and unreachable. Translation would have
#     worked all through development and vanished in the build that ships.
#
# So this checks the EXPORT TRIE, which is what dlsym reads, and it checks both
# places the code can live.
#
# Device and Simulator are separate products in separate directories, and the
# device one is NOT removed when you build for the Simulator. Defaulting to the
# device path would then pass on yesterday's device app while the Simulator
# build being tested exports nothing — so the bundle actually inspected is
# resolved out loud, and the platform it was built for is reported with the
# result rather than assumed from the path it sat in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEVICE_APP="build/ios/iphoneos/Runner.app"
SIM_APP="build/ios/iphonesimulator/Runner.app"

case "${1:-}" in
  --simulator) app="$SIM_APP" ;;
  --device)    app="$DEVICE_APP" ;;
  "")
    if [ -d "$DEVICE_APP" ]; then app="$DEVICE_APP"
    elif [ -d "$SIM_APP" ]; then app="$SIM_APP"
    else app="$DEVICE_APP"; fi
    echo "no bundle given; inspecting $app"
    ;;
  *) app="$1" ;;
esac
[ -d "$app" ] || { echo "no app bundle at $app — build one first" >&2; exit 1; }

name="$(basename "$app" .app)"
main="$app/$name"
[ -f "$main" ] || { echo "::error::$app has no $name executable" >&2; exit 2; }

# Which platform this bundle is actually for, read from the binary. `platform 2`
# is a device, `platform 7` the Simulator; they are both arm64 here, so the file
# name and the directory prove nothing.
platform="$(otool -l "$main" 2>/dev/null \
  | awk '/LC_BUILD_VERSION/{b=1;next} b&&/^ *platform /{print $2; exit}')"
case "${platform:-none}" in
  2) built_for="iOS device" ;;
  7) built_for="iOS Simulator" ;;
  *) built_for="platform ${platform:-unknown}" ;;
esac

# The debug split: the real code is in the sibling dylib, and that is a normal
# arrangement rather than a failure — so both are asked, and finding the
# symbols in either is an answer.
candidates=("$main")
[ -f "$app/$name.debug.dylib" ] && candidates+=("$app/$name.debug.dylib")

# Resolved from the script's own location: the list of entry points must not
# depend on which directory this was invoked from, or an empty `wanted` turns
# the whole check into a no-op that exits 2 for the wrong reason.
wanted="$(grep -oE 'veil_translate[a-z_]*\(' "$ROOT/native/translate/veil_translate.h" \
  | tr -d '(' | sort -u)"
[ -n "$wanted" ] || { echo "::error::no entry points found in veil_translate.h" >&2; exit 2; }

# WHICH SLICE. A Simulator build is fat — x86_64 and arm64 — and the translate
# archive is arm64 only, so the x86_64 slice legitimately carries nothing. Asked
# without `-arch`, dyld_info prints every slice's exports one after another, and
# a grep over that output says "found" when ANY slice has them. That is a green
# check for an app that cannot translate: this Mac's Simulator runs the arm64
# slice, and it would be the one that came up empty. So the slice is named.
#
# arm64 is the required one on both products — the device is arm64, and so is
# the Simulator on Apple Silicon. A binary without an arm64 slice at all is
# answered on the slice it does have, said out loud rather than assumed.
REQUIRED_ARCH=arm64
slices="$(lipo -archs "$main" 2>/dev/null || echo "")"
case " $slices " in
  *" $REQUIRED_ARCH "*) ;;
  *) if [ -n "$slices" ]; then
       REQUIRED_ARCH="${slices%% *}"
       echo "note: no arm64 slice; checking $REQUIRED_ARCH instead"
     fi ;;
esac

exports_of() {
  # dyld_info reads the export trie — the same table dlsym consults. `nm` reads
  # the static symbol table, which a release build strips entirely: it would
  # report "missing" for a binary that works, and that is a false alarm nobody
  # would trust twice.
  dyld_info -arch "$REQUIRED_ARCH" -exports "$1" 2>/dev/null \
    | awk '{print $NF}' | sed 's/^_//' | { grep '^veil_translate' || true; } | sort -u
}

found=""
for binary in "${candidates[@]}"; do
  exported="$(exports_of "$binary")"
  if [ -n "$exported" ]; then found="$exported"; break; fi
done

if [ -z "$found" ]; then
  echo "::error::$app ($built_for, $REQUIRED_ARCH) exports no veil_translate_* entry point."
  echo "  The archive can be present, linked and inside the binary and still be"
  echo "  unreachable: an executable exports nothing by default. Check that"
  echo "  ios/Flutter/TranslateLink.xcconfig exists and carries both -force_load"
  echo "  and -Wl,-export_dynamic."
  if [ "${platform:-}" = 7 ]; then
    echo "  This is a SIMULATOR build: it needs libveil_translate-sim.a, which the"
    echo "  device archive cannot stand in for. Run"
    echo "  native/translate/build_veil_translate_ios.sh --simulator."
  fi
  exit 1
fi

missing="$(comm -23 <(echo "$wanted") <(echo "$found"))"
if [ -n "$missing" ]; then
  echo "::error::the app ($built_for, $REQUIRED_ARCH) is missing entry points the Dart side looks up:"
  echo "$missing" | sed 's/^/  /'
  exit 1
fi
echo "ok: $app ($built_for, $REQUIRED_ARCH) exports $(echo "$found" | wc -l | tr -d ' ') veil_translate_* entry points"

# The other slices, reported rather than enforced. There is no x86_64 translate
# archive, so a fat Simulator build carries translation in arm64 only — correct
# on this hardware and a real gap on an Intel Mac. Saying so beats a bare "ok"
# that hides it.
for a in $slices; do
  [ "$a" = "$REQUIRED_ARCH" ] && continue
  n=0
  for binary in "${candidates[@]}"; do
    c="$(dyld_info -arch "$a" -exports "$binary" 2>/dev/null \
      | awk '{print $NF}' | sed 's/^_//' | { grep -c '^veil_translate' || true; })"
    [ "$c" -gt "$n" ] && n="$c"
  done
  [ "$n" -eq 0 ] && echo "note: the $a slice has no translation (no $a archive is built)"
done
