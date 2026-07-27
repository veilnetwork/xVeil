#!/usr/bin/env bash
# Build the Android release APKs for handing to testers.
#
# Exists so two things cannot be forgotten:
#
# 1. The version. The error report (Settings -> "Copy error report") names the
#    build it came from, and it reads that name from --dart-define. Pass the
#    flag by hand and someone eventually will not, and then a tester's report
#    says "dev" and cannot be tied to anything. This script reads the version
#    from pubspec.yaml instead, so it is always right and always matches what
#    is installed.
#
# 2. The signing key. Without android/key.properties, gradle falls back to the
#    DEBUG key -- it prints a warning, but a warning in the middle of a
#    two-minute build is not a warning anyone reads. A debug-signed APK must
#    not be handed out: nobody can ship an update over it later (a different
#    key is a different app to Android), and anyone can build something that
#    installs over it. This script checks at the END, where it cannot scroll
#    past.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${XVEIL_VERSION:-$(sed -n 's/^version: *//p' pubspec.yaml | head -1)}"
if [[ -z "$VERSION" ]]; then
  echo "cannot read 'version:' from pubspec.yaml" >&2
  exit 1
fi

# One APK per ABI. The universal APK carries all three (arm64, armeabi-v7a,
# x86_64) and is ~50% larger for no benefit to a person on one phone.
echo "==> flutter build apk --release --split-per-abi (version=$VERSION)"
flutter build apk --release --split-per-abi --dart-define=XVEIL_VERSION="$VERSION"

echo
ls -la build/app/outputs/flutter-apk/app-*-release.apk

echo
if [[ -f android/key.properties ]]; then
  echo "SIGNED with the key from android/key.properties."
  echo "Hand out build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
else
  cat >&2 <<'WARN'

  ############################################################
  #  DEBUG-SIGNED -- DO NOT HAND THIS OUT                    #
  ############################################################

  android/key.properties is missing, so gradle signed the release with the
  debug key. Two consequences, both permanent:

    * you can never ship an update over it (Android treats a different
      signing key as a different app -- testers would have to uninstall,
      losing their identity and message history);
    * anyone can build an APK that installs over yours.

  To fix, once, and keep the result safe -- it is the app's identity for
  as long as the app exists:

    keytool -genkey -v -keystore ~/xveil-release.jks \
      -keyalg RSA -keysize 4096 -validity 10000 -alias xveil

    cat > android/key.properties <<EOF
    storeFile=$HOME/xveil-release.jks
    storePassword=<what you typed>
    keyPassword=<what you typed>
    keyAlias=xveil
    EOF

  Both the .jks and key.properties are gitignored. Back up the .jks
  somewhere you will still have it in a year; losing it means losing the
  ability to update the app.

WARN
  exit 2
fi
