#!/usr/bin/env bash
# Local onion-rendezvous round-trip harness — 4 nodes, full log visibility.
#
# Brings up two relay-capable nodes (R rendezvous + M onion middle hop), an
# anonymous receiver B, and a sender S; peers every pair; and checks that B's
# AUTO rendezvous registration LANDS on a relay (R or M logs
# `anonymity.relay_chain.register.ok`) — STAGE 1. Then prints the command to run
# the STAGE 2 sender->B onion round-trip test (test/native/onion_roundtrip_live_test.dart),
# which proves the full path S -> M(middle) -> R(rendezvous) -> B end to end.
#
# A second relay (M) is required: select_onion_relay_path forces hop_count>=2 and
# excludes the rendezvous relay from the middle-hop pool, so with a single relay
# the sender finds 0 middle candidates. The cold sender warms both relays'
# relay-directory entries (FIND_VALUE) before building the circuit.
#
# Needs a veil-cli built from the current submodule (cold-start FIND_VALUE +
# send-confirmation fixes):
#   cargo build -p veil-cli --release --features allow-empty-seeds
#
#   scripts/dev-onion-pair.sh
#   # stop:  pkill -f 'veil-cli.*node run'
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${VEIL_CLI:-$ROOT/third_party/veil/target/release/veil-cli}"
NODES="$ROOT/.dev-onion"
[[ -x "$BIN" ]] || { echo "build veil-cli first (see header)" >&2; exit 1; }

# Identity PoW difficulty. The node REQUIRES >=24 leading zero bits (it rejects
# a weaker identity at config-validation), so 24 is the floor. ~19s/node to mint
# — the four nodes are minted in PARALLEL below to keep the wall-clock to one.
MINT_DIFFICULTY="${VEIL_MINT_DIFFICULTY:-24}"

mk_node() { # <dir> <port>
  local dir="$1" port="$2"
  local cfg="$dir/config.toml"
  # Provision FRESH every run. Reusing a persisted config leaks stale state
  # across runs — e.g. a leftover [anonymity] block on the sender turned S into
  # a relay/receiver, so B sometimes picked the SENDER as its rendezvous relay
  # and delivery failed non-deterministically. A clean config each run makes the
  # harness deterministic (the only cost is a fast low-difficulty identity mint).
  rm -rf "$dir"
  mkdir -p "$dir"
  "$BIN" config init -f -d "$MINT_DIFFICULTY" "$cfg" >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null 2>&1 || true
  # ipc.* ARE whitelisted config-set keys; anonymity.* are NOT, so those are
  # appended as raw TOML below (after bootstrap-join, the last write wins).
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1 || true
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null \
    | grep -oE 'veil:bootstrap\S+' | head -1
}

echo "==> provisioning R (rendezvous relay) + M (middle relay) + B (anon receiver) + S (sender)…"
echo "    (minting 4 identities at PoW difficulty $MINT_DIFFICULTY in parallel — ~20s)"
mk_node "$NODES/relay" 9200 &   # R: rendezvous relay
mk_node "$NODES/mid"   9203 &   # M: a SECOND relay_capable node, the onion middle hop
mk_node "$NODES/recv"  9201 &   # B: anonymous receiver
mk_node "$NODES/send"  9202 &   # S: a plain node (the sender ≠ the relay)
wait

# Mutual bootstrap join (directional-dedup topology — every node has a listener).
# select_onion_relay_path forces hop_count>=2, so the circuit is
#   S -> M(middle) -> R(rendezvous) -> B(recipient).
# The middle hop must be a relay_capable node DISTINCT from the rendezvous relay R
# (R is excluded from the candidate pool), so M is required — with only R the
# sender finds 0 middle candidates (InsufficientRelayCandidates{have:0}). Every
# pair is peered so the DHT is fully connected and S can warm both R's and M's
# relay-directory entries.
peers=(relay mid recv send)
for a in "${peers[@]}"; do
  for b in "${peers[@]}"; do
    [[ "$a" == "$b" ]] && continue
    "$BIN" -c "$NODES/$a/config.toml" bootstrap join --uri "$(invite_of "$NODES/$b")" >/dev/null 2>&1 || true
  done
done

# Append [anonymity] (config set has no anonymity keys; node run just parses the
# TOML). Configs are freshly minted each run, so a plain append is correct — no
# stale block to guard against. S deliberately gets NO [anonymity]: it is a plain
# sender, never a relay or receiver (else B could pick it as its rendezvous relay).
printf '\n[anonymity]\nrelay_capable = true\n' >> "$NODES/relay/config.toml"
printf '\n[anonymity]\nrelay_capable = true\n' >> "$NODES/mid/config.toml"
printf '\n[anonymity]\nreceive_anonymous = true\nonion_service = true\n' >> "$NODES/recv/config.toml"

pkill -f "veil-cli.*node run" 2>/dev/null || true; sleep 1
# Wipe persisted DHT values between runs. The recipient mints a fresh per-process
# rendezvous auth_cookie each start, so a stale ad persisted from a prior run
# (carrying the OLD cookie) would short-circuit the sender's get_local lookup and
# make the relay drop the introduce with `cookie_unknown`. Relay-directory + ad
# entries are republished on startup, so wiping costs nothing.
rm -f "$NODES"/*/dht_values.json 2>/dev/null || true
"$BIN" -c "$NODES/relay/config.toml" node run --foreground >"$NODES/relay/node.log" 2>&1 &
"$BIN" -c "$NODES/mid/config.toml"   node run --foreground >"$NODES/mid/node.log" 2>&1 &
"$BIN" -c "$NODES/recv/config.toml"  node run --foreground >"$NODES/recv/node.log" 2>&1 &
"$BIN" -c "$NODES/send/config.toml"  node run --foreground >"$NODES/send/node.log" 2>&1 &

echo "==> nodes up; waiting up to 150s for B to register a rendezvous relay…"
# B's pick_rendezvous_relay may land on EITHER relay-capable node (R or M), so
# accept register.ok on either — the round-trip works regardless of which one B
# binds (the other becomes the onion middle hop).
ok=0
for _ in $(seq 1 150); do
  if grep -qs "relay_chain.register.ok" "$NODES/relay/node.log" "$NODES/mid/node.log"; then
    ok=1; break
  fi
  sleep 1
done

echo
if [[ "$ok" == 1 ]]; then
  echo "✅ a relay logged register.ok — RegisterRendezvous LANDED (live delivery works locally)"
else
  echo "❌ no register.ok on R or M within 150s — gap reproduced locally"
fi
echo "=== R + M (relays) rendezvous/relay_chain events ==="
grep -iE "relay_chain|rendezvous|register|relay_directory" "$NODES/relay/node.log" "$NODES/mid/node.log" 2>/dev/null | tail -12 || true
echo "=== B (receiver) rendezvous-recipient events ==="
grep -iE "rendezvous_recipient|registered with|send_failed|no_relay|relay_directory" "$NODES/recv/node.log" 2>/dev/null | tail -12 || true
echo
B_NODE_ID="$(grep -oE 'node_id=[0-9a-f]{64}' "$NODES/recv/node.log" 2>/dev/null | head -1 | cut -d= -f2)"
DYLIB="$ROOT/third_party/veil/target/release/libveilclient_ffi.dylib"
echo "=== STAGE 2 — run the sender->B onion round-trip (S sends, R forwards): ==="
cat <<EOF
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_TEST_SOCK_SENDER="$NODES/send/app.sock" \\
  XVEIL_TEST_SOCK_RECV="$NODES/recv/app.sock" \\
  XVEIL_RECV_NODE_ID="$B_NODE_ID" \\
  flutter test test/native/onion_roundtrip_live_test.dart
EOF
echo
echo "logs: $NODES/{relay,recv,send}/node.log   stop: pkill -f 'veil-cli.*node run'"
