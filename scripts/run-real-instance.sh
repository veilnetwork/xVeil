#!/usr/bin/env bash
# Launch ONE built xVeil macOS app instance in REAL mode (real veil node +
# overlay transport) against a given node config and storage path. Run it twice
# (two configs, two stores) to get two chat windows on one machine.
#
# Prereqs: scripts/build-native.sh, a running node for <config> (see
# scripts/dev-real-pair.sh), and `flutter build macos --debug`.
#
# Usage: scripts/run-real-instance.sh <config.toml> <store-path>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:?usage: run-real-instance.sh <config.toml> <store-path>}"
STORE="${2:?usage: run-real-instance.sh <config.toml> <store-path>}"

APP="$ROOT/build/macos/Build/Products/Debug/xveil.app/Contents/MacOS/xveil"
[[ -x "$APP" ]] || { echo "Build the app first: flutter build macos --debug" >&2; exit 1; }

VEIL_FFI_DYLIB="$ROOT/third_party/veil/target/debug/libveilclient_ffi.dylib" \
XVEIL_HV_DYLIB="$ROOT/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib" \
XVEIL_VEIL_CLI="$ROOT/third_party/veil/target/debug/veil-cli" \
XVEIL_VEIL_CONFIG="$CONFIG" \
XVEIL_STORE_PATH="$STORE" \
  "$APP" &

echo "launched xVeil (real mode) against $CONFIG, store=$STORE, pid=$!"
