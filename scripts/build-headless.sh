#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/headless}"

"$ROOT/scripts/build-native.sh" --release
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

echo "Headless bundle: $OUT/bundle"
