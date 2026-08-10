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
PACKET_TUNNEL_ENT="$ROOT/macos/PacketTunnel/PacketTunnel.entitlements"
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

# The same question about the OTHER dylib, which this script has been copying
# unchecked since it was written. hidden-volume owns the at-rest format, so a
# stale copy here is worse than a stale veilclient: the Dart bindings carry a
# per-method uniffi checksum table that fails CLOSED, and the app then refuses
# to open its own container rather than misbehaving visibly. That is the macOS
# twin of the Android jniLibs staleness of 2026-08-02..05 — same cause (nothing
# on the packaging path rebuilds it), same silence.
BUILD_HINT="scripts/build-native.sh"
[ "$PROFILE" = "release" ] && BUILD_HINT="scripts/build-native.sh --release"
# tests/benches/examples are separate cargo targets, never linked into the
# cdylib — condemning the dylib for a test-only edit would just teach the
# operator to work around the check.
newer_hv_source="$(find "$ROOT/third_party/hidden-volume/crates" \
  -type f \( -name '*.rs' -o -name 'Cargo.toml' \) \
  -not -path '*/tests/*' -not -path '*/benches/*' \
  -not -path '*/examples/*' -not -path '*/fuzz/*' \
  -newer "$HV" -print -quit)"
if [ -z "$newer_hv_source" ]; then
  newer_hv_source="$(find "$ROOT/third_party/hidden-volume" -maxdepth 1 -type f \
    \( -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
    -newer "$HV" -print -quit)"
fi
if [ -n "$newer_hv_source" ]; then
  echo "ERROR: $HV is older than Rust source $newer_hv_source" >&2
  echo "The app would refuse to open its own container (uniffi checksum guard)." >&2
  echo "run: $BUILD_HINT" >&2
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
  # Checked before it is bundled, for the reason the check itself gives: the
  # engine is a prebuilt delivered out of band, and a stale one is invisible —
  # it links, it bundles, the app starts, and the first call fails at dlsym.
  # CI checks the Linux and Android copies; this is the macOS one, which until
  # the check learned to read Mach-O could not be checked at all.
  #
  # Not fatal: a build without calls-media is a supported build, and refusing
  # to bundle is the same outcome the `else` branch below already produces.
  if ! "$ROOT/scripts/check-media-symbols.sh" "$VM"; then
    echo "WARNING: not bundling libveil_media.dylib — see the check above." >&2
  else
    cp -f "$VM" "$APP/Contents/Frameworks/"
    echo "bundled libveil_media.dylib (calls media engine)"
  fi
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

# On-device translation (CTranslate2 + SentencePiece) — OPTIONAL, built by
# native/translate/build_veil_translate_macos.sh. Absent = no translation
# (the provider resolves to null and the affordance never appears).
#
# It is here because a library nobody copies is a library the app cannot load:
# the Android build had exactly this shape, staging beside its own script
# instead of where the APK packages from, and every check still called the
# engine fine.
VT="$ROOT/native/translate/Frameworks/libveil_translate.dylib"
if [ -f "$VT" ]; then
  cp -f "$VT" "$APP/Contents/Frameworks/"
  echo "bundled libveil_translate.dylib (message translation)"
else
  echo "note: $VT absent — building without message translation"
fi

# The ggml model whisper needs (~57MB) is NO LONGER BUNDLED BY DEFAULT: it does
# not compress, so it dominated the download for a feature most people never
# use. The app fetches it on demand and keeps it once for the whole app, in the
# support directory Dart already probes.
#
# Set XVEIL_BUNDLE_WHISPER_MODEL=1 for a build that installs without a network;
# Dart still looks in Contents/Resources first, so a bundled copy wins.
WM="${XVEIL_WHISPER_MODEL_SRC:-$HOME/Projects/veilnetwork/whisper.cpp/models/ggml-base-q5_1.bin}"
if [ "${XVEIL_BUNDLE_WHISPER_MODEL:-0}" = "1" ]; then
  if [ -f "$WM" ]; then
    cp -f "$WM" "$APP/Contents/Resources/"
    echo "bundled $(basename "$WM") (whisper model)"
  else
    echo "ERROR: XVEIL_BUNDLE_WHISPER_MODEL=1 but $WM is absent" >&2
    exit 1
  fi
else
  # A stale copy from an earlier bundled build would silently keep winning.
  rm -f "$APP/Contents/Resources/ggml-base-q5_1.bin"
  echo "whisper model not bundled — the app fetches it on demand"
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
echo "re-signing $APP ($SIGN_LABEL, entitlements=$ENTITLEMENTS) after the dylib swap…"
# Do not use `--deep --entitlements "$ENT"`: codesign then applies the host
# app's debug relaxations (allow-jit, disable-library-validation, …) to the
# nested PacketTunnel system extension as well. AMFI rejects that combination
# at process launch with "Hardened Runtime relaxation entitlements disallowed
# on System Extensions" even though `codesign --verify --deep` says the bundle
# is structurally valid. Sign each modified leaf, restore the extension's own
# restricted entitlement set, then seal the containing app last.
FRAMEWORKS_DIR="$APP/Contents/Frameworks"
# A normal `flutter build macos` signs plugin frameworks before this script
# runs. The local PacketTunnel fallback builds with CODE_SIGNING_ALLOWED=NO,
# however, so every copied code object is unsigned. Sign all dylib leaves and
# framework bundles (deepest first) instead of assuming only our four runtime
# libraries need attention.
while IFS= read -r -d '' dylib; do
  codesign --force --sign "$SIGN_IDENTITY" "$dylib"
done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' framework; do
  codesign --force --sign "$SIGN_IDENTITY" "$framework"
done < <(find "$FRAMEWORKS_DIR" -depth -type d -name '*.framework' -print0)
PACKET_TUNNEL_APP="$APP/Contents/PlugIns/PacketTunnel.appex"
if [[ -d "$PACKET_TUNNEL_APP" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$PACKET_TUNNEL_ENT" "$PACKET_TUNNEL_APP"
fi
HOST_ENT="$ENT"
TEMP_HOST_ENT=""
if [[ "$PROFILE" == "debug" \
      && -d "$PACKET_TUNNEL_APP" \
      && ! -f "$APP/Contents/embedded.provisionprofile" ]]; then
  # The Network Extension entitlement is restricted. A local Flutter debug
  # build normally has no provisioning profile; retaining that entitlement
  # beside allow-jit/disable-library-validation makes AMFI classify and reject
  # the host executable as an improperly relaxed system extension. Keep the
  # correctly entitled nested provider, but omit the restricted host
  # entitlement for an unprovisioned local-debug app. Provisioned builds keep
  # the complete entitlement set and therefore retain system VPN management.
  TEMP_HOST_ENT="$(mktemp)"
  cp "$ENT" "$TEMP_HOST_ENT"
  /usr/libexec/PlistBuddy -c \
    'Delete :com.apple.developer.networking.networkextension' \
    "$TEMP_HOST_ENT"
  HOST_ENT="$TEMP_HOST_ENT"
  echo "note: signing unprovisioned debug host without restricted Network Extension entitlement"
fi
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$HOST_ENT" "$APP"
[[ -z "$TEMP_HOST_ENT" ]] || rm -f "$TEMP_HOST_ENT"
codesign --verify --deep "$APP" \
  && echo "codesign OK — bundle seal matches the new dylibs" \
  || { echo "ERROR: codesign verify failed after re-sign" >&2; exit 1; }
