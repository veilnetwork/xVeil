#!/usr/bin/env bash
set -euo pipefail

# Fast, deterministic onion-stream regression harness.
#
# This intentionally does NOT need the phone, Flutter UI, real relays or seeds.
# It covers:
#   * sans-IO reliability/pacing simulations;
#   * StreamMux retry after reset / SYN_ACK blackhole / return-path blackhole;
#   * FFI circuit opt-in plus published-mode protected-intro framing;
#   * Flutter content-layer range, reoffer, resume, disk-write and false-complete
#     regressions, including empty/partial plaintext destinations.
#
# Set SYNTHETIC_ROUNDS=N to repeat the whole deterministic suite N times while
# chasing rare ordering races.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
SYNTHETIC_ROUNDS="${SYNTHETIC_ROUNDS:-1}"

if [[ ! "$SYNTHETIC_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNTHETIC_ROUNDS must be a positive integer." >&2
  exit 2
fi

run_round() {
  local round="$1"
  echo "== synthetic round $round/$SYNTHETIC_ROUNDS =="

  echo "[1/6] Rust stream mux fault-injection"
  (
    cd "$VEIL"
    cargo test -p veil-onion-stream --test mux_fault -- --nocapture
  )

  echo "[2/6] Rust stream full test suite"
  (
    cd "$VEIL"
    cargo test -p veil-onion-stream
  )

  echo "[3/6] veilclient-ffi circuit framing smoke tests"
  (
    cd "$VEIL"
    cargo test -p veilclient-ffi --features node-embedded anon_stream::tests
  )

  echo "[4/6] Dart/Flutter content stream resume tests"
  (
    cd "$ROOT"
    flutter test test/content_stream_transfer_test.dart
  )

  echo "[5/6] Static analysis for touched Dart files"
  (
    cd "$ROOT"
    dart analyze \
      lib/debug/soak_hook.dart \
      lib/main.dart \
      lib/state/messaging.dart \
      test/content_stream_transfer_test.dart
  )

  echo "[6/6] Shell harness syntax checks"
  (
    cd "$ROOT"
    bash -n \
      scripts/onion-stream-device-soak.sh \
      scripts/onion-stream-hook-transfer.sh \
      scripts/onion-stream-local-live.sh \
      scripts/onion-stream-synthetic.sh \
      scripts/onion_stream_soak.sh
  )
}

for ((round = 1; round <= SYNTHETIC_ROUNDS; round++)); do
  run_round "$round"
done

echo "ok: onion stream synthetic harness passed ($SYNTHETIC_ROUNDS round(s))"
