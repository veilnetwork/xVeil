#!/usr/bin/env bash
# Build the native Rust libraries xVeil links against, from the submodules.
#
#   libveilclient_ffi  — veil overlay-network client FFI (veil_flutter)
#   libhidden_volume_ffi — deniable storage FFI (hidden_volume plugin)
#   veil-cli           — the node binary spawned by SubprocessNodeController
#
# Debug by default; pass --release for optimized artifacts. Pass --ffi-only
# when the caller embeds the node and does not ship the standalone veil-cli.
# Pass --no-compiled-in-seeds for a build with no built-in seed list.
# Prints the absolute artifact paths so callers can wire VEIL_FFI_DYLIB / link
# steps.
set -euo pipefail

PROFILE="debug"
CARGO_FLAGS=()
BUILD_CLI=true
# This selects only the compiled-in seed list. Runtime discovery through DHT,
# Nostr, or the local network is separate; the island harness disables those
# meeting points in its config. Keep this override out of the shared network
# rule: the Dart half (lib/data/node/network_flavor.dart) has no matching flavor.
SEED_FEATURE_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --release)
      PROFILE="release"
      CARGO_FLAGS+=(--release)
      ;;
    --ffi-only)
      BUILD_CLI=false
      ;;
    --no-compiled-in-seeds)
      SEED_FEATURE_OVERRIDE="allow-empty-seeds"
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
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
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
if [[ -n "$SEED_FEATURE_OVERRIDE" ]]; then
  SEED_FEATURE="$SEED_FEATURE_OVERRIDE"
  echo "==> No compiled-in seeds (veil feature: $SEED_FEATURE; $XVEIL_NETWORK flavor overridden)"
else
  echo "==> Network: $XVEIL_NETWORK (veil feature: $SEED_FEATURE)"
fi
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
# The paths CARGO used, which are not the paths a checkout usually has:
# `CARGO_TARGET_DIR` puts every crate's output in one shared directory, and
# printing the conventional path there names files that do not exist.
OUT_HV="${CARGO_TARGET_DIR:-$HV/target}/$PROFILE"
OUT_VEIL="${CARGO_TARGET_DIR:-$VEIL/target}/$PROFILE"
echo "Artifacts:"
echo "  HV_FFI=$OUT_HV/libhidden_volume_ffi.$EXT"
echo "  VEIL_FFI=$OUT_VEIL/libveilclient_ffi.$EXT"
if [[ "$BUILD_CLI" == true ]]; then
  echo "  VEIL_CLI=$OUT_VEIL/veil-cli"
fi
