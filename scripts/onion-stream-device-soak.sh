#!/usr/bin/env bash
set -euo pipefail

# Compatibility alias for the canonical real-device soak harness.
# Accepts the newer env names and maps them to scripts/onion_stream_soak.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${ANDROID_DEVICE:-}" && -z "${ANDROID_SERIAL:-}" ]]; then
  export ANDROID_SERIAL="$ANDROID_DEVICE"
fi
if [[ -n "${WATCH_PATH:-}" && -z "${DOWNLOAD_PATH:-}" ]]; then
  export DOWNLOAD_PATH="$WATCH_PATH"
fi
if [[ -n "${OUT_DIR:-}" && -z "${LOG_DIR:-}" ]]; then
  export LOG_DIR="$OUT_DIR"
fi
if [[ -n "${POLL_SEC:-}" && -z "${MONITOR_INTERVAL:-}" ]]; then
  export MONITOR_INTERVAL="$POLL_SEC"
fi
if [[ -n "${XVEIL_SOAK_HOOK_CMD:-}" && -z "${SOAK_TRIGGER_CMD:-}" ]]; then
  export SOAK_TRIGGER_CMD="$XVEIL_SOAK_HOOK_CMD"
fi

exec "$SCRIPT_DIR/onion_stream_soak.sh" "$@"
