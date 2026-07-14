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
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xveil-ios-simulator.XXXXXX")"
export XVEIL_XATTR_ROOT="$ROOT"
export PATH="$ROOT/tool/ios_simulator:$PATH"
TRACKED_IOS_STATE=(
  "ios/Podfile.lock"
  "ios/Runner.xcodeproj/project.pbxproj"
  "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

if [[ -e "$OVERRIDE" ]]; then
  rm -rf "$STATE_DIR"
  echo "error: refusing to replace existing pubspec_overrides.yaml" >&2
  exit 1
fi

for relative_path in "${TRACKED_IOS_STATE[@]}"; do
  mkdir -p "$STATE_DIR/$(dirname "$relative_path")"
  if [[ -e "$ROOT/$relative_path" ]]; then
    cp -p "$ROOT/$relative_path" "$STATE_DIR/$relative_path"
  else
    touch "$STATE_DIR/$relative_path.absent"
  fi
done

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  set +e
  rm -f "$OVERRIDE"
  (cd "$ROOT" && flutter pub get >/dev/null) || cleanup_status=$?
  # Restore the production CocoaPods graph as well. `flutter pub get` updates
  # Dart plugins but does not replace the stub Pod targets/materialized lock.
  (cd "$ROOT/ios" && pod install >/dev/null) || cleanup_status=$?
  # `pod install` rewrites tracked generated files even when it restores the
  # same production graph. Preserve the exact pre-build state, including any
  # caller changes, so a simulator-only build cannot dirty the worktree.
  for relative_path in "${TRACKED_IOS_STATE[@]}"; do
    if [[ -e "$STATE_DIR/$relative_path.absent" ]]; then
      rm -f "$ROOT/$relative_path"
    else
      # CocoaPods may remove the whole SwiftPM state directory while swapping
      # the production MLKit graph for the simulator stub. Recreate the
      # original parent before restoring the saved tracked file.
      mkdir -p "$ROOT/$(dirname "$relative_path")"
      cp -p "$STATE_DIR/$relative_path" "$ROOT/$relative_path"
    fi
  done
  rm -rf "$STATE_DIR"
  if [[ $status -eq 0 && $cleanup_status -ne 0 ]]; then
    status=$cleanup_status
  fi
  exit "$status"
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

# Flutter 26 decides whether arm64-simulator is supported by inspecting the
# *existing* Pods.xcodeproj before its internal pod install. Materialize the
# scanner-stub graph first; otherwise a prior production MLKit graph makes
# Flutter write `EXCLUDED_ARCHS=arm64` and emit an unusable x86_64 app even
# though the later pod install correctly removes MLKit.
(cd ios && pod install)

# CocoaPods can race the hidden-volume force_load against its XCFramework copy
# on the first architecture switch. A first failed build leaves the selected
# slice staged; retry once rather than requiring a manual second invocation.
if ! flutter build ios --simulator --debug; then
  flutter build ios --simulator --debug
fi

echo "Simulator app: $ROOT/build/ios/iphonesimulator/Runner.app"
