#!/usr/bin/env bash
# Local onion harness for the receiver-side mailbox FETCH (STEP 2c) — reuses the
# PROVEN dev-onion-pair topology (the one that lands a live receive-anonymous
# round-trip) so the authenticated-with-reply FETCH path actually routes.
#
# 4 nodes, all pairwise peered, FRESH provision + dht wipe each run:
#   R  (relay+target): receive_anonymous + onion_service + [mailbox] enabled
#                      — stores a blob for F and SERVES the network FETCH.
#   F  (fetcher):      receive_anonymous + onion_service — retrieves its mailbox.
#   M1, M2 (relays):   relay_capable — the rendezvous + onion-middle hops.
#
# Both R and F are receive-anonymous (R must accept F's authenticated FETCH; F
# must receive the reply), so BOTH register with a rendezvous relay (M1/M2). Two
# relays are required: select_onion_relay_path forces hop_count>=2 and excludes
# the rendezvous relay from the middle-hop pool. The cold nodes warm connected
# relays' directory entries (FIND_VALUE) before building circuits (veil cold-start
# fix, already in the binary).
#
# Build first:  cargo build -p veil-cli -p veilclient-ffi --release --features allow-empty-seeds
#   scripts/dev-mailbox-onion.sh   # stop: pkill -f 'veil-cli.*node run'
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${VEIL_CLI:-$ROOT/third_party/veil/target/release/veil-cli}"
NODES="$ROOT/.dev-mailbox-onion"
MINT_DIFFICULTY="${VEIL_MINT_DIFFICULTY:-24}"
[[ -x "$BIN" ]] || { echo "build veil-cli first (see header)" >&2; exit 1; }

mk_node() { # <dir> <port>
  local dir="$1" port="$2"
  local cfg="$dir/config.toml"
  rm -rf "$dir"; mkdir -p "$dir"
  # NOTE: sequential (not backgrounded) — parallel PoW mints raced and some
  # config.toml's were missing at peering time. ~19s/node × 4 = ~80s.
  "$BIN" config init -f -d "$MINT_DIFFICULTY" "$cfg" >/dev/null 2>&1 || true
  [[ -f "$cfg" ]] || { echo "config init failed for $dir" >&2; exit 1; }
  "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1 || true
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null | grep -oE 'veil:bootstrap\S+' | head -1
}

echo "==> provisioning R(relay+mailbox) + F(fetcher) + M1 + M2 (mint @ $MINT_DIFFICULTY, sequential ~80s)…"
mk_node "$NODES/relay" 9210
mk_node "$NODES/fetch" 9211
mk_node "$NODES/mid1"  9212
mk_node "$NODES/mid2"  9213

peers=(relay fetch mid1 mid2)
for a in "${peers[@]}"; do
  for b in "${peers[@]}"; do
    [[ "$a" == "$b" ]] && continue
    "$BIN" -c "$NODES/$a/config.toml" bootstrap join --uri "$(invite_of "$NODES/$b")" >/dev/null 2>&1 || true
  done
done

# R: receive-anonymous target that also hosts the mailbox relay (stores+serves
# FETCH). NOT relay_capable — it is a destination, and keeping it out of the
# relay pool stops F from picking it as F's own rendezvous relay.
printf '\n[anonymity]\nreceive_anonymous = true\nonion_service = true\n' >> "$NODES/relay/config.toml"
printf '\n[mailbox]\nenabled = true\nrequire_capability_token = false\n' >> "$NODES/relay/config.toml"
# F: plain receive-anonymous fetcher.
printf '\n[anonymity]\nreceive_anonymous = true\nonion_service = true\n' >> "$NODES/fetch/config.toml"
# M1/M2: the rendezvous + onion-middle relays.
printf '\n[anonymity]\nrelay_capable = true\n' >> "$NODES/mid1/config.toml"
printf '\n[anonymity]\nrelay_capable = true\n' >> "$NODES/mid2/config.toml"

pkill -f "veil-cli.*node run" 2>/dev/null || true; sleep 1
rm -f "$NODES"/*/dht_values.json 2>/dev/null || true
for n in "${peers[@]}"; do
  RUST_LOG="info,veil_node_runtime=debug,veil_mailbox=debug" \
    "$BIN" -c "$NODES/$n/config.toml" node run --foreground >"$NODES/$n/node.log" 2>&1 &
done

echo "==> nodes up; waiting up to 150s for BOTH R and F to register a rendezvous relay…"
ok=0
for _ in $(seq 1 150); do
  if grep -qs "registered with rendezvous relay" "$NODES/relay/node.log" \
     && grep -qs "registered with rendezvous relay" "$NODES/fetch/node.log"; then
    ok=1; break
  fi
  sleep 1
done
[[ "$ok" == 1 ]] && echo "✅ R and F both registered a rendezvous relay" \
                 || echo "⚠️  not both registered within 150s (test may still retry)"

R_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/relay/node.log" | head -1 | cut -d= -f2)"
F_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/fetch/node.log" | head -1 | cut -d= -f2)"
echo "R(relay)=${R_ID:0:8}  F(fetcher)=${F_ID:0:8}  + mid1 mid2"

DYLIB="$ROOT/third_party/veil/target/release/libveilclient_ffi.dylib"
echo
echo "=== STEP 2c — F retrieves its mailbox from R over the onion: ==="
cat <<EOF
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_TEST_SOCK_SENDER="$NODES/fetch/app.sock" \\
  XVEIL_TEST_SOCK_RELAY="$NODES/relay/app.sock" \\
  XVEIL_SEND_NODE_ID="$F_ID" \\
  XVEIL_RELAY_NODE_ID="$R_ID" \\
  flutter test test/native/mailbox_fetch_live_test.dart
EOF
echo
echo "logs: $NODES/*/node.log   stop: pkill -f 'veil-cli.*node run'"
