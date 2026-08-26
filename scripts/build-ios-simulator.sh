#!/usr/bin/env bash
# Build xVeil with its production dependency graph for Apple-Silicon iOS
# Simulator. mobile_scanner 7 uses Apple Vision and ships an ARM64 Simulator
# implementation, so no simulator-only dependency override is permitted here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDE="$ROOT/pubspec_overrides.yaml"
export XVEIL_XATTR_ROOT="$ROOT"

if [[ -e "$OVERRIDE" ]]; then
  echo "error: refusing to build Simulator with dependency overrides" >&2
  exit 1
fi

cd "$ROOT"
flutter pub get
scripts/build-mobile.sh ios --sim
(cd ios && pod install)

# CocoaPods can race the hidden-volume force_load against its XCFramework copy
# on the first architecture switch. A first failed build leaves the selected
# slice staged; retry once rather than requiring a manual second invocation.
# The version define, same as every other entry point. Without it this build
# reports itself as "dev": the error report ties to no build, and the update
# check refuses to offer anything because it will not order a version it
# cannot parse. A Simulator build is where a tester reproduces things, so it
# is exactly the build whose reports need to name themselves.
VERSION="${XVEIL_VERSION:-$(bash "$(dirname "${BASH_SOURCE[0]}")/pubspec-version.sh")}"
if ! flutter build ios --simulator --debug --dart-define=XVEIL_VERSION="$VERSION"; then
  flutter build ios --simulator --debug --dart-define=XVEIL_VERSION="$VERSION"
fi

APP="$ROOT/build/ios/iphonesimulator/Runner.app"
ARCHS="$(lipo -archs "$APP/Runner")"
if [[ " $ARCHS " != *" arm64 "* ]]; then
  echo "error: Simulator app is missing the arm64 slice ($ARCHS)" >&2
  exit 1
fi

echo "Simulator app: $APP ($ARCHS)"
