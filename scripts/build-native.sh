#!/usr/bin/env bash
# Build the native Rust libraries xVeil links against, from the submodules.
#
#   libveilclient_ffi  — veil overlay-network client FFI (veil_flutter)
#   libhidden_volume_ffi — deniable storage FFI (hidden_volume plugin)
#   veil-cli           — the node binary spawned by SubprocessNodeController
#
# Debug by default; pass --release for optimized artifacts. Pass --ffi-only
# when the caller embeds the node and does not ship the standalone veil-cli.
# Prints the absolute artifact paths so callers can wire VEIL_FFI_DYLIB / link
# steps.
set -euo pipefail

PROFILE="debug"
CARGO_FLAGS=()
BUILD_CLI=true
for arg in "$@"; do
  case "$arg" in
    --release)
      PROFILE="release"
      CARGO_FLAGS+=(--release)
      ;;
    --ffi-only)
      BUILD_CLI=false
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
HV="$ROOT/third_party/hidden-volume"

# C/C++ build scripts otherwise inherit the current macOS SDK as their
# minimum deployment version. The archive still links, but every BoringSSL/PQ
# object then requires the build machine's OS instead of xVeil's contract.
if [[ "$(uname -s)" == "Darwin" ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
fi

echo "==> Building hidden-volume-ffi ($PROFILE)"
( cd "$HV" && cargo build -p hidden-volume-ffi ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )

echo "==> Building veilclient-ffi ($PROFILE, node-embedded,packet-tunnel)"
# node-embedded bundles the in-process node runtime (veil_config_init /
# veil_node_start_deferred / veil_node_apply_config), required for the deniable
# in-process boot. It is additive — the client-only symbols are still present.
# WHICH NETWORK THIS BINARY BELONGS TO, and it is not a detail of packaging.
# The node splices its compiled-in seed list in by itself whenever the config
# names no peers, so this feature — not the bundled asset — decides what a stock
# install actually dials. The rule has ONE home, shared with every other build
# path and mirrored by the Dart half (lib/data/node/network_flavor.dart).
# shellcheck source=scripts/veil-network.sh
source "$(dirname "${BASH_SOURCE[0]}")/veil-network.sh"
echo "==> Network: $XVEIL_NETWORK (veil feature: $SEED_FEATURE)"
VEIL_FEATURES="node-embedded,$SEED_FEATURE,packet-tunnel"
( cd "$VEIL" && cargo build -p veilclient-ffi --features "$VEIL_FEATURES" ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )

if [[ "$BUILD_CLI" == true ]]; then
  echo "==> Building veil-cli ($PROFILE)"
  ( cd "$VEIL" && cargo build -p veil-cli --features "$SEED_FEATURE" ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )
fi

case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  Linux)  EXT="so" ;;
  *)      EXT="dll" ;;
esac

echo
echo "Artifacts:"
echo "  HV_FFI=$HV/target/$PROFILE/libhidden_volume_ffi.$EXT"
echo "  VEIL_FFI=$VEIL/target/$PROFILE/libveilclient_ffi.$EXT"
if [[ "$BUILD_CLI" == true ]]; then
  echo "  VEIL_CLI=$VEIL/target/$PROFILE/veil-cli"
fi
