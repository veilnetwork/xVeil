#!/usr/bin/env bash
# Bring up TWO local veil nodes correctly peered for real overlay chat, so the
# app (or the env-gated tests) can exercise the real transport end to end.
#
# Encodes the verified topology: each node has its OWN listener and the two
# mutually `bootstrap join` each other's invite, so the session forms in the
# direction veil's directional dedup accepts (otherwise the link drops with EOF
# and every send hits route.discovery.miss).
#
# Idempotent: reuses configs under .dev-nodes/ (mining a 24-bit identity takes
# minutes on first run). Prints the env to launch the app in real mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/third_party/veil/target/debug/veil-cli"
NODES="$ROOT/.dev-nodes"

case "$(uname -s)" in
  Darwin) DYLIB="$ROOT/third_party/veil/target/debug/libveilclient_ffi.dylib" ;;
  Linux)  DYLIB="$ROOT/third_party/veil/target/debug/libveilclient_ffi.so" ;;
  *)      DYLIB="$ROOT/third_party/veil/target/debug/veilclient_ffi.dll" ;;
esac

[[ -x "$BIN" ]] || { echo "Build veil-cli first: scripts/build-native.sh" >&2; exit 1; }

ensure_node() { # <dir> <listen_port>
  local dir="$1" port="$2" cfg="$1/config.toml"
  mkdir -p "$dir"
  if [[ ! -f "$cfg" ]]; then
    echo "==> Mining identity for $(basename "$dir") (minutes)…"
    "$BIN" config init "$cfg" >/dev/null
    "$BIN" -c "$cfg" listen add "tcp://127.0.0.1:$port" >/dev/null
  fi
  "$BIN" -c "$cfg" config set ipc.enabled true >/dev/null 2>&1
  "$BIN" -c "$cfg" config set ipc.socket_uri "unix://$dir/app.sock" >/dev/null 2>&1
}

invite_of() {
  "$BIN" -c "$1/config.toml" bootstrap invite 2>/dev/null \
    | grep -oE 'veil:bootstrap\S+' | head -1
}

ensure_node "$NODES/a" 9100
ensure_node "$NODES/b" 9101

# Mutual bootstrap (idempotent / deduped by veil).
"$BIN" -c "$NODES/a/config.toml" bootstrap join --uri "$(invite_of "$NODES/b")" >/dev/null 2>&1 || true
"$BIN" -c "$NODES/b/config.toml" bootstrap join --uri "$(invite_of "$NODES/a")" >/dev/null 2>&1 || true

pkill -f "veil-cli.*node run" 2>/dev/null || true
sleep 1
"$BIN" -c "$NODES/a/config.toml" node run --foreground >"$NODES/a/node.log" 2>&1 &
"$BIN" -c "$NODES/b/config.toml" node run --foreground >"$NODES/b/node.log" 2>&1 &

for _ in $(seq 1 30); do
  [[ -S "$NODES/a/app.sock" && -S "$NODES/b/app.sock" ]] && break
  sleep 1
done
[[ -S "$NODES/a/app.sock" && -S "$NODES/b/app.sock" ]] || { echo "nodes failed to expose app sockets" >&2; exit 1; }

cat <<EOF

Two nodes are running and peered.

Run the env-gated A->B test:
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_TEST_SOCK_A="$NODES/a/app.sock" XVEIL_TEST_SOCK_B="$NODES/b/app.sock" \\
  flutter test test/native/veil_two_node_live_test.dart

Or launch the app in REAL mode against node A:
  VEIL_FFI_DYLIB="$DYLIB" \\
  XVEIL_VEIL_CLI="$BIN" XVEIL_VEIL_CONFIG="$NODES/a/config.toml" \\
  flutter run -d macos

Stop the nodes:  pkill -f 'veil-cli.*node run'
EOF
