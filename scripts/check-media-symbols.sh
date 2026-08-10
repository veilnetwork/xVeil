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

# Two object formats, two spellings of the same question.
#
# `nm -D` is GNU and reads an ELF dynamic symbol table. Apple's nm has no `-D`
# and answers "File format has no dynamic symbol table" for a Mach-O — which
# this script then read as an EMPTY export list, i.e. as "the engine is
# missing every symbol the app calls". On a macOS host that is the platform
# being developed, checked by a gate that could not open its library and said
# so in a sentence indistinguishable from a real miss.
#
# Mach-O also prefixes C symbols with an underscore, so the name has to be
# unmangled before it can be compared with what Dart looks up.
if nm -D --defined-only "$so" >"$tmp/raw" 2>/dev/null; then
  fmt="ELF"
elif nm -gU "$so" >"$tmp/raw" 2>/dev/null; then
  fmt="Mach-O"
  sed -i '' 's/ _veil_media_/ veil_media_/' "$tmp/raw" 2>/dev/null \
    || sed -i 's/ _veil_media_/ veil_media_/' "$tmp/raw"
else
  echo "::error::cannot read a symbol table out of $so — neither \`nm -D\` " \
       "(ELF) nor \`nm -gU\` (Mach-O) could open it. This is NOT the same as " \
       "'symbols are missing', and the check refuses to report it as such." >&2
  exit 2
fi
# `|| true` because no match is an ANSWER here, not an error. Without it
# `set -e` plus `pipefail` kills the script on grep's exit 1 — silently, with
# an empty report, and before the emptiness check below can say what happened.
# That made the one case this script exists to describe ("this file is not the
# engine") indistinguishable from a crash: exit 1, no output.
awk '{print $NF}' "$tmp/raw" | { grep '^veil_media_' || true; } | sort -u > "$tmp/exported"
# An empty export list means the tool ran and found nothing, which for a
# library that is supposed to BE the engine is a broken artifact rather than a
# long list of missing names.
if [ ! -s "$tmp/exported" ]; then
  echo "::error::$so ($fmt) exports no veil_media_* symbol at all — it is not " \
       "the engine, or it was stripped." >&2
  exit 2
fi

# Quoted names only: the bare identifier also appears inside the library name
# `libveil_media_camera_stub.so`, and a check that invents a missing symbol is
# a check someone switches off.
grep -rhoE "'veil_media_[a-z0-9_]+'" \
  "$root/lib" "$root/third_party/veil/flutter/veil_media/lib" \
  | tr -d "'" | sort -u > "$tmp/wanted"

printf 'veil_media_send_datagram\nveil_media_set_recv_callback\n' > "$tmp/sibling"

comm -13 "$tmp/exported" "$tmp/wanted" | comm -23 - "$tmp/sibling" > "$tmp/missing"

echo "$fmt: exported $(wc -l < "$tmp/exported" | tr -d ' ')   looked up by Dart: $(wc -l < "$tmp/wanted" | tr -d ' ')"
if [ -s "$tmp/missing" ]; then
  echo "::error::the engine is missing symbols the app calls:"
  sed 's/^/  /' "$tmp/missing"
  exit 1
fi
echo "OK: nothing the app calls is missing from the engine"
