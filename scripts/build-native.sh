#!/usr/bin/env bash
# Build the native Rust libraries xVeil links against, from the submodules.
#
#   libveilclient_ffi  — veil overlay-network client FFI (veil_flutter)
#   libhidden_volume_ffi — deniable storage FFI (hidden_volume plugin)
#   veil-cli           — the node binary spawned by SubprocessNodeController
#
# Debug by default; pass --release for optimized artifacts. Prints the
# absolute artifact paths so callers can wire VEIL_FFI_DYLIB / link steps.
set -euo pipefail

PROFILE="debug"
CARGO_FLAGS=()
if [[ "${1:-}" == "--release" ]]; then
  PROFILE="release"
  CARGO_FLAGS+=(--release)
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
HV="$ROOT/third_party/hidden-volume"

echo "==> Building hidden-volume-ffi ($PROFILE)"
( cd "$HV" && cargo build -p hidden-volume-ffi ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )

echo "==> Building veilclient-ffi ($PROFILE)"
( cd "$VEIL" && cargo build -p veilclient-ffi ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )

echo "==> Building veil-cli ($PROFILE)"
( cd "$VEIL" && cargo build -p veil-cli ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )

case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  Linux)  EXT="so" ;;
  *)      EXT="dll" ;;
esac

echo
echo "Artifacts:"
echo "  HV_FFI=$HV/target/$PROFILE/libhidden_volume_ffi.$EXT"
echo "  VEIL_FFI=$VEIL/target/$PROFILE/libveilclient_ffi.$EXT"
echo "  VEIL_CLI=$VEIL/target/$PROFILE/veil-cli"
