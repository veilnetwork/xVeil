#!/usr/bin/env bash
# Every veil_media_* symbol the Dart layer looks up must be exported by the
# engine it will dlopen.
#
#   scripts/check-media-symbols.sh <libveil_media.so>
#
# This exists because the engine is a prebuilt delivered out of band, and a
# stale one is invisible: it links, it bundles, the app starts, and the first
# call fails at dlsym. The copy in use before this check was twelve commits
# behind — 78 exported against 87 looked up, short capture-device selection,
# screen sharing and the RTP size cap.
#
# Two symbols are undefined on purpose. libveilclient_ffi.so defines
# veil_media_send_datagram and veil_media_set_recv_callback, and the loader
# resolves them from the sibling library via DT_NEEDED plus an $ORIGIN rpath.
set -euo pipefail

so="${1:?usage: $0 <libveil_media.so>}"
[ -r "$so" ] || { echo "no engine at $so" >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

nm -D --defined-only "$so" | awk '{print $NF}' | grep '^veil_media_' | sort -u > "$tmp/exported"

# Quoted names only: the bare identifier also appears inside the library name
# `libveil_media_camera_stub.so`, and a check that invents a missing symbol is
# a check someone switches off.
grep -rhoE "'veil_media_[a-z0-9_]+'" \
  "$root/lib" "$root/third_party/veil/flutter/veil_media/lib" \
  | tr -d "'" | sort -u > "$tmp/wanted"

printf 'veil_media_send_datagram\nveil_media_set_recv_callback\n' > "$tmp/sibling"

comm -13 "$tmp/exported" "$tmp/wanted" | comm -23 - "$tmp/sibling" > "$tmp/missing"

echo "exported: $(wc -l < "$tmp/exported" | tr -d ' ')   looked up by Dart: $(wc -l < "$tmp/wanted" | tr -d ' ')"
if [ -s "$tmp/missing" ]; then
  echo "::error::the engine is missing symbols the app calls:"
  sed 's/^/  /' "$tmp/missing"
  exit 1
fi
echo "OK: nothing the app calls is missing from the engine"
