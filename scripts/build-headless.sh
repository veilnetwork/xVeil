#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/headless}"

"$ROOT/scripts/build-native.sh" --release --ffi-only
mkdir -p "$OUT"
(cd "$ROOT" && dart build cli --target=bin/xveil.dart --output="$OUT")

case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  Linux) EXT="so" ;;
  MINGW*|MSYS*|CYGWIN*) EXT="dll" ;;
  *) echo "unsupported host OS" >&2; exit 1 ;;
esac

mkdir -p "$OUT/bundle/lib"
cp "$ROOT/third_party/veil/target/release/libveilclient_ffi.$EXT" \
  "$OUT/bundle/lib/"
cp "$ROOT/third_party/hidden-volume/target/release/libhidden_volume_ffi.$EXT" \
  "$OUT/bundle/lib/"
cp "$ROOT/doc/HEADLESS-DAEMON.md" "$OUT/bundle/README.md"

# THE KEY THAT MAKES THE SEEDS DIALLABLE, beside the library built for them.
#
# Both deployment networks separate themselves by obfs4 PSK, so a daemon
# without it finds peers at the rendezvous and refuses every one of them —
# while printing `ready: true`. The GUI app reads this same file as a Flutter
# asset; a `dart build cli` binary has no asset bundle, so it has to arrive
# here as a file the config can point at.
#
# The network comes from the ONE rule, with the same PROFILE the native build
# above used — a bundle carrying the testnet key beside a production-seeded
# library is exactly the mirrored-constant failure veil-network.sh exists to
# prevent.
# shellcheck disable=SC2034  # read by veil-network.sh when sourced
PROFILE=release
# shellcheck source=scripts/veil-network.sh
source "$ROOT/scripts/veil-network.sh"
cp "$ROOT/assets/$XVEIL_NETWORK/obfs4_psk.b64" "$OUT/bundle/obfs4_psk.b64"

echo "Headless bundle: $OUT/bundle  (network: $XVEIL_NETWORK)"
echo "  point obfs4_psk_file at $OUT/bundle/obfs4_psk.b64 or the daemon"
echo "  will refuse every peer it finds."
