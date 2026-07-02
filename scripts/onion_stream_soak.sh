#!/usr/bin/env bash
set -euo pipefail

# Real-device onion-stream soak harness.
#
# What it automates:
#   - stops stale Android/macOS debug app processes;
#   - optionally rebuilds the local debug Rust native libraries before launch;
#   - enables the pinned onion-stream circuit mode on Android via setprop;
#   - launches desktop + Android debug builds with the local Rust dylibs;
#   - captures Flutter/app/logcat output under one timestamped log directory;
#   - starts a debug-only loopback command hook on both apps;
#   - with SOAK_UNLOCK_PASSWORD=..., unlocks both apps through the debug hook;
#   - with SOAK_AUTO_TRANSFER=1, creates a test payload and drives a full
#     phone<->desktop send/download through those hooks;
#   - with SOAK_DOWNLOAD_PEER=any or SOAK_DOWNLOAD_PEERS=hex,hex, makes the
#     receiver pull from every accepted/explicit holder instead of one sender;
#   - optionally runs SOAK_TRIGGER_CMD to send/download without UI clicks;
#   - optionally monitors a destination file until it reaches EXPECT_SIZE;
#   - optionally injects a real-device fault (custom command or Android Wi-Fi
#     flap) while the transfer is running;
#   - writes progress.csv + summary.{txt,json}, and can fail below a minimum
#     average throughput with SOAK_MIN_BYTES_PER_SEC / SOAK_MIN_MIB_PER_SEC.
#
# What it deliberately does NOT fake:
#   - the production UI path. The optional unlock uses the debug-only hook and
#     posts the password in the request body, not in the URL.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="${APP_ID:-network.veil.xveil}"
ANDROID_SERIAL="${ANDROID_SERIAL:-}"
VEIL_CIRCUIT_MODE="${VEIL_CIRCUIT_MODE:-published}"
LOG_DIR="${LOG_DIR:-$ROOT/scratchpad/soak-$(date +%Y%m%d-%H%M%S)}"
# The Android .so is always a cargo --release build (gradle), so a debug
# desktop dylib makes the stand asymmetric: the desktop's per-cell session/
# stream path runs unoptimized and caps measured throughput. Default to the
# release dylib for speed work; SOAK_NATIVE_PROFILE=debug restores the old
# behavior for debugging native code.
SOAK_NATIVE_PROFILE="${SOAK_NATIVE_PROFILE:-release}"
if [[ "$SOAK_NATIVE_PROFILE" != "debug" && "$SOAK_NATIVE_PROFILE" != "release" ]]; then
  echo "SOAK_NATIVE_PROFILE must be debug or release." >&2
  exit 2
fi
DESKTOP_DYLIB="${DESKTOP_DYLIB:-$ROOT/third_party/veil/target/$SOAK_NATIVE_PROFILE/libveilclient_ffi.dylib}"
HV_DYLIB="${HV_DYLIB:-$ROOT/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib}"
SOAK_BUILD_NATIVE="${SOAK_BUILD_NATIVE:-1}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-}"
ANDROID_DOWNLOAD_PATH="${ANDROID_DOWNLOAD_PATH:-}"
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
SOAK_DOWNLOAD_PEER="${SOAK_DOWNLOAD_PEER:-}"
SOAK_DOWNLOAD_PEERS="${SOAK_DOWNLOAD_PEERS:-}"
SOAK_WAIT_READY_MS="${SOAK_WAIT_READY_MS:-120000}"
SOAK_WAIT_OFFER_MS="${SOAK_WAIT_OFFER_MS:-15000}"
SOAK_DOWNLOAD_TIMEOUT_MS="${SOAK_DOWNLOAD_TIMEOUT_MS:-}"
SOAK_UNLOCK_PASSWORD="${SOAK_UNLOCK_PASSWORD:-}"
SOAK_UNLOCK_TIMEOUT_MS="${SOAK_UNLOCK_TIMEOUT_MS:-$SOAK_WAIT_READY_MS}"
SOAK_BOOT_WAIT_SEC="${SOAK_BOOT_WAIT_SEC:-}"
SOAK_HOOK_WAIT_SEC="${SOAK_HOOK_WAIT_SEC:-}"
SOAK_EXIT_AFTER_TRANSFER="${SOAK_EXIT_AFTER_TRANSFER:-$SOAK_AUTO_TRANSFER}"
SOAK_CLEAN_DEST="${SOAK_CLEAN_DEST:-1}"
SOAK_STREAM_RANGE_ENABLED="${SOAK_STREAM_RANGE_ENABLED:-}"
# Back-compat/typo guard: several historical scratchpad commands used the
# shorter SOAK_STREAM_RANGE_PARALLEL name. Treat it as an alias so a requested
# "p16" run cannot silently fall back to the app default.
SOAK_STREAM_RANGE_PARALLELISM="${SOAK_STREAM_RANGE_PARALLELISM:-${SOAK_STREAM_RANGE_PARALLEL:-}}"
SOAK_STREAM_RANGE_TARGET_BYTES="${SOAK_STREAM_RANGE_TARGET_BYTES:-}"
SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS="${SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS:-}"
SOAK_STREAM_RANGE_STALL_ABANDON_MS="${SOAK_STREAM_RANGE_STALL_ABANDON_MS:-}"
SOAK_STREAM_RANGE_HEDGE_MS="${SOAK_STREAM_RANGE_HEDGE_MS:-}"
SOAK_STREAM_RANGE_OPEN_PACE_MS="${SOAK_STREAM_RANGE_OPEN_PACE_MS:-}"
SOAK_STREAM_OPEN_WRITE_GRACE_MS="${SOAK_STREAM_OPEN_WRITE_GRACE_MS:-}"
SOAK_STREAM_REQUEST_TIMEOUT_MS="${SOAK_STREAM_REQUEST_TIMEOUT_MS:-}"
SOAK_CONTENT_REOFFER_TIMEOUT_MS="${SOAK_CONTENT_REOFFER_TIMEOUT_MS:-}"
SOAK_ONION_STREAM_DEBUG_SUMMARY_MS="${SOAK_ONION_STREAM_DEBUG_SUMMARY_MS:-}"
SOAK_ONION_STREAM_INIT_RTO_MS="${SOAK_ONION_STREAM_INIT_RTO_MS:-2000}"
SOAK_DESKTOP_ONION_STREAM_INIT_RTO_MS="${SOAK_DESKTOP_ONION_STREAM_INIT_RTO_MS:-$SOAK_ONION_STREAM_INIT_RTO_MS}"
SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS="${SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS:-$SOAK_ONION_STREAM_INIT_RTO_MS}"
SOAK_ONION_STREAM_MIN_RTO_MS="${SOAK_ONION_STREAM_MIN_RTO_MS:-1000}"
SOAK_DESKTOP_ONION_STREAM_MIN_RTO_MS="${SOAK_DESKTOP_ONION_STREAM_MIN_RTO_MS:-$SOAK_ONION_STREAM_MIN_RTO_MS}"
SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS="${SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS:-$SOAK_ONION_STREAM_MIN_RTO_MS}"
SOAK_ONION_STREAM_MAX_RTO_MS="${SOAK_ONION_STREAM_MAX_RTO_MS:-10000}"
SOAK_DESKTOP_ONION_STREAM_MAX_RTO_MS="${SOAK_DESKTOP_ONION_STREAM_MAX_RTO_MS:-$SOAK_ONION_STREAM_MAX_RTO_MS}"
SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS="${SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS:-$SOAK_ONION_STREAM_MAX_RTO_MS}"
SOAK_ONION_STREAM_MAX_RETRANSMITS="${SOAK_ONION_STREAM_MAX_RETRANSMITS:-}"
SOAK_DESKTOP_ONION_STREAM_MAX_RETRANSMITS="${SOAK_DESKTOP_ONION_STREAM_MAX_RETRANSMITS:-$SOAK_ONION_STREAM_MAX_RETRANSMITS}"
SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS="${SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS:-$SOAK_ONION_STREAM_MAX_RETRANSMITS}"
SOAK_ONION_STREAM_INIT_CWND_MSS="${SOAK_ONION_STREAM_INIT_CWND_MSS:-}"
SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS="${SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS:-$SOAK_ONION_STREAM_INIT_CWND_MSS}"
SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS="${SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS:-$SOAK_ONION_STREAM_INIT_CWND_MSS}"
SOAK_ONION_STREAM_MAX_PACING_BATCH="${SOAK_ONION_STREAM_MAX_PACING_BATCH:-}"
SOAK_DESKTOP_ONION_STREAM_MAX_PACING_BATCH="${SOAK_DESKTOP_ONION_STREAM_MAX_PACING_BATCH:-$SOAK_ONION_STREAM_MAX_PACING_BATCH}"
SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH="${SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH:-$SOAK_ONION_STREAM_MAX_PACING_BATCH}"
SOAK_ONION_STREAM_DATA_PACE_US="${SOAK_ONION_STREAM_DATA_PACE_US:-}"
SOAK_DESKTOP_ONION_STREAM_DATA_PACE_US="${SOAK_DESKTOP_ONION_STREAM_DATA_PACE_US:-$SOAK_ONION_STREAM_DATA_PACE_US}"
SOAK_ANDROID_ONION_STREAM_DATA_PACE_US="${SOAK_ANDROID_ONION_STREAM_DATA_PACE_US:-$SOAK_ONION_STREAM_DATA_PACE_US}"
SOAK_ONION_STREAM_BBR="${SOAK_ONION_STREAM_BBR:-}"
SOAK_DESKTOP_ONION_STREAM_BBR="${SOAK_DESKTOP_ONION_STREAM_BBR:-$SOAK_ONION_STREAM_BBR}"
SOAK_ANDROID_ONION_STREAM_BBR="${SOAK_ANDROID_ONION_STREAM_BBR:-$SOAK_ONION_STREAM_BBR}"
SOAK_ONION_STREAM_OUTBOUND_POOL="${SOAK_ONION_STREAM_OUTBOUND_POOL:-}"
SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL="${SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL:-$SOAK_ONION_STREAM_OUTBOUND_POOL}"
SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL="${SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL:-$SOAK_ONION_STREAM_OUTBOUND_POOL}"
SOAK_ONION_STREAM_ACK_OUTBOUND_POOL="${SOAK_ONION_STREAM_ACK_OUTBOUND_POOL:-}"
SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL="${SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL:-$SOAK_ONION_STREAM_ACK_OUTBOUND_POOL}"
SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL="${SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL:-$SOAK_ONION_STREAM_ACK_OUTBOUND_POOL}"
SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT="${SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT:-}"
SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT="${SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT:-$SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT}"
SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT="${SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT:-$SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT}"
SOAK_WAIT_ONION_REGISTRATIONS="${SOAK_WAIT_ONION_REGISTRATIONS:-0}"
SOAK_WAIT_ONION_REGISTRATIONS_MS="${SOAK_WAIT_ONION_REGISTRATIONS_MS:-60000}"
SOAK_PLAIN_FILE_STREAM="${SOAK_PLAIN_FILE_STREAM:-}"
SOAK_BULK_STREAM_TRACE="${SOAK_BULK_STREAM_TRACE:-}"
SOAK_PREFER_RENDEZVOUS="${SOAK_PREFER_RENDEZVOUS:-}"
SOAK_CONTENT_SERVE_BATCH="${SOAK_CONTENT_SERVE_BATCH:-}"
SOAK_CONTENT_PACING_MS="${SOAK_CONTENT_PACING_MS:-}"
SOAK_ANON_STREAM_READ_CONCURRENCY="${SOAK_ANON_STREAM_READ_CONCURRENCY:-}"
SOAK_ANON_STREAM_WRITE_CONCURRENCY="${SOAK_ANON_STREAM_WRITE_CONCURRENCY:-}"
SOAK_MIN_BYTES_PER_SEC="${SOAK_MIN_BYTES_PER_SEC:-}"
SOAK_MIN_MIB_PER_SEC="${SOAK_MIN_MIB_PER_SEC:-}"
SOAK_FAULT_AFTER_SEC="${SOAK_FAULT_AFTER_SEC:-}"
SOAK_FAULT_CMD="${SOAK_FAULT_CMD:-}"
SOAK_ANDROID_WIFI_FLAP_AFTER_SEC="${SOAK_ANDROID_WIFI_FLAP_AFTER_SEC:-}"
SOAK_ANDROID_WIFI_FLAP_DOWN_SEC="${SOAK_ANDROID_WIFI_FLAP_DOWN_SEC:-15}"

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

android_file_size() {
  local path="$1"
  local size
  size="$(
    adb -s "$ANDROID_SERIAL" shell \
      "if [ -e $(android_shell_quote "$path") ]; then stat -c %s $(android_shell_quote "$path") 2>/dev/null || wc -c < $(android_shell_quote "$path"); else echo 0; fi" |
      tr -d '\r' |
      tail -1
  )"
  # App-internal paths (/data/user/0/<pkg>/...) are unreadable from the plain
  # adb shell user; a debug build still exposes them through run-as.
  if [[ -z "$size" || "$size" == "0" ]]; then
    local script="if [ -e $(android_shell_quote "$path") ]; then stat -c %s $(android_shell_quote "$path") 2>/dev/null || wc -c < $(android_shell_quote "$path"); else echo 0; fi"
    size="$(
      adb -s "$ANDROID_SERIAL" shell \
        "run-as $(android_shell_quote "$APP_ID") sh -c $(android_shell_quote "$script")" 2>/dev/null |
        tr -d '\r' |
        tail -1
    )"
  fi
  echo "${size:-0}"
}

local_file_size() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo 0
    return
  fi
  stat -c '%s' "$path" 2>/dev/null ||
    stat -f '%z' "$path" 2>/dev/null ||
    echo 0
}

local_download_size() {
  local path="$1"
  local size=0
  local n
  n="$(local_file_size "$path")"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt "$size" ]]; then
    size="$n"
  fi
  local part
  while IFS= read -r part; do
    n="$(local_file_size "$part")"
    if [[ "$n" =~ ^[0-9]+$ && "$n" -gt "$size" ]]; then
      size="$n"
    fi
  done < <(compgen -G "${path}.part-*" || true)
  echo "$size"
}

auto_source_path=""
auto_dest_path=""
auto_local_source=""
auto_sha256=""
auto_expected_size=""
auto_stage_android_source=0
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

validate_nonnegative_int() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer." >&2
    exit 2
  fi
}

normalize_dart_bool() {
  local name="$1"
  local value="$2"
  case "${value,,}" in
    "")
      return
      ;;
    1|true|yes|on)
      printf true
      ;;
    0|false|no|off)
      printf false
      ;;
    *)
      echo "$name must be a boolean (1/0, true/false, yes/no, on/off)." >&2
      exit 2
      ;;
  esac
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
    auto_source_path="/data/user/0/$APP_ID/files/soak/source-$SOAK_NAME"
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
    # Scoped storage denies the raw /sdcard/Android/data path even to the app
    # itself on current Android; the app-internal files dir works for the app
    # and is monitorable via run-as (debug build).
    auto_dest_path="/data/user/0/$APP_ID/files/soak/download-$SOAK_NAME"
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
      auto_local_source="$local_source"
      auto_stage_android_source=1
    fi

    echo "generating soak payload: $SOAK_SIZE bytes -> $local_source"
    auto_sha256="$(make_payload "$SOAK_SIZE" "$local_source")"
    auto_expected_size="$SOAK_SIZE"
  elif [[ "$generate" != "0" ]]; then
    echo "SOAK_GENERATE_SOURCE must be auto, 0 or 1." >&2
    exit 2
  elif [[ "$SOAK_SENDER" == "desktop" && -f "$auto_source_path" ]]; then
    auto_expected_size="$(stat -c '%s' "$auto_source_path" 2>/dev/null || stat -f '%z' "$auto_source_path")"
    auto_sha256="$(
      shasum -a 256 "$auto_source_path" 2>/dev/null |
        awk '{print $1}'
    )"
  fi

  if [[ "$SOAK_SENDER" == "android" ]]; then
    DOWNLOAD_PATH="${DOWNLOAD_PATH:-$auto_dest_path}"
  else
    ANDROID_DOWNLOAD_PATH="${ANDROID_DOWNLOAD_PATH:-$auto_dest_path}"
  fi
  if [[ -n "$auto_expected_size" ]]; then
    EXPECT_SIZE="${EXPECT_SIZE:-$auto_expected_size}"
  fi

  if [[ "$SOAK_CLEAN_DEST" == "1" ]]; then
    if [[ "$SOAK_SENDER" == "android" ]]; then
      rm -f "$auto_dest_path"
    else
      # App-internal paths need run-as (debug build); fall back to the plain
      # shell for world-accessible destinations.
      adb -s "$ANDROID_SERIAL" shell \
        "run-as $(android_shell_quote "$APP_ID") rm -f $(android_shell_quote "$auto_dest_path")" \
        >/dev/null 2>&1 ||
        adb -s "$ANDROID_SERIAL" shell \
          "rm -f $(android_shell_quote "$auto_dest_path")" >/dev/null 2>&1 ||
        true
    fi
  fi

  echo "auto transfer: sender=$SOAK_SENDER"
  echo "auto source: $auto_source_path"
  echo "auto dest: $auto_dest_path"
  if [[ -n "$SOAK_DOWNLOAD_PEERS" ]]; then
    echo "auto download peers: $SOAK_DOWNLOAD_PEERS"
  elif [[ -n "$SOAK_DOWNLOAD_PEER" ]]; then
    echo "auto download peer: $SOAK_DOWNLOAD_PEER"
  fi
  if [[ -n "$auto_expected_size" ]]; then
    echo "auto expect size: $auto_expected_size"
  fi
}

stage_android_auto_source() {
  if [[ "$auto_stage_android_source" != "1" ]]; then
    return
  fi
  if [[ -z "$auto_local_source" ]]; then
    echo "internal error: auto_local_source is empty" >&2
    exit 2
  fi

  local safe_name
  safe_name="$(
    printf '%s' "$SOAK_NAME" |
      tr -c 'A-Za-z0-9._-' '_'
  )"
  local tmp="/data/local/tmp/xveil-soak-$safe_name"
  echo "staging soak payload inside Android app sandbox: $auto_source_path"
  adb -s "$ANDROID_SERIAL" push "$auto_local_source" "$tmp" \
    >"$LOG_DIR/adb-push-source.log"
  adb -s "$ANDROID_SERIAL" shell "chmod 644 $(android_shell_quote "$tmp")" \
    >/dev/null

  if [[ "$auto_source_path" == "/data/user/0/$APP_ID/"* ]]; then
    local rel="${auto_source_path#/data/user/0/$APP_ID/}"
    local rel_dir="${rel%/*}"
    if [[ "$rel_dir" == "$rel" ]]; then
      rel_dir="."
    fi
    local script
    script="mkdir -p $(android_shell_quote "$rel_dir") && cp $(android_shell_quote "$tmp") $(android_shell_quote "$rel") && ls -l $(android_shell_quote "$rel")"
    adb -s "$ANDROID_SERIAL" shell \
      "run-as $(android_shell_quote "$APP_ID") sh -c $(android_shell_quote "$script")" \
      >"$LOG_DIR/adb-stage-source.log"
  elif [[ "$auto_source_path" == "/data/data/$APP_ID/"* ]]; then
    local rel="${auto_source_path#/data/data/$APP_ID/}"
    local rel_dir="${rel%/*}"
    if [[ "$rel_dir" == "$rel" ]]; then
      rel_dir="."
    fi
    local script
    script="mkdir -p $(android_shell_quote "$rel_dir") && cp $(android_shell_quote "$tmp") $(android_shell_quote "$rel") && ls -l $(android_shell_quote "$rel")"
    adb -s "$ANDROID_SERIAL" shell \
      "run-as $(android_shell_quote "$APP_ID") sh -c $(android_shell_quote "$script")" \
      >"$LOG_DIR/adb-stage-source.log"
  else
    local device_dir="${auto_source_path%/*}"
    if [[ "$device_dir" == "$auto_source_path" ]]; then
      device_dir="."
    fi
    adb -s "$ANDROID_SERIAL" shell \
      "mkdir -p $(android_shell_quote "$device_dir") && cp $(android_shell_quote "$tmp") $(android_shell_quote "$auto_source_path") && ls -l $(android_shell_quote "$auto_source_path")" \
      >"$LOG_DIR/adb-stage-source.log"
  fi
}

latest_onion_registration_lines() {
  local log_file="$1"
  if [[ -f "$log_file" ]]; then
    grep -E "PINNED CIRCUIT (opened|refreshed)" "$log_file" 2>/dev/null |
      tail -5 || true
  fi
}

latest_onion_registration_count() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    echo 0
    return
  fi
  grep -E "PINNED CIRCUIT (opened|refreshed).*[0-9]+ registration\\(s\\)" "$log_file" 2>/dev/null |
    sed -E 's/.* ([0-9]+) registration\(s\).*/\1/' |
    tail -1 || true
}

wait_onion_registrations() {
  local target="$1"
  if [[ -z "$target" || "$target" == "0" ]]; then
    return
  fi
  local timeout_ms="$SOAK_WAIT_ONION_REGISTRATIONS_MS"
  local timeout_sec=$(((timeout_ms + 999) / 1000))
  if (( timeout_sec < 1 )); then
    timeout_sec=1
  fi
  local desktop_log="$LOG_DIR/desktop-flutter.log"
  local android_log="$LOG_DIR/android-flutter.log"
  echo "waiting for onion inbound registrations: >=${target} on both apps (${timeout_sec}s)"
  for _ in $(seq 1 "$timeout_sec"); do
    local desktop_count
    local android_count
    desktop_count="$(latest_onion_registration_count "$desktop_log")"
    android_count="$(latest_onion_registration_count "$android_log")"
    desktop_count="${desktop_count:-0}"
    android_count="${android_count:-0}"
    if (( desktop_count >= target && android_count >= target )); then
      echo "onion inbound registrations ready: desktop=${desktop_count} android=${android_count} target=${target}"
      return
    fi
    sleep 1
  done
  {
    echo "timed out waiting for onion inbound registrations target=$target"
    echo "desktop latest PINNED CIRCUIT lines:"
    latest_onion_registration_lines "$desktop_log"
    echo "android latest PINNED CIRCUIT lines:"
    latest_onion_registration_lines "$android_log"
  } >&2
  exit 1
}

warmup_onion_hooks() {
  if [[ "$SOAK_WAIT_ONION_REGISTRATIONS" == "0" ]]; then
    return
  fi
  if [[ "$ENABLE_DEBUG_HOOK" != "1" ]]; then
    echo "SOAK_WAIT_ONION_REGISTRATIONS requires ENABLE_DEBUG_HOOK=1." >&2
    exit 2
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "SOAK_WAIT_ONION_REGISTRATIONS requires curl." >&2
    exit 2
  fi
  echo "warming onion stream hubs through debug hooks..."
  curl -fsS "http://127.0.0.1:$DESKTOP_HOOK_PORT/warmup_onion" \
    >"$LOG_DIR/desktop-warmup-onion.json"
  curl -fsS "http://127.0.0.1:$ANDROID_HOST_HOOK_PORT/warmup_onion" \
    >"$LOG_DIR/android-warmup-onion.json"
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
validate_nonnegative_int SOAK_FAULT_AFTER_SEC "$SOAK_FAULT_AFTER_SEC"
validate_nonnegative_int SOAK_ANDROID_WIFI_FLAP_AFTER_SEC "$SOAK_ANDROID_WIFI_FLAP_AFTER_SEC"
validate_nonnegative_int SOAK_ANDROID_WIFI_FLAP_DOWN_SEC "$SOAK_ANDROID_WIFI_FLAP_DOWN_SEC"
validate_nonnegative_int SOAK_STREAM_RANGE_PARALLELISM "$SOAK_STREAM_RANGE_PARALLELISM"
validate_nonnegative_int SOAK_WAIT_READY_MS "$SOAK_WAIT_READY_MS"
validate_nonnegative_int SOAK_WAIT_OFFER_MS "$SOAK_WAIT_OFFER_MS"
validate_nonnegative_int SOAK_DOWNLOAD_TIMEOUT_MS "$SOAK_DOWNLOAD_TIMEOUT_MS"
validate_nonnegative_int SOAK_UNLOCK_TIMEOUT_MS "$SOAK_UNLOCK_TIMEOUT_MS"
validate_nonnegative_int SOAK_BOOT_WAIT_SEC "$SOAK_BOOT_WAIT_SEC"
validate_nonnegative_int SOAK_HOOK_WAIT_SEC "$SOAK_HOOK_WAIT_SEC"
validate_nonnegative_int SOAK_CONTENT_SERVE_BATCH "$SOAK_CONTENT_SERVE_BATCH"
validate_nonnegative_int SOAK_CONTENT_PACING_MS "$SOAK_CONTENT_PACING_MS"
validate_nonnegative_int SOAK_ANON_STREAM_READ_CONCURRENCY "$SOAK_ANON_STREAM_READ_CONCURRENCY"
validate_nonnegative_int SOAK_ANON_STREAM_WRITE_CONCURRENCY "$SOAK_ANON_STREAM_WRITE_CONCURRENCY"
validate_nonnegative_int SOAK_STREAM_RANGE_TARGET_BYTES "$SOAK_STREAM_RANGE_TARGET_BYTES"
validate_nonnegative_int SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS "$SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS"
validate_nonnegative_int SOAK_STREAM_RANGE_STALL_ABANDON_MS "$SOAK_STREAM_RANGE_STALL_ABANDON_MS"
validate_nonnegative_int SOAK_STREAM_RANGE_HEDGE_MS "$SOAK_STREAM_RANGE_HEDGE_MS"
validate_nonnegative_int SOAK_STREAM_RANGE_OPEN_PACE_MS "$SOAK_STREAM_RANGE_OPEN_PACE_MS"
validate_nonnegative_int SOAK_STREAM_OPEN_WRITE_GRACE_MS "$SOAK_STREAM_OPEN_WRITE_GRACE_MS"
validate_nonnegative_int SOAK_STREAM_REQUEST_TIMEOUT_MS "$SOAK_STREAM_REQUEST_TIMEOUT_MS"
validate_nonnegative_int SOAK_CONTENT_REOFFER_TIMEOUT_MS "$SOAK_CONTENT_REOFFER_TIMEOUT_MS"
validate_nonnegative_int SOAK_ONION_STREAM_DEBUG_SUMMARY_MS "$SOAK_ONION_STREAM_DEBUG_SUMMARY_MS"
validate_nonnegative_int SOAK_ONION_STREAM_INIT_RTO_MS "$SOAK_ONION_STREAM_INIT_RTO_MS"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_INIT_RTO_MS "$SOAK_DESKTOP_ONION_STREAM_INIT_RTO_MS"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS "$SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS"
validate_nonnegative_int SOAK_ONION_STREAM_MIN_RTO_MS "$SOAK_ONION_STREAM_MIN_RTO_MS"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_MIN_RTO_MS "$SOAK_DESKTOP_ONION_STREAM_MIN_RTO_MS"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS "$SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS"
validate_nonnegative_int SOAK_ONION_STREAM_MAX_RTO_MS "$SOAK_ONION_STREAM_MAX_RTO_MS"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_MAX_RTO_MS "$SOAK_DESKTOP_ONION_STREAM_MAX_RTO_MS"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS "$SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS"
validate_nonnegative_int SOAK_ONION_STREAM_MAX_RETRANSMITS "$SOAK_ONION_STREAM_MAX_RETRANSMITS"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_MAX_RETRANSMITS "$SOAK_DESKTOP_ONION_STREAM_MAX_RETRANSMITS"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS "$SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS"
validate_nonnegative_int SOAK_ONION_STREAM_INIT_CWND_MSS "$SOAK_ONION_STREAM_INIT_CWND_MSS"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS "$SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS "$SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS"
validate_nonnegative_int SOAK_ONION_STREAM_MAX_PACING_BATCH "$SOAK_ONION_STREAM_MAX_PACING_BATCH"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_MAX_PACING_BATCH "$SOAK_DESKTOP_ONION_STREAM_MAX_PACING_BATCH"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH "$SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH"
validate_nonnegative_int SOAK_ONION_STREAM_DATA_PACE_US "$SOAK_ONION_STREAM_DATA_PACE_US"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_DATA_PACE_US "$SOAK_DESKTOP_ONION_STREAM_DATA_PACE_US"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_DATA_PACE_US "$SOAK_ANDROID_ONION_STREAM_DATA_PACE_US"
validate_nonnegative_int SOAK_ONION_STREAM_BBR "$SOAK_ONION_STREAM_BBR"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_BBR "$SOAK_DESKTOP_ONION_STREAM_BBR"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_BBR "$SOAK_ANDROID_ONION_STREAM_BBR"
validate_nonnegative_int SOAK_ONION_STREAM_OUTBOUND_POOL "$SOAK_ONION_STREAM_OUTBOUND_POOL"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL "$SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL "$SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL"
validate_nonnegative_int SOAK_ONION_STREAM_ACK_OUTBOUND_POOL "$SOAK_ONION_STREAM_ACK_OUTBOUND_POOL"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL "$SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL "$SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL"
validate_nonnegative_int SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT "$SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT"
validate_nonnegative_int SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT "$SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT"
validate_nonnegative_int SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT "$SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT"
validate_nonnegative_int SOAK_WAIT_ONION_REGISTRATIONS "$SOAK_WAIT_ONION_REGISTRATIONS"
validate_nonnegative_int SOAK_WAIT_ONION_REGISTRATIONS_MS "$SOAK_WAIT_ONION_REGISTRATIONS_MS"
if [[ "$SOAK_AUTO_TRANSFER" == "1" && -z "$SOAK_PLAIN_FILE_STREAM" ]]; then
  # The real speed path is reliable stream/range pull. Keep the app default
  # conservative, but make the soak harness exercise the path it is meant to
  # validate unless a caller explicitly asks for the legacy chunk/datagram path.
  SOAK_PLAIN_FILE_STREAM=true
fi
SOAK_STREAM_RANGE_ENABLED="$(normalize_dart_bool SOAK_STREAM_RANGE_ENABLED "$SOAK_STREAM_RANGE_ENABLED")"
SOAK_PLAIN_FILE_STREAM="$(normalize_dart_bool SOAK_PLAIN_FILE_STREAM "$SOAK_PLAIN_FILE_STREAM")"
SOAK_BULK_STREAM_TRACE="$(normalize_dart_bool SOAK_BULK_STREAM_TRACE "$SOAK_BULK_STREAM_TRACE")"
if [[ -z "$SOAK_BOOT_WAIT_SEC" ]]; then
  SOAK_BOOT_WAIT_SEC=$(((SOAK_WAIT_READY_MS + 999) / 1000))
fi
if [[ -z "$SOAK_HOOK_WAIT_SEC" ]]; then
  SOAK_HOOK_WAIT_SEC=$(((SOAK_WAIT_READY_MS + 999) / 1000))
fi
if (( SOAK_BOOT_WAIT_SEC < 90 )); then
  SOAK_BOOT_WAIT_SEC=90
fi
if (( SOAK_HOOK_WAIT_SEC < 90 )); then
  SOAK_HOOK_WAIT_SEC=90
fi
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
echo "build native: $SOAK_BUILD_NATIVE"
echo "debug hook: $ENABLE_DEBUG_HOOK"
if [[ "$ENABLE_DEBUG_HOOK" == "1" ]]; then
  echo "desktop hook: http://127.0.0.1:$DESKTOP_HOOK_PORT"
  echo "android hook: http://127.0.0.1:$ANDROID_HOST_HOOK_PORT -> device:$ANDROID_HOOK_PORT"
fi
if [[ -n "$min_bytes_per_sec" ]]; then
  echo "minimum average throughput: $min_bytes_per_sec B/s"
fi
if [[ -n "$SOAK_STREAM_RANGE_PARALLELISM" ]]; then
  echo "stream range parallelism: $SOAK_STREAM_RANGE_PARALLELISM"
fi
if [[ -n "$SOAK_STREAM_RANGE_ENABLED" ]]; then
  echo "stream range enabled: $SOAK_STREAM_RANGE_ENABLED"
fi
echo "wait receiver offer: ${SOAK_WAIT_OFFER_MS}ms"
if [[ -n "$SOAK_DOWNLOAD_TIMEOUT_MS" ]]; then
  echo "download timeout: ${SOAK_DOWNLOAD_TIMEOUT_MS}ms"
fi
if [[ -n "$SOAK_STREAM_RANGE_TARGET_BYTES" ]]; then
  echo "stream range target bytes: $SOAK_STREAM_RANGE_TARGET_BYTES"
fi
if [[ -n "$SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS" ]]; then
  echo "stream range payload idle: ${SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS}ms"
fi
if [[ -n "$SOAK_STREAM_RANGE_OPEN_PACE_MS" ]]; then
  echo "stream range open pace: ${SOAK_STREAM_RANGE_OPEN_PACE_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_OUTBOUND_POOL" ]]; then
  echo "onion stream outbound pool: $SOAK_ONION_STREAM_OUTBOUND_POOL"
fi
if [[ -n "$SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL" || -n "$SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL" ]]; then
  echo "onion stream outbound pool by side: desktop=${SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL:-default} android=${SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL:-default}"
fi
if [[ -n "$SOAK_ONION_STREAM_ACK_OUTBOUND_POOL" ]]; then
  echo "onion stream ACK outbound pool: $SOAK_ONION_STREAM_ACK_OUTBOUND_POOL"
fi
if [[ -n "$SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL" || -n "$SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL" ]]; then
  echo "onion stream ACK outbound pool by side: desktop=${SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL:-default} android=${SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL:-default}"
fi
if [[ -n "$SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT" ]]; then
  echo "onion stream bulk route active limit: $SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT"
fi
if [[ -n "$SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT" || -n "$SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT" ]]; then
  echo "onion stream bulk route active limit by side: desktop=${SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT:-default} android=${SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT:-default}"
fi
if [[ -n "$SOAK_ONION_STREAM_INIT_CWND_MSS" ]]; then
  echo "onion stream initial cwnd: ${SOAK_ONION_STREAM_INIT_CWND_MSS} MSS"
fi
if [[ -n "$SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS" || -n "$SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS" ]]; then
  echo "onion stream initial cwnd by side: desktop=${SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS:-default} android=${SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS:-default}"
fi
if [[ "$SOAK_WAIT_ONION_REGISTRATIONS" != "0" ]]; then
  echo "wait onion registrations: ${SOAK_WAIT_ONION_REGISTRATIONS} (${SOAK_WAIT_ONION_REGISTRATIONS_MS}ms)"
fi
if [[ -n "$SOAK_STREAM_OPEN_WRITE_GRACE_MS" ]]; then
  echo "stream open/write grace: ${SOAK_STREAM_OPEN_WRITE_GRACE_MS}ms"
fi
if [[ -n "$SOAK_STREAM_REQUEST_TIMEOUT_MS" ]]; then
  echo "stream request timeout: ${SOAK_STREAM_REQUEST_TIMEOUT_MS}ms"
fi
if [[ -n "$SOAK_CONTENT_REOFFER_TIMEOUT_MS" ]]; then
  echo "content reoffer timeout: ${SOAK_CONTENT_REOFFER_TIMEOUT_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_DEBUG_SUMMARY_MS" ]]; then
  echo "onion stream debug summary: ${SOAK_ONION_STREAM_DEBUG_SUMMARY_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_INIT_RTO_MS" ]]; then
  echo "onion stream init RTO: ${SOAK_ONION_STREAM_INIT_RTO_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_MIN_RTO_MS" ]]; then
  echo "onion stream min RTO: ${SOAK_ONION_STREAM_MIN_RTO_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_MAX_RTO_MS" ]]; then
  echo "onion stream max RTO: ${SOAK_ONION_STREAM_MAX_RTO_MS}ms"
fi
if [[ -n "$SOAK_ONION_STREAM_MAX_RETRANSMITS" ]]; then
  echo "onion stream max retransmits: $SOAK_ONION_STREAM_MAX_RETRANSMITS"
fi
if [[ -n "$SOAK_PLAIN_FILE_STREAM" ]]; then
  echo "plain file stream: $SOAK_PLAIN_FILE_STREAM"
fi
if [[ -n "$SOAK_BULK_STREAM_TRACE" ]]; then
  echo "bulk stream trace: $SOAK_BULK_STREAM_TRACE"
fi
if [[ -n "$SOAK_PREFER_RENDEZVOUS" ]]; then
  echo "prefer rendezvous: $SOAK_PREFER_RENDEZVOUS"
fi
if [[ -n "$SOAK_CONTENT_SERVE_BATCH" ]]; then
  echo "content serve batch: $SOAK_CONTENT_SERVE_BATCH"
fi
if [[ -n "$SOAK_CONTENT_PACING_MS" ]]; then
  echo "content pacing: ${SOAK_CONTENT_PACING_MS}ms"
fi
if [[ -n "$SOAK_ANON_STREAM_READ_CONCURRENCY" ]]; then
  echo "anon stream read concurrency: $SOAK_ANON_STREAM_READ_CONCURRENCY"
fi
if [[ -n "$SOAK_ANON_STREAM_WRITE_CONCURRENCY" ]]; then
  echo "anon stream write concurrency: $SOAK_ANON_STREAM_WRITE_CONCURRENCY"
fi
if [[ -n "$SOAK_UNLOCK_PASSWORD" ]]; then
  echo "debug hook unlock: enabled"
fi
echo "app boot wait: ${SOAK_BOOT_WAIT_SEC}s"
echo "debug hook wait: ${SOAK_HOOK_WAIT_SEC}s"
if [[ -n "$SOAK_FAULT_CMD" || -n "$SOAK_ANDROID_WIFI_FLAP_AFTER_SEC" ]]; then
  echo "fault injection: enabled"
fi

if [[ "$KILL_OLD" == "1" ]]; then
  adb -s "$ANDROID_SERIAL" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  pkill -f "build/macos/Build/Products/Debug/xveil.app" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*-d macos" >/dev/null 2>&1 || true
  pkill -f "flutter_tools.snapshot run.*$ANDROID_SERIAL" >/dev/null 2>&1 || true
  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill "$pid" >/dev/null 2>&1 || true
    done < <(lsof -tiTCP:"$DESKTOP_HOOK_PORT" -sTCP:LISTEN 2>/dev/null || true)
    sleep 1
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -9 "$pid" >/dev/null 2>&1 || true
    done < <(lsof -tiTCP:"$DESKTOP_HOOK_PORT" -sTCP:LISTEN 2>/dev/null || true)
  fi
fi

if [[ "$SOAK_BUILD_NATIVE" == "1" ]]; then
  echo "building $SOAK_NATIVE_PROFILE native libraries..."
  build_native_args=()
  if [[ "$SOAK_NATIVE_PROFILE" == "release" ]]; then
    build_native_args+=(--release)
  fi
  "$ROOT/scripts/build-native.sh" ${build_native_args[@]+"${build_native_args[@]}"} \
    >"$LOG_DIR/build-native.log" 2>&1
elif [[ "$SOAK_BUILD_NATIVE" != "0" ]]; then
  echo "SOAK_BUILD_NATIVE must be 0 or 1." >&2
  exit 2
fi

for native_lib in "$DESKTOP_DYLIB" "$HV_DYLIB"; do
  if [[ ! -f "$native_lib" ]]; then
    echo "missing native library: $native_lib" >&2
    echo "Run scripts/build-native.sh or set SOAK_BUILD_NATIVE=1." >&2
    exit 1
  fi
done

adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_circuit "$VEIL_CIRCUIT_MODE"
if [[ -n "$SOAK_PREFER_RENDEZVOUS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_prefer_rendezvous "$SOAK_PREFER_RENDEZVOUS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_prefer_rendezvous none
fi
if [[ -n "$SOAK_ONION_STREAM_DEBUG_SUMMARY_MS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_debug_summary_ms "$SOAK_ONION_STREAM_DEBUG_SUMMARY_MS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_debug_summary_ms 0
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_init_rto_ms "$SOAK_ANDROID_ONION_STREAM_INIT_RTO_MS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_init_rto_ms 2000
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_min_rto_ms "$SOAK_ANDROID_ONION_STREAM_MIN_RTO_MS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_min_rto_ms 1000
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_rto_ms "$SOAK_ANDROID_ONION_STREAM_MAX_RTO_MS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_rto_ms 10000
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_retransmits "$SOAK_ANDROID_ONION_STREAM_MAX_RETRANSMITS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_retransmits 5
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_init_cwnd_mss "$SOAK_ANDROID_ONION_STREAM_INIT_CWND_MSS"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_init_cwnd_mss 64
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_outbound_pool "$SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_outbound_pool 3
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_ack_outbound_pool "$SOAK_ANDROID_ONION_STREAM_ACK_OUTBOUND_POOL"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_ack_outbound_pool 1
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_bulk_route_active_limit "$SOAK_ANDROID_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_bulk_route_active_limit 2
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_pacing_batch "$SOAK_ANDROID_ONION_STREAM_MAX_PACING_BATCH"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_max_pacing_batch 256
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_DATA_PACE_US" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_data_pace_us "$SOAK_ANDROID_ONION_STREAM_DATA_PACE_US"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_data_pace_us 50
fi
if [[ -n "$SOAK_ANDROID_ONION_STREAM_BBR" ]]; then
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_bbr "$SOAK_ANDROID_ONION_STREAM_BBR"
else
  adb -s "$ANDROID_SERIAL" shell setprop debug.veil.onion_stream_bbr 1
fi
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
if [[ -n "$SOAK_STREAM_RANGE_PARALLELISM" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_PARALLELISM=$SOAK_STREAM_RANGE_PARALLELISM"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_PARALLELISM=$SOAK_STREAM_RANGE_PARALLELISM"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_ENABLED" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_ENABLED=$SOAK_STREAM_RANGE_ENABLED"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_ENABLED=$SOAK_STREAM_RANGE_ENABLED"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_TARGET_BYTES" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_TARGET_BYTES=$SOAK_STREAM_RANGE_TARGET_BYTES"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_TARGET_BYTES=$SOAK_STREAM_RANGE_TARGET_BYTES"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_PAYLOAD_IDLE_MS=$SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_PAYLOAD_IDLE_MS=$SOAK_STREAM_RANGE_PAYLOAD_IDLE_MS"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_STALL_ABANDON_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_STALL_ABANDON_MS=$SOAK_STREAM_RANGE_STALL_ABANDON_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_STALL_ABANDON_MS=$SOAK_STREAM_RANGE_STALL_ABANDON_MS"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_HEDGE_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_HEDGE_MS=$SOAK_STREAM_RANGE_HEDGE_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_HEDGE_MS=$SOAK_STREAM_RANGE_HEDGE_MS"
  )
fi
if [[ -n "$SOAK_STREAM_RANGE_OPEN_PACE_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_OPEN_PACE_MS=$SOAK_STREAM_RANGE_OPEN_PACE_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_RANGE_OPEN_PACE_MS=$SOAK_STREAM_RANGE_OPEN_PACE_MS"
  )
fi
if [[ -n "$SOAK_STREAM_OPEN_WRITE_GRACE_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_OPEN_WRITE_GRACE_MS=$SOAK_STREAM_OPEN_WRITE_GRACE_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_OPEN_WRITE_GRACE_MS=$SOAK_STREAM_OPEN_WRITE_GRACE_MS"
  )
fi
if [[ -n "$SOAK_STREAM_REQUEST_TIMEOUT_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_STREAM_REQUEST_TIMEOUT_MS=$SOAK_STREAM_REQUEST_TIMEOUT_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_STREAM_REQUEST_TIMEOUT_MS=$SOAK_STREAM_REQUEST_TIMEOUT_MS"
  )
fi
if [[ -n "$SOAK_CONTENT_REOFFER_TIMEOUT_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_CONTENT_REOFFER_TIMEOUT_MS=$SOAK_CONTENT_REOFFER_TIMEOUT_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_CONTENT_REOFFER_TIMEOUT_MS=$SOAK_CONTENT_REOFFER_TIMEOUT_MS"
  )
fi
if [[ -n "$SOAK_PLAIN_FILE_STREAM" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_PLAIN_FILE_STREAM=$SOAK_PLAIN_FILE_STREAM"
  )
  android_defines+=(
    "--dart-define=XVEIL_PLAIN_FILE_STREAM=$SOAK_PLAIN_FILE_STREAM"
  )
fi
if [[ -n "$SOAK_BULK_STREAM_TRACE" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_BULK_STREAM_TRACE=$SOAK_BULK_STREAM_TRACE"
  )
  android_defines+=(
    "--dart-define=XVEIL_BULK_STREAM_TRACE=$SOAK_BULK_STREAM_TRACE"
  )
fi
if [[ -n "$SOAK_CONTENT_SERVE_BATCH" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_CONTENT_SERVE_BATCH=$SOAK_CONTENT_SERVE_BATCH"
  )
  android_defines+=(
    "--dart-define=XVEIL_CONTENT_SERVE_BATCH=$SOAK_CONTENT_SERVE_BATCH"
  )
fi
if [[ -n "$SOAK_CONTENT_PACING_MS" ]]; then
  desktop_defines+=(
    "--dart-define=XVEIL_CONTENT_PACING_MS=$SOAK_CONTENT_PACING_MS"
  )
  android_defines+=(
    "--dart-define=XVEIL_CONTENT_PACING_MS=$SOAK_CONTENT_PACING_MS"
  )
fi
if [[ -n "$SOAK_ANON_STREAM_READ_CONCURRENCY" ]]; then
  desktop_defines+=(
    "--dart-define=VEIL_ANON_STREAM_READ_CONCURRENCY=$SOAK_ANON_STREAM_READ_CONCURRENCY"
  )
  android_defines+=(
    "--dart-define=VEIL_ANON_STREAM_READ_CONCURRENCY=$SOAK_ANON_STREAM_READ_CONCURRENCY"
  )
fi
if [[ -n "$SOAK_ANON_STREAM_WRITE_CONCURRENCY" ]]; then
  desktop_defines+=(
    "--dart-define=VEIL_ANON_STREAM_WRITE_CONCURRENCY=$SOAK_ANON_STREAM_WRITE_CONCURRENCY"
  )
  android_defines+=(
    "--dart-define=VEIL_ANON_STREAM_WRITE_CONCURRENCY=$SOAK_ANON_STREAM_WRITE_CONCURRENCY"
  )
fi

(
  cd "$ROOT"
  VEIL_FFI_DYLIB="$DESKTOP_DYLIB" \
    XVEIL_HV_DYLIB="$HV_DYLIB" \
    VEIL_ONION_STREAM_CIRCUIT="$VEIL_CIRCUIT_MODE" \
    VEIL_ONION_STREAM_PREFER_RENDEZVOUS="$SOAK_PREFER_RENDEZVOUS" \
    VEIL_ONION_STREAM_DEBUG_SUMMARY_MS="$SOAK_ONION_STREAM_DEBUG_SUMMARY_MS" \
    VEIL_ONION_STREAM_CIRCUIT_INIT_RTO_MS="$SOAK_DESKTOP_ONION_STREAM_INIT_RTO_MS" \
    VEIL_ONION_STREAM_CIRCUIT_MIN_RTO_MS="$SOAK_DESKTOP_ONION_STREAM_MIN_RTO_MS" \
    VEIL_ONION_STREAM_CIRCUIT_MAX_RTO_MS="$SOAK_DESKTOP_ONION_STREAM_MAX_RTO_MS" \
    VEIL_ONION_STREAM_CIRCUIT_MAX_RETRANSMITS="$SOAK_DESKTOP_ONION_STREAM_MAX_RETRANSMITS" \
    VEIL_ONION_STREAM_CIRCUIT_INIT_CWND_MSS="$SOAK_DESKTOP_ONION_STREAM_INIT_CWND_MSS" \
    VEIL_ONION_STREAM_CIRCUIT_OUTBOUND_POOL="$SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL" \
    VEIL_ONION_STREAM_CIRCUIT_ACK_OUTBOUND_POOL="$SOAK_DESKTOP_ONION_STREAM_ACK_OUTBOUND_POOL" \
    VEIL_ONION_STREAM_CIRCUIT_BULK_ROUTE_ACTIVE_LIMIT="$SOAK_DESKTOP_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT" \
    VEIL_ONION_STREAM_CIRCUIT_MAX_PACING_BATCH="$SOAK_DESKTOP_ONION_STREAM_MAX_PACING_BATCH" \
    VEIL_ONION_STREAM_CIRCUIT_DATA_PACE_US="$SOAK_DESKTOP_ONION_STREAM_DATA_PACE_US" \
    VEIL_ONION_STREAM_CIRCUIT_BBR="$SOAK_DESKTOP_ONION_STREAM_BBR" \
    flutter run --no-pub -d macos --debug "${desktop_defines[@]}"
) >"$LOG_DIR/desktop-flutter.log" 2>&1 &
pids+=("$!")

(
  cd "$ROOT"
  flutter run --no-pub -d "$ANDROID_SERIAL" --debug "${android_defines[@]}"
) >"$LOG_DIR/android-flutter.log" 2>&1 &
pids+=("$!")

if [[ "$ENABLE_DEBUG_HOOK" == "1" ]]; then
  echo "waiting for apps to expose debug hooks..."
else
  echo "waiting for apps to boot..."
  for _ in $(seq 1 "$SOAK_BOOT_WAIT_SEC"); do
    if grep -q "onion-stream" "$LOG_DIR/desktop-flutter.log" 2>/dev/null &&
       grep -q "onion-stream" "$LOG_DIR/android-flutter.log" 2>/dev/null; then
      break
    fi
    sleep 1
  done
fi

if [[ "$ENABLE_DEBUG_HOOK" == "1" ]] && command -v curl >/dev/null 2>&1; then
  echo "waiting for debug hooks..."
  desktop_ok=0
  android_ok=0
  for _ in $(seq 1 "$SOAK_HOOK_WAIT_SEC"); do
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
  if [[ "$desktop_ok" != "1" || "$android_ok" != "1" ]]; then
    {
      echo "debug hooks did not become ready within ${SOAK_HOOK_WAIT_SEC}s"
      echo "desktop_hook_ready=$desktop_ok android_hook_ready=$android_ok"
      echo "desktop health:"
      cat "$LOG_DIR/desktop-hook-health.json" 2>/dev/null || true
      echo
      echo "android health:"
      cat "$LOG_DIR/android-hook-health.json" 2>/dev/null || true
      echo
      echo "desktop flutter tail:"
      tail -80 "$LOG_DIR/desktop-flutter.log" 2>/dev/null || true
      echo
      echo "android flutter tail:"
      tail -120 "$LOG_DIR/android-flutter.log" 2>/dev/null || true
    } >&2
    exit 1
  fi
fi

if [[ -n "$SOAK_UNLOCK_PASSWORD" ]]; then
  if [[ "$ENABLE_DEBUG_HOOK" != "1" ]]; then
    echo "SOAK_UNLOCK_PASSWORD requires ENABLE_DEBUG_HOOK=1." >&2
    exit 2
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "SOAK_UNLOCK_PASSWORD requires curl." >&2
    exit 2
  fi
  echo "unlocking apps through debug hooks..."
  printf '%s' "$SOAK_UNLOCK_PASSWORD" |
    curl -fsS -X POST --data-binary @- \
      "http://127.0.0.1:$DESKTOP_HOOK_PORT/unlock?timeout_ms=$SOAK_UNLOCK_TIMEOUT_MS" \
      >"$LOG_DIR/desktop-unlock.json"
  printf '%s' "$SOAK_UNLOCK_PASSWORD" |
    curl -fsS -X POST --data-binary @- \
      "http://127.0.0.1:$ANDROID_HOST_HOOK_PORT/unlock?timeout_ms=$SOAK_UNLOCK_TIMEOUT_MS" \
      >"$LOG_DIR/android-unlock.json"
fi

warmup_onion_hooks
wait_onion_registrations "$SOAK_WAIT_ONION_REGISTRATIONS"
stage_android_auto_source

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
        WAIT_OFFER_MS="$SOAK_WAIT_OFFER_MS" \
        DOWNLOAD_TIMEOUT_MS="${SOAK_DOWNLOAD_TIMEOUT_MS:-1800000}" \
        DOWNLOAD_PEER="$SOAK_DOWNLOAD_PEER" \
        DOWNLOAD_PEERS="$SOAK_DOWNLOAD_PEERS" \
        ANDROID_SERIAL="$ANDROID_SERIAL" \
        APP_ID="$APP_ID" \
        CLEAN_DEST=0 \
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

fault_pid=""
fault_status_file="$LOG_DIR/fault.status"
fault_started_file="$LOG_DIR/fault.started"
if [[ -n "$SOAK_FAULT_CMD" || -n "$SOAK_ANDROID_WIFI_FLAP_AFTER_SEC" ]]; then
  fault_delay="$SOAK_FAULT_AFTER_SEC"
  if [[ -z "$fault_delay" && -n "$SOAK_ANDROID_WIFI_FLAP_AFTER_SEC" ]]; then
    fault_delay="$SOAK_ANDROID_WIFI_FLAP_AFTER_SEC"
  fi
  fault_delay="${fault_delay:-0}"
  echo "scheduling fault injection after ${fault_delay}s"
  (
    set +e
    sleep "$fault_delay"
    date +%s >"$fault_started_file"
    if [[ -n "$SOAK_FAULT_CMD" ]]; then
      echo "running SOAK_FAULT_CMD"
      if cd "$ROOT"; then
        bash -lc "$SOAK_FAULT_CMD"
        status=$?
      else
        status=1
      fi
    else
      echo "running Android Wi-Fi flap: down ${SOAK_ANDROID_WIFI_FLAP_DOWN_SEC}s"
      wifi_disabled=0
      trap 'if [[ "$wifi_disabled" == "1" ]]; then adb -s "$ANDROID_SERIAL" shell svc wifi enable >/dev/null 2>&1 || true; fi' EXIT
      adb -s "$ANDROID_SERIAL" shell svc wifi disable
      off_status=$?
      if [[ "$off_status" == "0" ]]; then
        wifi_disabled=1
      fi
      sleep "$SOAK_ANDROID_WIFI_FLAP_DOWN_SEC"
      adb -s "$ANDROID_SERIAL" shell svc wifi enable
      on_status=$?
      wifi_disabled=0
      if [[ "$off_status" == "0" && "$on_status" == "0" ]]; then
        status=0
      else
        status=1
      fi
    fi
    echo "$status" >"$fault_status_file"
    exit "$status"
  ) >"$LOG_DIR/fault.log" 2>&1 &
  fault_pid="$!"
  pids+=("$fault_pid")
fi

check_fault_status() {
  if [[ -n "$fault_pid" && -f "$fault_status_file" ]]; then
    fault_status="$(cat "$fault_status_file")"
    if [[ "$fault_status" != "0" ]]; then
      echo "fault injection failed with status $fault_status; see $LOG_DIR/fault.log" >&2
      exit "$fault_status"
    fi
  fi
}

echo "monitoring; Ctrl-C to stop"
echo "time,size,delta_bytes,bytes_per_sec,phone_pid,desktop_errors,android_errors" \
  >"$LOG_DIR/progress.csv"

last_size=0
last_ts="$(date +%s)"
monitor_start_ts="$last_ts"
final_size=0
first_byte_ts=""
last_byte_ts=""
expected_size_notice=0
while true; do
  now="$(date +%s)"
  size=0
  if [[ -n "$DOWNLOAD_PATH" ]]; then
    size="$(local_download_size "$DOWNLOAD_PATH")"
  elif [[ -n "$ANDROID_DOWNLOAD_PATH" ]]; then
    size="$(android_file_size "$ANDROID_DOWNLOAD_PATH")"
    if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]]; then
      size=0
    fi
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
    {
      grep -E "stream-pull failed|payload idle|driver gone|onion stream reset|Connection reset" \
        "$LOG_DIR/desktop-flutter.log" 2>/dev/null || true
    } |
      tail -1 |
      tr ',' ';'
  )"
  android_errors="$(
    {
      grep -E "stream-serve failed|driver gone|onion stream reset|Connection reset" \
        "$LOG_DIR/android-flutter.log" "$LOG_DIR/android-logcat.log" 2>/dev/null || true
    } |
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

  trigger_done=0
  if [[ -n "$trigger_pid" && -f "$trigger_status_file" ]]; then
    trigger_status="$(cat "$trigger_status_file")"
    if [[ "$trigger_status" != "0" ]]; then
      echo "trigger failed with status $trigger_status; see $LOG_DIR" >&2
      exit "$trigger_status"
    fi
    trigger_done=1
    if [[ "$SOAK_EXIT_AFTER_TRANSFER" == "1" && -z "$EXPECT_SIZE" ]]; then
      echo "trigger completed"
      break
    fi
  fi
  if [[ -n "$EXPECT_SIZE" && "$size" -ge "$EXPECT_SIZE" ]]; then
    if [[ -n "$trigger_pid" && "$trigger_done" != "1" ]]; then
      if [[ "$expected_size_notice" != "1" ]]; then
        echo "expected size reached: $size >= $EXPECT_SIZE; waiting for trigger verification"
        expected_size_notice=1
      fi
    else
      echo "expected size reached: $size >= $EXPECT_SIZE"
      break
    fi
  fi
  check_fault_status

  last_size="$size"
  last_ts="$now"
  sleep "$MONITOR_INTERVAL"
done
check_fault_status

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
check_fault_status

fault_summary_status="none"
if [[ -n "$fault_pid" ]]; then
  if [[ ! -f "$fault_started_file" ]]; then
    fault_summary_status="not_started"
    echo "fault injection did not start before transfer completed; increase SOAK_SIZE or lower the fault delay" >&2
    exit 1
  fi
  fault_wait_status=0
  wait "$fault_pid" || fault_wait_status=$?
  fault_summary_status="$fault_wait_status"
  if [[ -f "$fault_status_file" ]]; then
    fault_summary_status="$(cat "$fault_status_file")"
  fi
  if [[ "$fault_summary_status" != "0" ]]; then
    echo "fault injection failed with status $fault_summary_status; see $LOG_DIR/fault.log" >&2
    exit "$fault_summary_status"
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
  echo "fault_status=$fault_summary_status"
} | tee "$LOG_DIR/summary.txt"
cat >"$LOG_DIR/summary.json" <<JSON
{"final_size_bytes":$final_size,"wall_elapsed_sec":$wall_elapsed_sec,"active_elapsed_sec":$active_elapsed_sec,"avg_bytes_per_sec":$avg_bps,"avg_mib_per_sec":$avg_mib_s,"wall_avg_bytes_per_sec":$wall_avg_bps,"wall_avg_mib_per_sec":$wall_avg_mib_s,"expected_size_bytes":${EXPECT_SIZE:-null},"min_bytes_per_sec":${min_bytes_per_sec:-null},"fault_status":"$fault_summary_status"}
JSON

if [[ -n "$min_bytes_per_sec" && "$avg_bps" -lt "$min_bytes_per_sec" ]]; then
  echo "average throughput below minimum: $avg_bps < $min_bytes_per_sec B/s" >&2
  exit 1
fi
