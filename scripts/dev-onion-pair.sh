#!/usr/bin/env bash
# Local onion-rendezvous round-trip — STAGE 1 (2 nodes, full log visibility).
#
# Brings up a relay-capable node R and an anonymous receiver B, peers them, and
# checks whether B's AUTO rendezvous registration LANDS on R — i.e. R logs
# `anonymity.relay_chain.register.ok`. This reproduces (or refutes) the testnet
# gap — recipient sends RegisterRendezvous (send_to=true) but no relay logged
# handling it — in a fully-local setup where we control + see both sides.
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

mk_node() { # <dir> <port>
  local dir="$1" port="$2"
  local cfg="$dir/config.toml"
  mkdir -p "$dir"
  if [[ ! -f "$cfg" ]]; then
    "$BIN" config init "$cfg" >/dev/null 2>&1 || true
    "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null 2>&1 || true
  fi
  # ipc.* ARE whitelisted config-set keys; anonymity.* are NOT, so those are
  # appended as raw TOML below (after bootstrap-join, the last write wins).
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1 || true
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1 || true
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null \
    | grep -oE 'veil:bootstrap\S+' | head -1
}

echo "==> provisioning R (relay_capable) + B (anonymous receiver)…"
mk_node "$NODES/relay" 9200
mk_node "$NODES/recv"  9201

# Mutual bootstrap join (directional-dedup topology — both have listeners).
"$BIN" -c "$NODES/relay/config.toml" bootstrap join --uri "$(invite_of "$NODES/recv")"  >/dev/null 2>&1 || true
"$BIN" -c "$NODES/recv/config.toml"  bootstrap join --uri "$(invite_of "$NODES/relay")" >/dev/null 2>&1 || true

# Append [anonymity] LAST (config set has no anonymity keys; node run just parses
# the TOML). Guard against double-append on re-runs.
grep -q '^\[anonymity\]' "$NODES/relay/config.toml" || printf '\n[anonymity]\nrelay_capable = true\n' >> "$NODES/relay/config.toml"
grep -q '^\[anonymity\]' "$NODES/recv/config.toml"  || printf '\n[anonymity]\nreceive_anonymous = true\nonion_service = true\n' >> "$NODES/recv/config.toml"

pkill -f "veil-cli.*node run" 2>/dev/null || true; sleep 1
"$BIN" -c "$NODES/relay/config.toml" node run --foreground >"$NODES/relay/node.log" 2>&1 &
"$BIN" -c "$NODES/recv/config.toml"  node run --foreground >"$NODES/recv/node.log" 2>&1 &

echo "==> nodes up; waiting up to 150s for B to register a rendezvous with R…"
ok=0
for _ in $(seq 1 150); do
  if grep -q "relay_chain.register.ok" "$NODES/relay/node.log" 2>/dev/null; then
    ok=1; break
  fi
  sleep 1
done

echo
if [[ "$ok" == 1 ]]; then
  echo "✅ RELAY logged register.ok — RegisterRendezvous LANDED (live delivery works locally)"
else
  echo "❌ no register.ok on the relay within 150s — gap reproduced locally"
fi
echo "=== R (relay) rendezvous/relay_chain events ==="
grep -iE "relay_chain|rendezvous|register|relay_directory" "$NODES/relay/node.log" 2>/dev/null | tail -12 || true
echo "=== B (receiver) rendezvous-recipient events ==="
grep -iE "rendezvous_recipient|registered with|send_failed|no_relay|relay_directory" "$NODES/recv/node.log" 2>/dev/null | tail -12 || true
echo
echo "logs: $NODES/{relay,recv}/node.log   stop: pkill -f 'veil-cli.*node run'"
