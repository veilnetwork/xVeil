#!/usr/bin/env bash
# scripts/check-workflow-pins.sh — every tool CI installs is pinned.
#
# `cargo install <tool>` takes whatever version crates.io serves at the moment
# the job runs, so two runs of the same commit can build with different tools.
# That is somebody else's code deciding what our release is made of, and it
# changes without a commit here to point at when it breaks.
#
# Two requirements, and they are separate:
#
#   --version   the tool itself is a range we chose, not "latest";
#   --locked    its OWN dependency tree comes from its lockfile rather than
#               from whatever those crates published since.
#
# A caret range rather than an exact version on purpose: a patch release of a
# linter is worth taking automatically, a major one is not.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"
  case "$text" in
    *--version*) ;;
    *) echo "::error file=$file,line=$lineno::cargo install without --version: ${text#"${text%%[![:space:]]*}"}"; fail=1 ;;
  esac
  case "$text" in
    *--locked*) ;;
    *) echo "::error file=$file,line=$lineno::cargo install without --locked: ${text#"${text%%[![:space:]]*}"}"; fail=1 ;;
  esac
done < <(grep -rn "cargo install" .github/workflows/ 2>/dev/null || true)

if [ "$fail" -ne 0 ]; then
  echo "==> a tool CI installs is unpinned; see the note at the top of this script"
  exit 1
fi
echo "==> every cargo install in .github/workflows is pinned (--version and --locked)"
