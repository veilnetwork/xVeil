#!/usr/bin/env bash
# Build a macOS release WITHOUT an Apple Developer account.
#
# Why this exists: the normal `flutter build macos --release` cannot run on a
# machine with no Apple account. Both the app and the PacketTunnel extension
# ask for `com.apple.developer.networking.networkextension`, which is a
# RESTRICTED entitlement -- Xcode refuses to sign it without a provisioning
# profile, and no profile can be minted without a (paid) account. The build
# fails at the signing step, having compiled everything.
#
# What this script trades away: the VPN. It signs ad-hoc against
# ReleaseNoVpn.entitlements (Release minus the networkextension key) and drops
# the PacketTunnel extension from the bundle. That costs nothing today -- the
# macOS VPN has never worked for exactly this reason -- but be clear that the
# result is an app WITHOUT packet tunnelling, not a fully signed release.
#
# What you still cannot do with the output: hand it to someone else without
# friction. An ad-hoc signature cannot be notarised, so Gatekeeper will refuse
# it on another Mac until the recipient clears the quarantine attribute by
# hand. For real distribution, get a Developer ID and use the normal build.
#
# Keeping the VPN entitlement while signing ad-hoc is NOT an option: AMFI kills
# the process at launch (observed as "Killed: 9" with no output).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${XVEIL_VERSION:-dev}"
APP="build/macos/Build/Products/Release/xveil.app"

echo "==> flutter config (version=$VERSION)"
flutter build macos --release --config-only --dart-define=XVEIL_VERSION="$VERSION"

echo "==> xcodebuild (ad-hoc, no VPN entitlement)"
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS=Runner/ReleaseNoVpn.entitlements \
  build

echo "==> bundling native dylibs"
scripts/bundle-macos-dylibs.sh release

# bundle-macos-dylibs.sh re-signs with Release.entitlements, which puts the
# restricted VPN key back. Undo that, or the app is killed on launch.
echo "==> dropping the tunnel extension and re-signing without the VPN key"
rm -rf "$APP/Contents/Library/SystemExtensions" "$APP/Contents/PlugIns"
codesign --force --sign - --entitlements macos/Runner/ReleaseNoVpn.entitlements \
  --timestamp=none "$APP"

codesign -dv --entitlements - "$APP" 2>&1 | grep -q networkextension && {
  echo "FAILED: the VPN entitlement is still present -- the app will be killed at launch" >&2
  exit 1
}

echo "OK: $APP"
echo "Reminder: ad-hoc signed. On another Mac, run"
echo "  xattr -dr com.apple.quarantine /Applications/xveil.app"
