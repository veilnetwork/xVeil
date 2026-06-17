#!/usr/bin/env bash
# Local offline-mailbox harness — 2 connected nodes (S sender + B receiver),
# both mailbox.enabled, full log visibility.
#
# STEP 1 validates the seal/open CRYPTO round-trip on real nodes (the part built
# blind): S resolves B's ML-KEM cert over the DHT, seals; B resolves S's document
# and opens. The blob is handed S->B directly by the test (no relay yet — the
# put/fetch transport + the private-cookie auth gate are validated in later
# steps as they're built).
#
# Needs a veil-cli + ffi dylib built from the current submodule:
#   cargo build -p veil-cli -p veilclient-ffi --release --features allow-empty-seeds
#
#   scripts/dev-mailbox-pair.sh
#   # stop:  pkill -f 'veil-cli.*node run'
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${VEIL_CLI:-$ROOT/third_party/veil/target/release/veil-cli}"
NODES="$ROOT/.dev-mailbox"
MINT_DIFFICULTY="${VEIL_MINT_DIFFICULTY:-24}"
[[ -x "$BIN" ]] || { echo "build veil-cli first (see header)" >&2; exit 1; }

mk_node() { # <dir> <port>
  local dir="$1" port="$2" cfg
  cfg="$dir/config.toml"
  rm -rf "$dir"; mkdir -p "$dir"
  "$BIN" config init -f -d "$MINT_DIFFICULTY" "$cfg" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1 || true
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null | grep -oE 'veil:bootstrap\S+' | head -1
}

echo "==> provisioning S (sender) + B (receiver), both mailbox-enabled (mint @ $MINT_DIFFICULTY, parallel ~20s)…"
mk_node "$NODES/send" 9300 &
mk_node "$NODES/recv" 9301 &
wait

# Mutual bootstrap-join so the DHT is connected (S must resolve B's ML-KEM cert).
"$BIN" -c "$NODES/send/config.toml" bootstrap join --uri "$(invite_of "$NODES/recv")" >/dev/null 2>&1 || true
"$BIN" -c "$NODES/recv/config.toml" bootstrap join --uri "$(invite_of "$NODES/send")" >/dev/null 2>&1 || true

# Enable the mailbox relay on both (config set has no mailbox keys -> raw TOML,
# appended last). require_capability_token=false for step 1 (we test seal/open,
# not the put anti-spam gate yet).
for d in send recv; do
  grep -q '^\[mailbox\]' "$NODES/$d/config.toml" || \
    printf '\n[mailbox]\nenabled = true\nrequire_capability_token = false\n' >> "$NODES/$d/config.toml"
done

pkill -f "veil-cli.*node run" 2>/dev/null || true; sleep 1
rm -f "$NODES"/*/dht_values.json 2>/dev/null || true
"$BIN" -c "$NODES/send/config.toml" node run --foreground >"$NODES/send/node.log" 2>&1 &
"$BIN" -c "$NODES/recv/config.toml" node run --foreground >"$NODES/recv/node.log" 2>&1 &

echo "==> nodes up; giving the DHT ~25s to connect + publish ML-KEM certs…"
for _ in $(seq 1 25); do
  grep -qs "mlkem_cert_published" "$NODES/send/node.log" "$NODES/recv/node.log" && break
  sleep 1
done

S_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/send/node.log" 2>/dev/null | head -1 | cut -d= -f2)"
B_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/recv/node.log" 2>/dev/null | head -1 | cut -d= -f2)"
echo "S=${S_ID:0:8} B=${B_ID:0:8}"
grep -hiE "mlkem_cert_published|node.start" "$NODES"/{send,recv}/node.log 2>/dev/null | tail -4 || true

DYLIB="$ROOT/third_party/veil/target/release/libveilclient_ffi.dylib"
echo
echo "=== STEP 1 — run the seal(S)->open(B) crypto round-trip: ==="
cat <<EOF
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_TEST_SOCK_SENDER="$NODES/send/app.sock" \\
  XVEIL_TEST_SOCK_RECV="$NODES/recv/app.sock" \\
  XVEIL_SEND_NODE_ID="$S_ID" \\
  XVEIL_RECV_NODE_ID="$B_ID" \\
  flutter test test/native/mailbox_seal_open_live_test.dart
EOF
echo
echo "logs: $NODES/{send,recv}/node.log   stop: pkill -f 'veil-cli.*node run'"
