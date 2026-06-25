#!/usr/bin/env bash
# Bundle the native dylibs into the built macOS .app.
#
# WHY: on macOS the app resolves libhidden_volume_ffi / libveilclient_ffi via
# native_libs.dart's candidate list. A `flutter run` from the repo root resolves
# the relative dev path (third_party/.../target/<profile>), but a Finder-launched
# .app has cwd=/ so that path fails — and the app then SILENTLY falls back to the
# in-memory fake store (every password opens the same space, no encryption, no
# deniability). Copying the dylibs into Contents/Frameworks makes the
# "$exeDir/../Frameworks/<lib>" candidate resolve, so a normally-launched .app
# uses the real deniable storage + embedded node.
#
# Run AFTER `flutter build macos [--debug|--release]`.
#   scripts/bundle-macos-dylibs.sh [debug|release]
set -euo pipefail

PROFILE="${1:-debug}"
case "$PROFILE" in
  debug) APP_SUBDIR="Debug" ;;
  release) APP_SUBDIR="Release" ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/macos/Build/Products/$APP_SUBDIR/xveil.app"
[ -d "$APP" ] || { echo "no .app at $APP — build first" >&2; exit 1; }

HV="$ROOT/third_party/hidden-volume/target/$PROFILE/libhidden_volume_ffi.dylib"
VC="$ROOT/third_party/veil/target/$PROFILE/libveilclient_ffi.dylib"
for f in "$HV" "$VC"; do
  [ -f "$f" ] || { echo "missing dylib: $f — build the native lib first" >&2; exit 1; }
done

# The veil dylib MUST carry the embedded-node FFI (built --features node-embedded),
# else the app degrades to a non-deniable boot. Fail loudly if it doesn't.
if ! nm -gU "$VC" 2>/dev/null | grep -q 'veil_config_init'; then
  echo "ERROR: $VC lacks veil_config_init — not built with --features node-embedded" >&2
  exit 1
fi

mkdir -p "$APP/Contents/Frameworks"
cp -f "$HV" "$VC" "$APP/Contents/Frameworks/"
echo "bundled into $APP/Contents/Frameworks:"
ls -la "$APP/Contents/Frameworks/" | grep -E 'hidden_volume|veilclient'

# Swapping a dylib invalidates the .app's code-signature seal (its CodeResources
# still references the OLD dylib hash), so a strict launch — `flutter run`, or
# Gatekeeper — SIGKILLs the process on dlopen with EXC_BAD_ACCESS / "Code
# Signature Invalid". Re-sign the whole bundle ad-hoc so the seal matches the
# freshly-copied dylibs. Without this the app crashes the moment it loads the
# native store.
echo "re-signing $APP (ad-hoc, deep) after the dylib swap…"
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP" \
  && echo "codesign OK — bundle seal matches the new dylibs" \
  || { echo "ERROR: codesign verify failed after re-sign" >&2; exit 1; }
