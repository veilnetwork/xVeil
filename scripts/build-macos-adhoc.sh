#!/usr/bin/env bash
# Build macOS WITHOUT an Apple Developer account.
#
#   scripts/build-macos-adhoc.sh [debug|release]     (default: release)
#
# Why this exists: `flutter build macos` cannot run at all on a machine with
# no Apple account -- DEBUG included, not just release. Both the app and the
# PacketTunnel extension ask for
# `com.apple.developer.networking.networkextension`, which is a RESTRICTED
# entitlement: Xcode refuses to sign it without a provisioning profile, and no
# profile can be minted without a (paid) account. The build compiles
# everything and then fails at the signing step.
#
# What this trades away: the VPN. It signs ad-hoc against
# {Debug,Release}NoVpn.entitlements (the originals minus the networkextension
# key) and drops the PacketTunnel extension from the bundle. That costs
# nothing today -- the macOS VPN has never worked, for exactly this reason --
# but the result is an app WITHOUT packet tunnelling, not a signed release.
#
# What you still cannot do with the output: hand it to someone else without
# friction. An ad-hoc signature cannot be notarised, so Gatekeeper refuses it
# on another Mac until the recipient clears the quarantine attribute by hand.
# For real distribution, get a Developer ID and use the normal build.
#
# Keeping the VPN entitlement while signing ad-hoc is NOT an option: AMFI
# kills the process at launch (observed as "Killed: 9" with no output, and
# nothing in the app's own log — `codesign -dv --entitlements -` is what says
# why).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in
  debug)   XC_CONFIG=Debug;   ENTITLEMENTS=DebugNoVpn.entitlements ;;
  release) XC_CONFIG=Release; ENTITLEMENTS=ReleaseNoVpn.entitlements ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac
APP="build/macos/Build/Products/$XC_CONFIG/xveil.app"

# Read the version from pubspec rather than defaulting to a placeholder: the
# error report names the build it came from, and a report that says "dev"
# cannot be tied to anything a tester actually has.
VERSION="${XVEIL_VERSION:-$(sed -n 's/^version: *//p' pubspec.yaml | head -1)}"
if [[ -z "$VERSION" ]]; then
  echo "cannot read 'version:' from pubspec.yaml" >&2
  exit 1
fi

# The debug hook is opt-in at COMPILE time -- soak_hook.dart reads a
# `bool.fromEnvironment`, so a build without the define has no hook at all and
# no way to gain one later. Without a pass-through here, a macOS stand build
# cannot be driven: /health answers nothing and it looks like a node that
# failed to bootstrap. (The Android path has the same shape; it cost an hour
# there on 2026-08-05 before the define was found.)
HOOK_DEFINE=()
case "${XVEIL_DEBUG_HOOK:-}" in
  1|true|yes)
    HOOK_DEFINE=(--dart-define=XVEIL_DEBUG_HOOK=true)
    echo "    debug hook: ON (stand build — do not hand this to a user)"
    # The PORT is compile-time for the same reason the flag is, and a stand
    # that needs TWO instances on one machine cannot separate them at launch:
    # both take the platform default, the second one's bind fails, and the
    # failure is swallowed into a devLog nobody can read without the hook that
    # just failed to start. Proven the slow way -- a second desktop build made
    # without this bound 38765 while its caller waited on 38767.
    if [[ -n "${XVEIL_DEBUG_HOOK_PORT:-}" ]]; then
      case "$XVEIL_DEBUG_HOOK_PORT" in
        ''|*[!0-9]*)
          echo "XVEIL_DEBUG_HOOK_PORT must be a number, got '$XVEIL_DEBUG_HOOK_PORT'" >&2
          exit 1
          ;;
      esac
      HOOK_DEFINE+=(--dart-define=XVEIL_DEBUG_HOOK_PORT="$XVEIL_DEBUG_HOOK_PORT")
      echo "    debug hook port: $XVEIL_DEBUG_HOOK_PORT"
    fi
    ;;
esac

echo "==> flutter config ($CONFIG, version=$VERSION)"
flutter build macos "--$CONFIG" --config-only \
  --dart-define=XVEIL_VERSION="$VERSION" "${HOOK_DEFINE[@]}"

echo "==> xcodebuild (ad-hoc, no VPN entitlement)"
# -derivedDataPath is NOT optional. Without it xcodebuild writes the app into
# ~/Library/Developer/Xcode/DerivedData/... while everything else here — the
# dylib bundling below, and anyone launching the result — looks in
# build/macos/. The two then diverge silently: the copy under build/macos keeps
# whatever Dart it was built with, so a "rebuild" appears to change nothing and
# every observation of the running app is of stale code. `flutter build macos`
# passes this itself, which is why the problem only shows up here. It cost an
# hour once; the check at the end is there so it cannot cost another.
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration "$XC_CONFIG" \
  -derivedDataPath build/macos \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS="Runner/$ENTITLEMENTS" \
  build

echo "==> bundling native dylibs"
scripts/bundle-macos-dylibs.sh "$CONFIG"

# bundle-macos-dylibs.sh re-signs with the ORIGINAL entitlements, which puts
# the restricted VPN key back. Undo that, or the app is killed on launch.
echo "==> dropping the tunnel extension and re-signing without the VPN key"
rm -rf "$APP/Contents/Library/SystemExtensions" "$APP/Contents/PlugIns"
codesign --force --sign - --entitlements "macos/Runner/$ENTITLEMENTS" \
  --timestamp=none "$APP"

if codesign -dv --entitlements - "$APP" 2>&1 | grep -q networkextension; then
  echo "FAILED: the VPN entitlement is still present -- the app will be killed at launch" >&2
  exit 1
fi

# Prove the app carries the Dart that was just compiled, rather than whatever
# a previous build left in build/macos. Debug runs a kernel snapshot, release
# an AOT image; both contain the version string that was defined above.
FRAMEWORK="$APP/Contents/Frameworks/App.framework/Versions/A"
if [[ "$CONFIG" == "debug" ]]; then
  DART_IMAGE="$FRAMEWORK/Resources/flutter_assets/kernel_blob.bin"
else
  DART_IMAGE="$FRAMEWORK/App"
fi
# `grep -c`, not `grep -q`: -q exits at the first match and closes the pipe,
# `strings` then dies of SIGPIPE, and `set -o pipefail` reports the whole
# pipeline as failed — so the check condemned a perfectly fresh bundle.
if ! strings -a "$DART_IMAGE" 2>/dev/null | grep -cF "$VERSION" >/dev/null; then
  echo "FAILED: $DART_IMAGE does not contain version $VERSION — the bundle is" >&2
  echo "        stale, so anything you observe in it is of older code." >&2
  exit 1
fi

echo "OK: $APP (Dart image carries $VERSION)"
echo "Reminder: ad-hoc signed. On another Mac, run"
echo "  xattr -dr com.apple.quarantine /Applications/xveil.app"
