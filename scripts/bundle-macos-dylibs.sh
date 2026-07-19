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
  debug) APP_SUBDIR="Debug"; ENTITLEMENTS="DebugProfile.entitlements" ;;
  release) APP_SUBDIR="Release"; ENTITLEMENTS="Release.entitlements" ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/macos/Build/Products/$APP_SUBDIR/xveil.app"
ENT="$ROOT/macos/Runner/$ENTITLEMENTS"
[ -d "$APP" ] || { echo "no .app at $APP — build first" >&2; exit 1; }

HV="$ROOT/third_party/hidden-volume/target/$PROFILE/libhidden_volume_ffi.dylib"
VC="$ROOT/third_party/veil/target/$PROFILE/libveilclient_ffi.dylib"
for f in "$HV" "$VC"; do
  [ -f "$f" ] || { echo "missing dylib: $f — build the native lib first" >&2; exit 1; }
done

# A Flutter/Xcode rebuild does not rebuild the runtime-loaded Rust dylibs. Do
# not silently package yesterday's FFI after a Rust fix: that exact mismatch
# left the pre-IPC-keepalive veilclient in an otherwise fresh debug app, so the
# desktop node died after 15 minutes of silence and every call offer failed
# with `connection closed`. Cargo's own dependency graph decides what to
# rebuild; this is only an early, actionable packaging guard.
newer_veil_source="$(find "$ROOT/third_party/veil/crates" \
  "$ROOT/third_party/veil/veilclient" \
  "$ROOT/third_party/veil/veilcore" \
  -type f \( -name '*.rs' -o -name 'Cargo.toml' \) \
  -newer "$VC" -print -quit)"
if [ -z "$newer_veil_source" ]; then
  newer_veil_source="$(find "$ROOT/third_party/veil" -maxdepth 1 -type f \
    \( -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
    -newer "$VC" -print -quit)"
fi
if [ -n "$newer_veil_source" ]; then
  echo "ERROR: $VC is older than Rust source $newer_veil_source" >&2
  echo "run: cargo build -p veilclient-ffi --features node-embedded" >&2
  exit 1
fi

# The veil dylib MUST carry the embedded-node FFI (built --features node-embedded),
# else the app degrades to a non-deniable boot. Fail loudly if it doesn't.
if ! nm -gU "$VC" 2>/dev/null | grep -q 'veil_config_init'; then
  echo "ERROR: $VC lacks veil_config_init — not built with --features node-embedded" >&2
  exit 1
fi

mkdir -p "$APP/Contents/Frameworks"
cp -f "$HV" "$VC" "$APP/Contents/Frameworks/"

# Call media engine (codec-stripped libwebrtc + the veil Transport shim) — an
# OPTIONAL dylib built separately from a WebRTC checkout by
# veil_media/macos/build_veil_media_dylib.sh. Bundle it if present; a build
# without it simply has no calls-media capability (Dart guards the FFI).
VM="$ROOT/third_party/veil/flutter/veil_media/macos/Frameworks/libveil_media.dylib"
if [ -f "$VM" ]; then
  cp -f "$VM" "$APP/Contents/Frameworks/"
  echo "bundled libveil_media.dylib (calls media engine)"
else
  echo "note: $VM absent — building without calls-media (run build_veil_media_dylib.sh to add it)"
fi

# On-device speech-to-text (whisper.cpp) — OPTIONAL, built by
# native/whisper/build_veil_whisper_macos.sh. Absent = no voice transcription
# (Dart guards the FFI + hides the affordance).
VW="$ROOT/native/whisper/Frameworks/libveil_whisper.dylib"
if [ -f "$VW" ]; then
  cp -f "$VW" "$APP/Contents/Frameworks/"
  echo "bundled libveil_whisper.dylib (voice transcription)"
else
  echo "note: $VW absent — building without voice transcription"
fi

# The ggml model whisper needs (~57MB). Dart looks in Contents/Resources; the
# dev source is the out-of-repo whisper.cpp checkout (override with
# XVEIL_WHISPER_MODEL_SRC). Without it the Transcribe affordance stays hidden.
WM="${XVEIL_WHISPER_MODEL_SRC:-$HOME/Projects/veilnetwork/whisper.cpp/models/ggml-base-q5_1.bin}"
if [ -f "$WM" ]; then
  cp -f "$WM" "$APP/Contents/Resources/"
  echo "bundled $(basename "$WM") (whisper model)"
else
  echo "note: $WM absent — transcription needs XVEIL_WHISPER_MODEL env at runtime"
fi

echo "bundled into $APP/Contents/Frameworks:"
ls -la "$APP/Contents/Frameworks/" | grep -E 'hidden_volume|veilclient|veil_media'

# Swapping a dylib invalidates the .app's code-signature seal (its CodeResources
# still references the OLD dylib hash), so a strict launch — `flutter run`, or
# Gatekeeper — SIGKILLs the process on dlopen with EXC_BAD_ACCESS / "Code
# Signature Invalid". Re-sign the whole bundle so the seal matches the freshly
# copied dylibs. Without this the app crashes the moment it loads the native
# store.
# Re-attach the SAME entitlements flutter applied at build time — a plain
# `--force` re-sign STRIPS the entitlements blob, which makes the
# file_picker plugin throw ENTITLEMENT_NOT_FOUND (the paperclip silently failed).
#
# Repeated ad-hoc signing changes the app's designated requirement to a new
# cdhash every time a dylib changes. macOS TCC then invalidates the previously
# granted camera/microphone permission: AVFoundation reports a running session
# but delivers no frames until another system prompt is accepted. A stable
# Apple Development identity avoids that local-development regression. Keep
# release behaviour unchanged unless the caller explicitly supplies the real
# distribution identity.
SIGN_IDENTITY="${XVEIL_CODESIGN_IDENTITY:--}"
if [[ "$PROFILE" == "debug" && -z "${XVEIL_CODESIGN_IDENTITY:-}" ]]; then
  DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development:.*/\1/p' \
    | head -1)"
  if [[ -n "$DEV_IDENTITY" ]]; then
    SIGN_IDENTITY="$DEV_IDENTITY"
  fi
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_LABEL="ad-hoc"
else
  SIGN_LABEL="$SIGN_IDENTITY"
fi
echo "re-signing $APP ($SIGN_LABEL, deep, entitlements=$ENTITLEMENTS) after the dylib swap…"
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --deep "$APP" \
  && echo "codesign OK — bundle seal matches the new dylibs" \
  || { echo "ERROR: codesign verify failed after re-sign" >&2; exit 1; }
