#!/usr/bin/env bash
# Build the Rust static library consumed by the macOS PacketTunnel extension.
#
# Keep it outside Cargo's shared target/{debug,release} output: ordinary
# workspace checks may rebuild veilclient-ffi without packet-tunnel and would
# otherwise silently replace the archive Xcode links.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
CONFIGURATION="${1:-Debug}"
ARCHS_VALUE="${2:-$(uname -m)}"

case "$CONFIGURATION" in
  Debug)
    CARGO_PROFILE="debug"
    CARGO_FLAGS=()
    VEIL_FEATURES="node-embedded,packet-tunnel"
    ;;
  Release|Profile)
    CARGO_PROFILE="release"
    CARGO_FLAGS=(--release)
    VEIL_FEATURES="node-embedded,production-seeds,packet-tunnel"
    ;;
  *)
    echo "error: unsupported Xcode configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
OUTPUT_DIR="$ROOT/build/apple-packet-tunnel/$CONFIGURATION"
mkdir -p "$OUTPUT_DIR"

ARCHIVES=()
for arch in $ARCHS_VALUE; do
  case "$arch" in
    arm64) triple="aarch64-apple-darwin" ;;
    x86_64) triple="x86_64-apple-darwin" ;;
    *)
      echo "error: unsupported macOS architecture: $arch" >&2
      exit 2
      ;;
  esac

  target_dir="$VEIL/target/xveil-packet-tunnel-macos-$arch"
  CARGO_TARGET_DIR="$target_dir" cargo build \
    --manifest-path "$VEIL/Cargo.toml" \
    --package veilclient-ffi \
    --target "$triple" \
    --features "$VEIL_FEATURES" \
    "${CARGO_FLAGS[@]}"
  ARCHIVES+=("$target_dir/$triple/$CARGO_PROFILE/libveilclient_ffi.a")
done

OUTPUT="$OUTPUT_DIR/libveilclient_ffi.a"
if [[ ${#ARCHIVES[@]} -eq 1 ]]; then
  cp "${ARCHIVES[0]}" "$OUTPUT"
else
  xcrun lipo -create "${ARCHIVES[@]}" -output "$OUTPUT"
fi

echo "$OUTPUT"
