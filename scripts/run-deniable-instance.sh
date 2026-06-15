#!/usr/bin/env bash
# Launch ONE xVeil macOS app instance in DENIABLE mode: the node identity is
# mined into and read from the unlocked hidden-volume container — there is NO
# config.toml on disk, and the node boots in-process (deferred-init + apply).
# Run it twice (two stores, two ports) to get two chat windows on one machine.
#
# Prereqs:
#   scripts/build-native.sh        (builds the node-embedded dylib)
#   flutter build macos --debug
#
# Usage: scripts/run-deniable-instance.sh <store-path> <listen-port>
#   e.g. scripts/run-deniable-instance.sh /tmp/xveil-a.store 9000
#        scripts/run-deniable-instance.sh /tmp/xveil-b.store 9001
#
# Note: XVEIL_VEIL_CONFIG is deliberately NOT set — that env var selects the
# legacy config-file path; leaving it unset arms the deniable in-process boot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="${1:?usage: run-deniable-instance.sh <store-path> <listen-port>}"
PORT="${2:?usage: run-deniable-instance.sh <store-path> <listen-port>}"

APP="$ROOT/build/macos/Build/Products/Debug/xveil.app/Contents/MacOS/xveil"
[[ -x "$APP" ]] || { echo "Build the app first: flutter build macos --debug" >&2; exit 1; }

DYLIB="$ROOT/third_party/veil/target/debug/libveilclient_ffi.dylib"
if ! nm -gU "$DYLIB" 2>/dev/null | grep -q "_veil_config_init$"; then
  echo "dylib lacks node-embedded symbols — run scripts/build-native.sh" >&2
  exit 1
fi

VEIL_FFI_DYLIB="$DYLIB" \
XVEIL_HV_DYLIB="$ROOT/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib" \
XVEIL_STORE_PATH="$STORE" \
XVEIL_LISTEN_PORT="$PORT" \
XVEIL_RUNTIME_DIR="${TMPDIR:-/tmp}/xveil-rt-$PORT" \
  "$APP" &

echo "launched xVeil (DENIABLE mode) store=$STORE port=$PORT pid=$!"
