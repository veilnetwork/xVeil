#!/usr/bin/env bash
set -euo pipefail

# Autonomous throughput matrix for the local published onion-stream file path.
#
# It repeatedly invokes scripts/onion-stream-local-live.sh with different
# content range-stream settings, records each run, and writes a compact TSV
# summary that is easy to compare while tuning speed regressions.
#
# Knobs:
#   ONION_STREAM_MATRIX_CASES="6:1048576 8:1048576 6:2097152"
#      Each case is XVEIL_STREAM_RANGE_PARALLELISM:XVEIL_STREAM_RANGE_TARGET_BYTES.
#   ONION_STREAM_MATRIX_FILE_SIZE=16777216
#   ONION_STREAM_MATRIX_MIN_MIB_PER_SEC=      optional floor passed to live test
#   ONION_STREAM_MATRIX_OUT=.dev-onion-stream-matrix
#   ONION_STREAM_MATRIX_CONTINUE_ON_FAIL=1    keep running after failed cases
#   ONION_STREAM_MATRIX_BUILD=0               passed as ONION_STREAM_LIVE_BUILD
#   ONION_STREAM_MATRIX_RUST_LOG=info         passed as ONION_STREAM_LIVE_RUST_LOG

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ONION_STREAM_MATRIX_OUT:-$ROOT/.dev-onion-stream-matrix}"
CASES="${ONION_STREAM_MATRIX_CASES:-6:1048576 8:1048576 6:2097152 4:2097152 4:4194304}"
FILE_SIZE="${ONION_STREAM_MATRIX_FILE_SIZE:-16777216}"
MIN_MIB="${ONION_STREAM_MATRIX_MIN_MIB_PER_SEC:-}"
CONTINUE_ON_FAIL="${ONION_STREAM_MATRIX_CONTINUE_ON_FAIL:-1}"
BUILD="${ONION_STREAM_MATRIX_BUILD:-0}"
RUST_LOG="${ONION_STREAM_MATRIX_RUST_LOG:-info}"

if [[ -z "$CASES" ]]; then
  echo "ONION_STREAM_MATRIX_CASES must not be empty." >&2
  exit 2
fi
if ! [[ "$FILE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ONION_STREAM_MATRIX_FILE_SIZE must be a positive integer." >&2
  exit 2
fi
if [[ "$CONTINUE_ON_FAIL" != "0" && "$CONTINUE_ON_FAIL" != "1" ]]; then
  echo "ONION_STREAM_MATRIX_CONTINUE_ON_FAIL must be 0 or 1." >&2
  exit 2
fi

mkdir -p "$OUT"
summary="$OUT/summary.tsv"
printf 'case\tparallelism\ttarget_bytes\texit_code\tseconds\tmib_per_sec\tlog\n' >"$summary"

overall=0
case_no=0

for spec in $CASES; do
  case_no=$((case_no + 1))
  IFS=: read -r parallelism target_bytes extra <<<"$spec"
  if [[ -n "${extra:-}" ||
        ! "$parallelism" =~ ^[1-9][0-9]*$ ||
        ! "$target_bytes" =~ ^[1-9][0-9]*$ ]]; then
    echo "bad case '$spec' (expected parallelism:target_bytes)" >&2
    exit 2
  fi

  label="case-${case_no}-p${parallelism}-t${target_bytes}"
  log="$OUT/$label.log"
  echo "==> $label file_size=$FILE_SIZE"

  live_env=(
    "ONION_STREAM_LIVE_BUILD=$BUILD"
    "ONION_STREAM_LIVE_FORCE_CLEAN=1"
    "ONION_STREAM_LIVE_RUST_LOG=$RUST_LOG"
    "XVEIL_TEST_FILE_SIZE=$FILE_SIZE"
    "XVEIL_STREAM_RANGE_PARALLELISM=$parallelism"
    "XVEIL_STREAM_RANGE_TARGET_BYTES=$target_bytes"
  )
  if [[ -n "$MIN_MIB" ]]; then
    live_env+=("XVEIL_TEST_MIN_MIB_PER_SEC=$MIN_MIB")
  fi

  code=0
  set +e
  (
    cd "$ROOT"
    env "${live_env[@]}" scripts/onion-stream-local-live.sh
  ) 2>&1 | tee "$log"
  code=${PIPESTATUS[0]}
  set -e

  seconds="$(
    sed -nE 's/.*completed [0-9]+B in ([0-9.]+)s = ([0-9.]+) MiB\/s.*/\1/p' "$log" |
      tail -1
  )"
  mib="$(
    sed -nE 's/.*completed [0-9]+B in ([0-9.]+)s = ([0-9.]+) MiB\/s.*/\2/p' "$log" |
      tail -1
  )"
  seconds="${seconds:-NA}"
  mib="${mib:-NA}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$parallelism" "$target_bytes" "$code" "$seconds" "$mib" "$log" |
    tee -a "$summary"

  if [[ "$code" != "0" ]]; then
    overall=1
    if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
      break
    fi
  fi
done

echo "==> summary: $summary"
column -t -s $'\t' "$summary" 2>/dev/null || cat "$summary"
exit "$overall"
