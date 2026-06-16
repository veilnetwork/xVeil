#!/usr/bin/env bash
# Build the native Rust libraries for xVeil's MOBILE targets and stage the
# artifacts exactly where each Flutter plugin's podspec / gradle expects them,
# so a subsequent `flutter build ios|apk` Just Works.
#
#   ios      veilclient_ffi (device aarch64) -> veil_flutter/ios/Frameworks/
#            hidden_volume_ffi (device+sim)  -> hidden_volume/ios/*.xcframework
#   android  per-ABI .so for both plugins (handled by each plugin's gradle
#            cargo-ndk task on `flutter build apk`; this just preflights the
#            toolchain and can pre-build via the submodule scripts)
#
# Both mobile libs are built with the in-process node (`node-embedded`) — the
# only way to run a veil node on iOS (no subprocess) and the deniable posture on
# Android. RocksDB stays OFF mobile (in-memory DHT) to keep the binary small.
#
# Usage:
#   scripts/build-mobile.sh ios          # device slice, stage into plugins
#   scripts/build-mobile.sh ios --sim    # simulator slice instead of device
#   scripts/build-mobile.sh android      # preflight + build per-ABI .so
#
# Prerequisites (see each submodule script for detail):
#   iOS:     Xcode + CLT; rustup target add aarch64-apple-ios \
#                          aarch64-apple-ios-sim x86_64-apple-ios
#   Android: cargo install cargo-ndk; export ANDROID_NDK_HOME=...; \
#            rustup target add aarch64-linux-android armv7-linux-androideabi \
#                              x86_64-linux-android
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
HV="$ROOT/third_party/hidden-volume"

PLATFORM="${1:-}"
SIM=false
[[ "${2:-}" == "--sim" ]] && SIM=true

die() { echo "error: $*" >&2; exit 1; }

build_ios() {
  command -v xcodebuild >/dev/null || die "Xcode not found (xcodebuild missing)"

  # veil: device by default; simulator slice with --sim (the veil_flutter
  # podspec vendors a SINGLE libveilclient_ffi.a, so device and simulator are
  # mutually exclusive — rebuild with --sim to switch).
  local veil_triple="aarch64-apple-ios"
  $SIM && veil_triple="aarch64-apple-ios-sim"

  echo "==> veilclient_ffi for $veil_triple (production-seeds,node-embedded)"
  "$VEIL/scripts/build-mobile.sh" --target "$veil_triple"

  local a="$VEIL/target/$veil_triple/release/libveilclient_ffi.a"
  [[ -f "$a" ]] || die "expected staticlib missing: $a"
  local dest="$VEIL/flutter/veil_flutter/ios/Frameworks"
  mkdir -p "$dest"
  cp "$a" "$dest/libveilclient_ffi.a"
  echo "    staged -> $dest/libveilclient_ffi.a"

  # hidden-volume: build-ios.sh self-stages the xcframework into the plugin
  # (device + arm64/x86_64 simulator slices, all platforms in one bundle).
  echo "==> hidden_volume_ffi xcframework (device + simulator)"
  ( cd "$HV" && ./scripts/build-ios.sh )

  echo
  echo "iOS artifacts staged. Next:"
  echo "  (cd ios && pod install) && flutter build ios"
  $SIM && echo "  NOTE: simulator slice staged — rebuild without --sim for a device build."
}

build_android() {
  command -v cargo-ndk >/dev/null || die "cargo-ndk not installed (cargo install cargo-ndk)"
  [[ -n "${ANDROID_NDK_HOME:-}" ]] || die "ANDROID_NDK_HOME is not set (point it at your NDK)"

  # The plugin gradle modules already run cargo-ndk per ABI on `flutter build
  # apk` (with node-embedded), so the normal path is simply:
  echo "Toolchain OK (cargo-ndk + NDK present)."
  echo "Both plugins build their per-ABI .so during the gradle build, so just run:"
  echo "  flutter build apk            # or: flutter run on a device/emulator"
  echo
  echo "To pre-build the .so without gradle (CI / offline):"
  echo "  (cd $VEIL && ./scripts/build-mobile.sh --target aarch64-linux-android)"
  echo "  (cd $HV   && ./scripts/build-android.sh)"
}

case "$PLATFORM" in
  ios)     build_ios ;;
  android) build_android ;;
  *) die "usage: $0 ios [--sim] | android" ;;
esac
