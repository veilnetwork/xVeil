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
# Set SYNTHETIC_LIVE=0 to skip the autonomous four-node live transfer.
# Set SYNTHETIC_LIVE_FILE_SIZE=N to change the live payload size; the default
# 16 MiB covers the former mid-transfer DHT quota / auto-ban regression.
# Set XVEIL_STREAM_RANGE_PARALLELISM=N and/or
# XVEIL_STREAM_RANGE_TARGET_BYTES=N to tune the autonomous live speed profile.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEIL="$ROOT/third_party/veil"
SYNTHETIC_ROUNDS="${SYNTHETIC_ROUNDS:-1}"
SYNTHETIC_LIVE="${SYNTHETIC_LIVE:-1}"
SYNTHETIC_LIVE_FILE_SIZE="${SYNTHETIC_LIVE_FILE_SIZE:-16777216}"
SYNTHETIC_LIVE_MIN_MIB_PER_SEC="${SYNTHETIC_LIVE_MIN_MIB_PER_SEC:-}"

if [[ ! "$SYNTHETIC_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNTHETIC_ROUNDS must be a positive integer." >&2
  exit 2
fi
if [[ "$SYNTHETIC_LIVE" != "0" && "$SYNTHETIC_LIVE" != "1" ]]; then
  echo "SYNTHETIC_LIVE must be 0 or 1." >&2
  exit 2
fi
if ! [[ "$SYNTHETIC_LIVE_FILE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNTHETIC_LIVE_FILE_SIZE must be a positive integer." >&2
  exit 2
fi

run_round() {
  local round="$1"
  local steps=6
  if [[ "$SYNTHETIC_LIVE" == "1" ]]; then
    steps=7
  fi
  echo "== synthetic round $round/$SYNTHETIC_ROUNDS =="

  echo "[1/$steps] Rust stream mux fault-injection"
  (
    cd "$VEIL"
    cargo test -p veil-onion-stream --test mux_fault -- --nocapture
  )

  echo "[2/$steps] Rust stream full test suite"
  (
    cd "$VEIL"
    cargo test -p veil-onion-stream
  )

  echo "[3/$steps] veilclient-ffi circuit framing smoke tests"
  (
    cd "$VEIL"
    cargo test -p veilclient-ffi --features node-embedded anon_stream::tests
  )

  echo "[4/$steps] Dart/Flutter content stream resume tests"
  (
    cd "$ROOT"
    flutter test test/content_stream_transfer_test.dart
  )

  echo "[5/$steps] Static analysis for touched Dart files"
  (
    cd "$ROOT"
    dart analyze \
      lib/debug/soak_hook.dart \
      lib/main.dart \
      lib/state/messaging.dart \
      test/content_stream_transfer_test.dart
  )

  echo "[6/$steps] Shell harness syntax checks"
  (
    cd "$ROOT"
    bash -n \
      scripts/onion-stream-device-soak.sh \
      scripts/onion-stream-hook-transfer.sh \
      scripts/onion-stream-local-live.sh \
      scripts/onion-stream-synthetic.sh \
      scripts/onion_stream_soak.sh
  )

  if [[ "$SYNTHETIC_LIVE" == "1" ]]; then
    echo "[7/$steps] Autonomous local live published onion-stream file transfer"
    (
      cd "$ROOT"
      live_env=(
        "XVEIL_TEST_FILE_SIZE=$SYNTHETIC_LIVE_FILE_SIZE"
      )
      if [[ -n "$SYNTHETIC_LIVE_MIN_MIB_PER_SEC" ]]; then
        live_env+=("XVEIL_TEST_MIN_MIB_PER_SEC=$SYNTHETIC_LIVE_MIN_MIB_PER_SEC")
      fi
      env "${live_env[@]}" scripts/onion-stream-local-live.sh
    )
  fi
}

for ((round = 1; round <= SYNTHETIC_ROUNDS; round++)); do
  run_round "$round"
done

echo "ok: onion stream synthetic harness passed ($SYNTHETIC_ROUNDS round(s))"
