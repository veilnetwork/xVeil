#!/usr/bin/env bash
set -euo pipefail

# Fast, deterministic onion-stream regression harness.
#
# This intentionally does NOT need the phone, Flutter UI, real relays or seeds.
# It covers:
#   * sans-IO reliability/pacing simulations;
#   * StreamMux retry after reset / SYN_ACK blackhole / return-path blackhole;
#   * Flutter content-layer stream resume after payload idle.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"

echo "[1/5] Rust stream mux fault-injection"
(
  cd "$VEIL"
  cargo test -p veil-onion-stream --test mux_fault -- --nocapture
)

echo "[2/5] Rust stream full test suite"
(
  cd "$VEIL"
  cargo test -p veil-onion-stream
)

echo "[3/5] veilclient-ffi circuit gate smoke test"
(
  cd "$VEIL"
  cargo test -p veilclient-ffi --features node-embedded circuit_env_is_strict_opt_in
)

echo "[4/5] Dart/Flutter content stream resume tests"
(
  cd "$ROOT"
  flutter test test/content_stream_transfer_test.dart
)

echo "[5/5] Static analysis for touched Dart files"
(
  cd "$ROOT"
  dart analyze lib/state/messaging.dart test/content_stream_transfer_test.dart
)

echo "ok: onion stream synthetic harness passed"
