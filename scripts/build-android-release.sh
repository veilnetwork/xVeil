#!/usr/bin/env bash
# Build the Android release APKs for handing to testers.
#
# The work moved into builder.py so that a Windows host can do it too — gradle
# and flutter run there perfectly well, and only this wrapper was POSIX. This
# stays because it is what fingers remember, and because the shorter name is
# easier to point someone at.
#
# What it does, all of it in builder.py now:
#   * one APK per ABI (the universal APK carries three for no benefit to a
#     person with one phone: 136.3 MB against 32.8 MB for arm64);
#   * the version read from pubspec, so the error report can name the build a
#     tester actually has;
#   * a signing check at the END, where it cannot scroll past, because gradle
#     silently falls back to the debug key when android/key.properties is
#     missing and a debug-signed APK can never be updated over.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 builder.py android --release "$@"
