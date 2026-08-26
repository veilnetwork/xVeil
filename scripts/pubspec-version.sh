#!/usr/bin/env bash
# Print the app version from pubspec.yaml, the way every build must read it.
#
# One place, because there were three: builder.py, build-macos-adhoc.sh and
# (not at all) build-ios-simulator.sh. What each of them produces ends up in
# `--dart-define=XVEIL_VERSION=`, and that value is not decoration: a build
# that cannot name itself reports "dev", which ties an error report to nothing
# and makes the update check refuse to offer anything — it will not order a
# version it cannot parse.
#
# So the value is validated rather than trusted. `version: "1.2.3+4"  # bump`
# is valid YAML and used to come through with the quotes and the comment
# attached, which is a version string nothing can compare.
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
file="$root/pubspec.yaml"

raw="$(sed -n 's/^version:[[:space:]]*//p' "$file" | head -1)"
# Strip, in order: an inline comment, surrounding quotes, trailing blanks.
raw="${raw%%#*}"
raw="$(printf '%s' "$raw" | sed 's/[[:space:]]*$//')"
raw="${raw#\"}"; raw="${raw%\"}"
raw="${raw#\'}"; raw="${raw%\'}"

if ! printf '%s' "$raw" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$'; then
  echo "pubspec.yaml version is not a version: '$raw'" >&2
  exit 1
fi
printf '%s' "$raw"
