#!/usr/bin/env bash
# Build xVeil for Apple-Silicon iOS Simulator without shipping a fake scanner.
#
# Google MLKit (mobile_scanner's iOS backend) contains a device-arm64 slice but
# no arm64-simulator slice. iOS 26 simulators on Apple Silicon cannot run the
# x86_64 fallback Flutter otherwise selects. This script temporarily overrides
# only mobile_scanner with a tiny UI-compatible camera-unavailable stub, builds
# the real veil/hidden-volume arm64 simulator slices, then restores the normal
# production dependency graph. The resulting Runner.app is for simulator use
# only; physical iOS/Android builds continue to use the real scanner package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDE="$ROOT/pubspec_overrides.yaml"

if [[ -e "$OVERRIDE" ]]; then
  echo "error: refusing to replace existing pubspec_overrides.yaml" >&2
  exit 1
fi

cleanup() {
  rm -f "$OVERRIDE"
  (cd "$ROOT" && flutter pub get >/dev/null)
}
trap cleanup EXIT

cat >"$OVERRIDE" <<'YAML'
dependency_overrides:
  mobile_scanner:
    path: tool/ios_simulator/mobile_scanner_stub
YAML

cd "$ROOT"
flutter pub get
scripts/build-mobile.sh ios --sim

# CocoaPods can race the hidden-volume force_load against its XCFramework copy
# on the first architecture switch. A first failed build leaves the selected
# slice staged; retry once rather than requiring a manual second invocation.
if ! flutter build ios --simulator --debug; then
  flutter build ios --simulator --debug
fi

echo "Simulator app: $ROOT/build/ios/iphonesimulator/Runner.app"
