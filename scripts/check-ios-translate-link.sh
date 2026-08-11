#!/usr/bin/env bash
# Does the built iOS app actually offer the translation entry points?
#
#   scripts/check-ios-translate-link.sh [path/to/Runner.app]
#
# Not "was the archive built" and not "did the build succeed" — both were true
# while the shipped binary offered nothing. The Dart side resolves these out of
# the PROCESS IMAGE, so the only question that matters is whether the finished
# app exports them, and the only way to answer it is to look inside the app.
#
# Two ways it went wrong here, neither visible from the build's exit code:
#
#   * The archive folded libprotobuf.a AND libprotobuf-lite.a, which carry the
#     same object files. Nothing noticed until `-force_load` pulled in every
#     member: 838 duplicate symbols. Without force_load the linker picks one
#     and the archive looks fine.
#   * DEBUG splits the app into a launcher and Runner.debug.dylib, and a dylib
#     exports by default — so debug worked. RELEASE is one executable, which
#     exports nothing by default, and STRIP_STYLE=all removes the rest. The
#     engine was inside the binary and unreachable. Translation would have
#     worked all through development and vanished in the build that ships.
#
# So this checks the EXPORT TRIE, which is what dlsym reads, and it checks both
# places the code can live.
set -euo pipefail

app="${1:-build/ios/iphoneos/Runner.app}"
[ -d "$app" ] || { echo "no app bundle at $app — build one first" >&2; exit 1; }

name="$(basename "$app" .app)"
main="$app/$name"
[ -f "$main" ] || { echo "::error::$app has no $name executable" >&2; exit 2; }

# The debug split: the real code is in the sibling dylib, and that is a normal
# arrangement rather than a failure — so both are asked, and finding the
# symbols in either is an answer.
candidates=("$main")
[ -f "$app/$name.debug.dylib" ] && candidates+=("$app/$name.debug.dylib")

wanted="$(grep -oE 'veil_translate[a-z_]*\(' native/translate/veil_translate.h \
  | tr -d '(' | sort -u)"
[ -n "$wanted" ] || { echo "::error::no entry points found in veil_translate.h" >&2; exit 2; }

found=""
for binary in "${candidates[@]}"; do
  # dyld_info reads the export trie — the same table dlsym consults. `nm` reads
  # the static symbol table, which a release build strips entirely: it would
  # report "missing" for a binary that works, and that is a false alarm nobody
  # would trust twice.
  exported="$(dyld_info -exports "$binary" 2>/dev/null \
    | awk '{print $NF}' | sed 's/^_//' | { grep '^veil_translate' || true; } | sort -u)"
  if [ -n "$exported" ]; then found="$exported"; break; fi
done

if [ -z "$found" ]; then
  echo "::error::$app exports no veil_translate_* entry point."
  echo "  The archive can be present, linked and inside the binary and still be"
  echo "  unreachable: an executable exports nothing by default. Check that"
  echo "  ios/Flutter/TranslateLink.xcconfig exists and carries both -force_load"
  echo "  and -Wl,-export_dynamic."
  exit 1
fi

missing="$(comm -23 <(echo "$wanted") <(echo "$found"))"
if [ -n "$missing" ]; then
  echo "::error::the app is missing entry points the Dart side looks up:"
  echo "$missing" | sed 's/^/  /'
  exit 1
fi
echo "ok: $app exports $(echo "$found" | wc -l | tr -d ' ') veil_translate_* entry points"
