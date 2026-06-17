#!/usr/bin/env bash
# Local offline-mailbox harness — STEP 2a: the NETWORK PUT path over the
# anonymous onion.
#
# 4-node mesh (S sender, B receiver/relay, M1/M2 filler relays) so the daemon's
# `send_anonymous_direct` egress can build a multi-hop source-routed circuit
# (a 2-node pair has no intermediates to route through). S deposits a
# `MailboxPutPayload` to B's built-in mailbox app-service
# (MAILBOX_APP_ID, PUT_ENDPOINT=1) using the EXISTING send_anonymous_direct
# FFI — no new emit code. B's `veil.mailbox.v1` service stores the blob.
# Validates the network deposit + receive-service path end-to-end before any
# emit/productization or signed-protocol change is built.
#
# All nodes are `anonymity.relay_capable = true` (needed to serve as onion hops
# AND so B reports its relay X25519 pubkey, the seal target for the deposit).
# Relay node runs with veil_node_runtime=debug so the "veil-mailbox: PUT stored"
# line (a debug log) surfaces for the test's assertion.
#
# Build first:
#   cargo build -p veil-cli -p veilclient-ffi --release --features allow-empty-seeds
# Then:
#   scripts/dev-mailbox-mesh.sh
#   # stop:  pkill -f 'veil-cli.*node run'
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${VEIL_CLI:-$ROOT/third_party/veil/target/release/veil-cli}"
NODES="$ROOT/.dev-mailbox-mesh"
MINT_DIFFICULTY="${VEIL_MINT_DIFFICULTY:-24}"
[[ -x "$BIN" ]] || { echo "build veil-cli first (see header)" >&2; exit 1; }

NAMES=(send recv m1 m2)
PORTS=(9300 9301 9302 9303)

mk_node() { # <dir> <port>
  local dir="$1" port="$2" cfg
  cfg="$dir/config.toml"
  rm -rf "$dir"; mkdir -p "$dir"
  "$BIN" config init -f -d "$MINT_DIFFICULTY" "$cfg" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1 || true
  # relay_capable: serve as an onion hop + publish relay X25519 (the deposit
  # seal target). Not a `config set` key — appended as raw TOML (like mailbox).
  # require_capability_token=false — STEP 2a tests deposit+store, not the
  # anti-spam gate.
  grep -q '^\[anonymity\]' "$cfg" || \
    printf '\n[anonymity]\nrelay_capable = true\n' >> "$cfg"
  grep -q '^\[mailbox\]' "$cfg" || \
    printf '\n[mailbox]\nenabled = true\nrequire_capability_token = false\n' >> "$cfg"
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null | grep -oE 'veil:bootstrap\S+' | head -1
}

echo "==> provisioning ${#NAMES[@]}-node mesh (mint @ $MINT_DIFFICULTY, parallel ~20-30s)…"
for i in "${!NAMES[@]}"; do mk_node "$NODES/${NAMES[$i]}" "${PORTS[$i]}" & done
wait

# Full mesh: every node bootstrap-joins every other node's invite.
INVITES=()
for n in "${NAMES[@]}"; do INVITES+=("$(invite_of "$NODES/$n")"); done
for i in "${!NAMES[@]}"; do
  for j in "${!NAMES[@]}"; do
    [[ "$i" == "$j" ]] && continue
    "$BIN" -c "$NODES/${NAMES[$i]}/config.toml" bootstrap join \
      --uri "${INVITES[$j]}" >/dev/null 2>&1 || true
  done
done

pkill -f "veil-cli.*node run" 2>/dev/null || true; sleep 1
for n in "${NAMES[@]}"; do rm -f "$NODES/$n/dht_values.json" 2>/dev/null || true; done
for n in "${NAMES[@]}"; do
  RUST_LOG="info,veil_node_runtime=debug,veil_mailbox=debug" \
    "$BIN" -c "$NODES/$n/config.toml" node run --foreground >"$NODES/$n/node.log" 2>&1 &
done

echo "==> mesh up; giving the DHT ~30s to connect + form circuits…"
for _ in $(seq 1 30); do
  grep -qs "mlkem_cert_published" "$NODES/send/node.log" "$NODES/recv/node.log" && break
  sleep 1
done

S_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/send/node.log" 2>/dev/null | head -1 | cut -d= -f2)"
B_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/recv/node.log" 2>/dev/null | head -1 | cut -d= -f2)"
echo "S=${S_ID:0:8}  B(relay)=${B_ID:0:8}  + m1 m2 (onion hops)"
grep -hiE "mlkem_cert_published|node.start" "$NODES"/{send,recv}/node.log 2>/dev/null | tail -4 || true

DYLIB="$ROOT/third_party/veil/target/release/libveilclient_ffi.dylib"
echo
echo "=== STEP 2a — S deposits a mailbox PUT to B over the anonymous onion: ==="
cat <<EOF
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_TEST_SOCK_SENDER="$NODES/send/app.sock" \\
  XVEIL_TEST_SOCK_RELAY="$NODES/recv/app.sock" \\
  XVEIL_RELAY_NODE_ID="$B_ID" \\
  XVEIL_RELAY_LOG="$NODES/recv/node.log" \\
  flutter test test/native/mailbox_put_remote_live_test.dart
EOF
echo
echo "logs: $NODES/*/node.log   stop: pkill -f 'veil-cli.*node run'"
