#!/usr/bin/env bash
set -euo pipefail

# Drive one real app-to-app file transfer through the debug soak hooks.
#
# Launch both apps first with scripts/onion_stream_soak.sh (or manually with
# --dart-define=XVEIL_DEBUG_HOOK=true). Then run, for the usual phone->desktop
# test:
#
#   SENDER=android \
#   SOURCE_PATH=/sdcard/Android/data/network.veil.xveil/files/soak.bin \
#   DEST_PATH="$HOME/Downloads/xveil-soak.bin" \
#   scripts/onion-stream-hook-transfer.sh
#
# SOURCE_PATH is local to the sender app process. DEST_PATH is local to the
# receiver app process. For Android paths, prefer the app-specific external
# files dir so scoped storage allows access.

DESKTOP_HOOK="${DESKTOP_HOOK:-http://127.0.0.1:38765}"
ANDROID_HOOK="${ANDROID_HOOK:-http://127.0.0.1:38766}"
SENDER="${SENDER:-android}" # android|desktop
SOURCE_PATH="${SOURCE_PATH:-}"
DEST_PATH="${DEST_PATH:-}"
NAME="${NAME:-}"
WAIT_READY_MS="${WAIT_READY_MS:-120000}"
EXPECT_SHA256="${EXPECT_SHA256:-}"

if [[ -z "$SOURCE_PATH" || -z "$DEST_PATH" ]]; then
  echo "Set SOURCE_PATH and DEST_PATH." >&2
  exit 2
fi
if [[ "$SENDER" != "android" && "$SENDER" != "desktop" ]]; then
  echo "SENDER must be android or desktop." >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for JSON/URL handling." >&2
  exit 2
fi

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

json_get() {
  python3 -c '
import json
import sys

obj = json.load(sys.stdin)
cur = obj
for part in sys.argv[1].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(1)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("")
else:
    print(cur)
' "$1"
}

require_ok() {
  local body="$1"
  local context="$2"
  local ok
  ok="$(printf '%s' "$body" | json_get ok || true)"
  if [[ "$ok" != "true" ]]; then
    echo "$context failed:" >&2
    echo "$body" >&2
    exit 1
  fi
}

get_json() {
  local url="$1"
  curl -fsS "$url"
}

echo "waiting for desktop hook: $DESKTOP_HOOK"
desktop_ready="$(get_json "$DESKTOP_HOOK/wait_ready?timeout_ms=$WAIT_READY_MS")"
require_ok "$desktop_ready" "desktop wait_ready"

echo "waiting for android hook: $ANDROID_HOOK"
android_ready="$(get_json "$ANDROID_HOOK/wait_ready?timeout_ms=$WAIT_READY_MS")"
require_ok "$android_ready" "android wait_ready"

desktop_identity="$(get_json "$DESKTOP_HOOK/identity")"
android_identity="$(get_json "$ANDROID_HOOK/identity")"
require_ok "$desktop_identity" "desktop identity"
require_ok "$android_identity" "android identity"

desktop_node="$(printf '%s' "$desktop_identity" | json_get identity.nodeId)"
android_node="$(printf '%s' "$android_identity" | json_get identity.nodeId)"

if [[ "$SENDER" == "android" ]]; then
  sender_hook="$ANDROID_HOOK"
  sender_peer="$desktop_node"
  receiver_hook="$DESKTOP_HOOK"
  receiver_peer="$android_node"
else
  sender_hook="$DESKTOP_HOOK"
  sender_peer="$android_node"
  receiver_hook="$ANDROID_HOOK"
  receiver_peer="$desktop_node"
fi

send_url="$sender_hook/send_file?peer=$(urlencode "$sender_peer")&path=$(urlencode "$SOURCE_PATH")"
if [[ -n "$NAME" ]]; then
  send_url="$send_url&name=$(urlencode "$NAME")"
fi

echo "sending $SOURCE_PATH via $SENDER"
send_body="$(get_json "$send_url")"
require_ok "$send_body" "send_file"
cid="$(printf '%s' "$send_body" | json_get contentId)"
size="$(printf '%s' "$send_body" | json_get size)"

echo "contentId: $cid"
echo "advertised size: $size"

download_url="$receiver_hook/download_file?peer=$(urlencode "$receiver_peer")&cid=$(urlencode "$cid")&path=$(urlencode "$DEST_PATH")"
echo "downloading to $DEST_PATH"
download_body="$(get_json "$download_url")"
require_ok "$download_body" "download_file"
downloaded_size="$(printf '%s' "$download_body" | json_get size || true)"
echo "downloaded size: ${downloaded_size:-unknown}"

if [[ "$SENDER" == "android" && -f "$DEST_PATH" ]]; then
  actual_size="$(stat -f '%z' "$DEST_PATH" 2>/dev/null || stat -c '%s' "$DEST_PATH")"
  if [[ "$actual_size" != "$size" ]]; then
    echo "size mismatch: expected $size, got $actual_size" >&2
    exit 1
  fi
  if [[ -n "$EXPECT_SHA256" ]]; then
    actual_sha="$(
      shasum -a 256 "$DEST_PATH" 2>/dev/null |
        awk '{print $1}'
    )"
    if [[ "$actual_sha" != "$EXPECT_SHA256" ]]; then
      echo "sha256 mismatch: expected $EXPECT_SHA256, got $actual_sha" >&2
      exit 1
    fi
  fi
fi

echo "ok: hook transfer completed"
