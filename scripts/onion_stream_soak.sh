#!/usr/bin/env bash
set -euo pipefail

# Real-device onion-stream soak harness.
#
# What it automates:
#   - stops stale Android/macOS debug app processes;
#   - enables the pinned onion-stream circuit mode on Android via setprop;
#   - launches desktop + Android debug builds with the local Rust dylibs;
#   - captures Flutter/app/logcat output under one timestamped log directory;
#   - optionally monitors a destination file until it reaches EXPECT_SIZE.
#
# What it deliberately does NOT fake:
#   - UI send/download actions. Until the app has a debug-only command endpoint,
#     trigger the transfer manually or set SOAK_TRIGGER_CMD to an explicit command
#     that does it in your environment.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="${APP_ID:-network.veil.xveil}"
ANDROID_SERIAL="${ANDROID_SERIAL:-}"
VEIL_CIRCUIT_MODE="${VEIL_CIRCUIT_MODE:-published}"
LOG_DIR="${LOG_DIR:-$ROOT/scratchpad/soak-$(date +%Y%m%d-%H%M%S)}"
DESKTOP_DYLIB="${DESKTOP_DYLIB:-$ROOT/third_party/veil/target/debug/libveilclient_ffi.dylib}"
HV_DYLIB="${HV_DYLIB:-$ROOT/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-}"
EXPECT_SIZE="${EXPECT_SIZE:-}"
SOAK_TRIGGER_CMD="${SOAK_TRIGGER_CMD:-}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
KILL_OLD="${KILL_OLD:-1}"

mkdir -p "$LOG_DIR"

if [[ -z "$ANDROID_SERIAL" ]]; then
  ANDROID_SERIAL="$(
    adb devices |
      awk 'NR > 1 && $2 == "device" { print $1; exit }'
  )"
fi

if [[ -z "$ANDROID_SERIAL" ]]; then
  echo "No adb device found. Set ANDROID_SERIAL=... or connect a phone." >&2
  exit 2
fi

pids=()

cleanup() {
  local code=$?
  for pid in "${pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  echo "logs: $LOG_DIR"
  exit "$code"
}
trap cleanup EXIT INT TERM

echo "root: $ROOT"
echo "logs: $LOG_DIR"
echo "android: $ANDROID_SERIAL"
echo "circuit mode: $VEIL_CIRCUIT_MODE"

if [[ "$KILL_OLD" == "1" ]]; then
  adb -s "$ANDROID_SERIAL" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  pkill -f "build/macos/Build/Products/Debug/xveil.app" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*-d macos" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*$ANDROID_SERIAL" >/dev/null 2>&1 || true
fi

adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_circuit "$VEIL_CIRCUIT_MODE"
adb -s "$ANDROID_SERIAL" shell svc power stayon true >/dev/null 2>&1 || true
adb -s "$ANDROID_SERIAL" logcat -c || true

adb -s "$ANDROID_SERIAL" logcat -v time >"$LOG_DIR/android-logcat.log" 2>&1 &
pids+=("$!")

(
  cd "$ROOT"
  VEIL_FFI_DYLIB="$DESKTOP_DYLIB" \
    XVEIL_HV_DYLIB="$HV_DYLIB" \
    VEIL_ONION_STREAM_CIRCUIT="$VEIL_CIRCUIT_MODE" \
    flutter run --no-pub -d macos --debug
) >"$LOG_DIR/desktop-flutter.log" 2>&1 &
pids+=("$!")

(
  cd "$ROOT"
  flutter run --no-pub -d "$ANDROID_SERIAL" --debug
) >"$LOG_DIR/android-flutter.log" 2>&1 &
pids+=("$!")

echo "waiting for apps to boot..."
for _ in $(seq 1 90); do
  if grep -q "onion-stream:" "$LOG_DIR/desktop-flutter.log" 2>/dev/null &&
     grep -q "onion-stream:" "$LOG_DIR/android-flutter.log" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ -n "$SOAK_TRIGGER_CMD" ]]; then
  echo "running SOAK_TRIGGER_CMD"
  (
    cd "$ROOT"
    bash -lc "$SOAK_TRIGGER_CMD"
  ) >"$LOG_DIR/trigger.log" 2>&1
fi

echo "monitoring; Ctrl-C to stop"
echo "time,size,delta_bytes,bytes_per_sec,phone_pid,desktop_errors,android_errors" \
  >"$LOG_DIR/progress.csv"

last_size=0
last_ts="$(date +%s)"
while true; do
  now="$(date +%s)"
  size=0
  if [[ -n "$DOWNLOAD_PATH" && -e "$DOWNLOAD_PATH" ]]; then
    size="$(stat -f '%z' "$DOWNLOAD_PATH" 2>/dev/null || echo 0)"
  fi
  dt=$((now - last_ts))
  delta=$((size - last_size))
  bps=0
  if (( dt > 0 && delta > 0 )); then
    bps=$((delta / dt))
  fi
  phone_pid="$(
    adb -s "$ANDROID_SERIAL" shell pidof "$APP_ID" 2>/dev/null |
      tr -d '\r' |
      awk '{ print $1 }'
  )"
  desktop_errors="$(
    grep -E "stream-pull failed|payload idle|driver gone|onion stream reset|Connection reset" \
      "$LOG_DIR/desktop-flutter.log" 2>/dev/null |
      tail -1 |
      tr ',' ';'
  )"
  android_errors="$(
    grep -E "stream-serve failed|driver gone|onion stream reset|Connection reset" \
      "$LOG_DIR/android-flutter.log" "$LOG_DIR/android-logcat.log" 2>/dev/null |
      tail -1 |
      tr ',' ';'
  )"
  echo "$(date '+%H:%M:%S'),$size,$delta,$bps,${phone_pid:-missing},$desktop_errors,$android_errors" \
    | tee -a "$LOG_DIR/progress.csv"

  if [[ -n "$EXPECT_SIZE" && "$size" -ge "$EXPECT_SIZE" ]]; then
    echo "expected size reached: $size >= $EXPECT_SIZE"
    break
  fi

  last_size="$size"
  last_ts="$now"
  sleep "$MONITOR_INTERVAL"
done
