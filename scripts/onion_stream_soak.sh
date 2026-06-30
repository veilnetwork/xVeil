#!/usr/bin/env bash
set -euo pipefail

# Real-device onion-stream soak harness.
#
# What it automates:
#   - stops stale Android/macOS debug app processes;
#   - enables the pinned onion-stream circuit mode on Android via setprop;
#   - launches desktop + Android debug builds with the local Rust dylibs;
#   - captures Flutter/app/logcat output under one timestamped log directory;
#   - starts a debug-only loopback command hook on both apps;
#   - with SOAK_AUTO_TRANSFER=1, creates a test payload and drives a full
#     phone<->desktop send/download through those hooks;
#   - optionally runs SOAK_TRIGGER_CMD to send/download without UI clicks;
#   - optionally monitors a destination file until it reaches EXPECT_SIZE;
#   - writes progress.csv + summary.{txt,json}, and can fail below a minimum
#     average throughput with SOAK_MIN_BYTES_PER_SEC / SOAK_MIN_MIB_PER_SEC.
#
# What it deliberately does NOT fake:
#   - unlocking the deniable space. Start from an unlocked/ready app, or unlock
#     once manually; after that SOAK_TRIGGER_CMD can drive send/download.

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
ENABLE_DEBUG_HOOK="${ENABLE_DEBUG_HOOK:-1}"
DESKTOP_HOOK_PORT="${DESKTOP_HOOK_PORT:-38765}"
ANDROID_HOOK_PORT="${ANDROID_HOOK_PORT:-38766}"
ANDROID_HOST_HOOK_PORT="${ANDROID_HOST_HOOK_PORT:-38766}"
SOAK_AUTO_TRANSFER="${SOAK_AUTO_TRANSFER:-0}"
SOAK_SENDER="${SOAK_SENDER:-android}" # android|desktop
SOAK_SIZE="${SOAK_SIZE:-104857600}"
SOAK_NAME="${SOAK_NAME:-soak.bin}"
SOAK_SOURCE_PATH="${SOAK_SOURCE_PATH:-${SOURCE_PATH:-}}"
SOAK_DEST_PATH="${SOAK_DEST_PATH:-${DEST_PATH:-}}"
SOAK_SOURCE_LOCAL="${SOAK_SOURCE_LOCAL:-}"
SOAK_GENERATE_SOURCE="${SOAK_GENERATE_SOURCE:-auto}" # auto|0|1
SOAK_WAIT_READY_MS="${SOAK_WAIT_READY_MS:-120000}"
SOAK_EXIT_AFTER_TRANSFER="${SOAK_EXIT_AFTER_TRANSFER:-$SOAK_AUTO_TRANSFER}"
SOAK_MIN_BYTES_PER_SEC="${SOAK_MIN_BYTES_PER_SEC:-}"
SOAK_MIN_MIB_PER_SEC="${SOAK_MIN_MIB_PER_SEC:-}"

mkdir -p "$LOG_DIR"

android_shell_quote() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

make_payload() {
  local size="$1"
  local path="$2"
  python3 - "$size" "$path" <<'PY'
import hashlib
import os
import sys

size = int(sys.argv[1])
path = sys.argv[2]
directory = os.path.dirname(path)
if directory:
    os.makedirs(directory, exist_ok=True)

sha = hashlib.sha256()
remaining = size
with open(path, "wb") as f:
    while remaining:
        chunk = os.urandom(min(1024 * 1024, remaining))
        f.write(chunk)
        sha.update(chunk)
        remaining -= len(chunk)

print(sha.hexdigest())
PY
}

auto_source_path=""
auto_dest_path=""
auto_sha256=""
auto_expected_size=""
min_bytes_per_sec=""

resolve_min_speed() {
  min_bytes_per_sec="$SOAK_MIN_BYTES_PER_SEC"
  if [[ -z "$min_bytes_per_sec" && -n "$SOAK_MIN_MIB_PER_SEC" ]]; then
    min_bytes_per_sec="$(
      awk -v mib="$SOAK_MIN_MIB_PER_SEC" 'BEGIN { printf "%.0f", mib * 1024 * 1024 }'
    )"
  fi
  if [[ -n "$min_bytes_per_sec" && ! "$min_bytes_per_sec" =~ ^[0-9]+$ ]]; then
    echo "SOAK_MIN_BYTES_PER_SEC/SOAK_MIN_MIB_PER_SEC must resolve to an integer B/s." >&2
    exit 2
  fi
}

prepare_auto_transfer() {
  if [[ "$SOAK_AUTO_TRANSFER" != "1" ]]; then
    return
  fi
  if [[ "$SOAK_SENDER" != "android" && "$SOAK_SENDER" != "desktop" ]]; then
    echo "SOAK_SENDER must be android or desktop." >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for SOAK_AUTO_TRANSFER." >&2
    exit 2
  fi

  local source_was_defaulted=0
  if [[ -n "$SOAK_SOURCE_PATH" ]]; then
    auto_source_path="$SOAK_SOURCE_PATH"
  elif [[ "$SOAK_SENDER" == "android" ]]; then
    auto_source_path="/sdcard/Android/data/$APP_ID/files/soak/source-$SOAK_NAME"
    source_was_defaulted=1
  else
    auto_source_path="$LOG_DIR/source-$SOAK_NAME"
    source_was_defaulted=1
  fi

  if [[ -n "$SOAK_DEST_PATH" ]]; then
    auto_dest_path="$SOAK_DEST_PATH"
  elif [[ "$SOAK_SENDER" == "android" ]]; then
    auto_dest_path="$LOG_DIR/download-$SOAK_NAME"
  else
    auto_dest_path="/sdcard/Android/data/$APP_ID/files/soak/download-$SOAK_NAME"
  fi

  local generate="$SOAK_GENERATE_SOURCE"
  if [[ "$generate" == "auto" ]]; then
    if [[ "$source_was_defaulted" == "1" ]]; then
      generate=1
    else
      generate=0
    fi
  fi

  if [[ "$generate" == "1" ]]; then
    local local_source="$auto_source_path"
    if [[ "$SOAK_SENDER" == "android" ]]; then
      local_source="${SOAK_SOURCE_LOCAL:-$LOG_DIR/source-$SOAK_NAME}"
    fi

    echo "generating soak payload: $SOAK_SIZE bytes -> $local_source"
    auto_sha256="$(make_payload "$SOAK_SIZE" "$local_source")"
    auto_expected_size="$SOAK_SIZE"

    if [[ "$SOAK_SENDER" == "android" ]]; then
      local device_dir="${auto_source_path%/*}"
      if [[ "$device_dir" == "$auto_source_path" ]]; then
        device_dir="."
      fi
      echo "pushing soak payload to Android: $auto_source_path"
      adb -s "$ANDROID_SERIAL" shell \
        "mkdir -p $(android_shell_quote "$device_dir")" >/dev/null
      adb -s "$ANDROID_SERIAL" push "$local_source" "$auto_source_path" \
        >"$LOG_DIR/adb-push-source.log"
    fi
  elif [[ "$generate" != "0" ]]; then
    echo "SOAK_GENERATE_SOURCE must be auto, 0 or 1." >&2
    exit 2
  elif [[ "$SOAK_SENDER" == "desktop" && -f "$auto_source_path" ]]; then
    auto_expected_size="$(stat -f '%z' "$auto_source_path" 2>/dev/null || stat -c '%s' "$auto_source_path")"
    auto_sha256="$(
      shasum -a 256 "$auto_source_path" 2>/dev/null |
        awk '{print $1}'
    )"
  fi

  if [[ "$SOAK_SENDER" == "android" ]]; then
    DOWNLOAD_PATH="${DOWNLOAD_PATH:-$auto_dest_path}"
  fi
  if [[ -n "$auto_expected_size" ]]; then
    EXPECT_SIZE="${EXPECT_SIZE:-$auto_expected_size}"
  fi

  echo "auto transfer: sender=$SOAK_SENDER"
  echo "auto source: $auto_source_path"
  echo "auto dest: $auto_dest_path"
  if [[ -n "$auto_expected_size" ]]; then
    echo "auto expect size: $auto_expected_size"
  fi
}

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

resolve_min_speed
prepare_auto_transfer

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
echo "debug hook: $ENABLE_DEBUG_HOOK"
if [[ "$ENABLE_DEBUG_HOOK" == "1" ]]; then
  echo "desktop hook: http://127.0.0.1:$DESKTOP_HOOK_PORT"
  echo "android hook: http://127.0.0.1:$ANDROID_HOST_HOOK_PORT -> device:$ANDROID_HOOK_PORT"
fi
if [[ -n "$min_bytes_per_sec" ]]; then
  echo "minimum average throughput: $min_bytes_per_sec B/s"
fi

if [[ "$KILL_OLD" == "1" ]]; then
  adb -s "$ANDROID_SERIAL" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  pkill -f "build/macos/Build/Products/Debug/xveil.app" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*-d macos" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*$ANDROID_SERIAL" >/dev/null 2>&1 || true
fi

adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_circuit "$VEIL_CIRCUIT_MODE"
adb -s "$ANDROID_SERIAL" shell svc power stayon true >/dev/null 2>&1 || true
adb -s "$ANDROID_SERIAL" logcat -c || true
if [[ "$ENABLE_DEBUG_HOOK" == "1" ]]; then
  adb -s "$ANDROID_SERIAL" forward \
    "tcp:$ANDROID_HOST_HOOK_PORT" "tcp:$ANDROID_HOOK_PORT" >/dev/null
fi

adb -s "$ANDROID_SERIAL" logcat -v time >"$LOG_DIR/android-logcat.log" 2>&1 &
pids+=("$!")

desktop_defines=()
android_defines=()
if [[ "$ENABLE_DEBUG_HOOK" == "1" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_DEBUG_HOOK=true"
    "--dart-define=XVEIL_DEBUG_HOOK_PORT=$DESKTOP_HOOK_PORT"
  )
  android_defines+=(
    "--dart-define=XVEIL_DEBUG_HOOK=true"
    "--dart-define=XVEIL_DEBUG_HOOK_PORT=$ANDROID_HOOK_PORT"
  )
fi

(
  cd "$ROOT"
  VEIL_FFI_DYLIB="$DESKTOP_DYLIB" \
    XVEIL_HV_DYLIB="$HV_DYLIB" \
    VEIL_ONION_STREAM_CIRCUIT="$VEIL_CIRCUIT_MODE" \
    flutter run --no-pub -d macos --debug "${desktop_defines[@]}"
) >"$LOG_DIR/desktop-flutter.log" 2>&1 &
pids+=("$!")

(
  cd "$ROOT"
  flutter run --no-pub -d "$ANDROID_SERIAL" --debug "${android_defines[@]}"
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

if [[ "$ENABLE_DEBUG_HOOK" == "1" ]] && command -v curl >/dev/null 2>&1; then
  echo "waiting for debug hooks..."
  for _ in $(seq 1 90); do
    desktop_ok=0
    android_ok=0
    curl -fsS "http://127.0.0.1:$DESKTOP_HOOK_PORT/health" \
      >"$LOG_DIR/desktop-hook-health.json" 2>/dev/null && desktop_ok=1 || true
    curl -fsS "http://127.0.0.1:$ANDROID_HOST_HOOK_PORT/health" \
      >"$LOG_DIR/android-hook-health.json" 2>/dev/null && android_ok=1 || true
    if [[ "$desktop_ok" == "1" && "$android_ok" == "1" ]]; then
      break
    fi
    sleep 1
  done
fi

trigger_pid=""
trigger_status_file="$LOG_DIR/trigger.status"
if [[ "$SOAK_AUTO_TRANSFER" == "1" ]]; then
  echo "running auto hook transfer"
  (
    set +e
    if cd "$ROOT"; then
      DESKTOP_HOOK="http://127.0.0.1:$DESKTOP_HOOK_PORT" \
        ANDROID_HOOK="http://127.0.0.1:$ANDROID_HOST_HOOK_PORT" \
        SENDER="$SOAK_SENDER" \
        SOURCE_PATH="$auto_source_path" \
        DEST_PATH="$auto_dest_path" \
        NAME="$SOAK_NAME" \
        WAIT_READY_MS="$SOAK_WAIT_READY_MS" \
        EXPECT_SHA256="$auto_sha256" \
        scripts/onion-stream-hook-transfer.sh
      status=$?
    else
      status=1
    fi
    echo "$status" >"$trigger_status_file"
    exit "$status"
  ) >"$LOG_DIR/auto-transfer.log" 2>&1 &
  trigger_pid="$!"
  pids+=("$trigger_pid")
elif [[ -n "$SOAK_TRIGGER_CMD" ]]; then
  echo "running SOAK_TRIGGER_CMD"
  (
    set +e
    if cd "$ROOT"; then
      bash -lc "$SOAK_TRIGGER_CMD"
      status=$?
    else
      status=1
    fi
    echo "$status" >"$trigger_status_file"
    exit "$status"
  ) >"$LOG_DIR/trigger.log" 2>&1 &
  trigger_pid="$!"
  pids+=("$trigger_pid")
fi

echo "monitoring; Ctrl-C to stop"
echo "time,size,delta_bytes,bytes_per_sec,phone_pid,desktop_errors,android_errors" \
  >"$LOG_DIR/progress.csv"

last_size=0
last_ts="$(date +%s)"
monitor_start_ts="$last_ts"
final_size=0
first_byte_ts=""
last_byte_ts=""
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
  final_size="$size"
  if (( size > 0 )); then
    if [[ -z "$first_byte_ts" ]]; then
      first_byte_ts="$now"
    fi
    if (( size > last_size )); then
      last_byte_ts="$now"
    fi
  fi

  if [[ -n "$EXPECT_SIZE" && "$size" -ge "$EXPECT_SIZE" ]]; then
    echo "expected size reached: $size >= $EXPECT_SIZE"
    break
  fi
  if [[ -n "$trigger_pid" && -f "$trigger_status_file" ]]; then
    trigger_status="$(cat "$trigger_status_file")"
    if [[ "$trigger_status" != "0" ]]; then
      echo "trigger failed with status $trigger_status; see $LOG_DIR" >&2
      exit "$trigger_status"
    fi
    if [[ "$SOAK_EXIT_AFTER_TRANSFER" == "1" && -z "$EXPECT_SIZE" ]]; then
      echo "trigger completed"
      break
    fi
  fi

  last_size="$size"
  last_ts="$now"
  sleep "$MONITOR_INTERVAL"
done

if [[ -n "$trigger_pid" ]]; then
  trigger_wait_status=0
  wait "$trigger_pid" || trigger_wait_status=$?
  trigger_status="$trigger_wait_status"
  if [[ -f "$trigger_status_file" ]]; then
    trigger_status="$(cat "$trigger_status_file")"
  fi
  if [[ "$trigger_status" != "0" ]]; then
    echo "trigger failed with status $trigger_status; see $LOG_DIR" >&2
    exit "$trigger_status"
  fi
fi

summary_ts="$(date +%s)"
wall_elapsed_sec=$((summary_ts - monitor_start_ts))
if (( wall_elapsed_sec < 1 )); then
  wall_elapsed_sec=1
fi
active_elapsed_sec="$wall_elapsed_sec"
if [[ -n "$first_byte_ts" && -n "$last_byte_ts" ]]; then
  active_elapsed_sec=$((last_byte_ts - first_byte_ts))
  if (( active_elapsed_sec < 1 )); then
    active_elapsed_sec=1
  fi
fi
avg_bps=$((final_size / active_elapsed_sec))
wall_avg_bps=$((final_size / wall_elapsed_sec))
avg_mib_s="$(
  awk -v bps="$avg_bps" 'BEGIN { printf "%.3f", bps / 1024 / 1024 }'
)"
wall_avg_mib_s="$(
  awk -v bps="$wall_avg_bps" 'BEGIN { printf "%.3f", bps / 1024 / 1024 }'
)"
{
  echo "final_size_bytes=$final_size"
  echo "wall_elapsed_sec=$wall_elapsed_sec"
  echo "active_elapsed_sec=$active_elapsed_sec"
  echo "avg_bytes_per_sec=$avg_bps"
  echo "avg_mib_per_sec=$avg_mib_s"
  echo "wall_avg_bytes_per_sec=$wall_avg_bps"
  echo "wall_avg_mib_per_sec=$wall_avg_mib_s"
  if [[ -n "$EXPECT_SIZE" ]]; then
    echo "expected_size_bytes=$EXPECT_SIZE"
  fi
  if [[ -n "$min_bytes_per_sec" ]]; then
    echo "min_bytes_per_sec=$min_bytes_per_sec"
  fi
} | tee "$LOG_DIR/summary.txt"
cat >"$LOG_DIR/summary.json" <<JSON
{"final_size_bytes":$final_size,"wall_elapsed_sec":$wall_elapsed_sec,"active_elapsed_sec":$active_elapsed_sec,"avg_bytes_per_sec":$avg_bps,"avg_mib_per_sec":$avg_mib_s,"wall_avg_bytes_per_sec":$wall_avg_bps,"wall_avg_mib_per_sec":$wall_avg_mib_s,"expected_size_bytes":${EXPECT_SIZE:-null},"min_bytes_per_sec":${min_bytes_per_sec:-null}}
JSON

if [[ -n "$min_bytes_per_sec" && "$avg_bps" -lt "$min_bytes_per_sec" ]]; then
  echo "average throughput below minimum: $avg_bps < $min_bytes_per_sec B/s" >&2
  exit 1
fi
