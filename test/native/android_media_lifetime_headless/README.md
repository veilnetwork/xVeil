# Activity-free Android media lifetime probe

This runs the real Dart media controller on Android, including its
`Platform.isAndroid` screen-share branch. Two cases also use the real
`CallService` and `CallSlot`. Engines, camera sources, transport, preferences,
permissions, foreground service, audio route, decoded texture and screen-capture
platform channel are synthetic. No camera, microphone, network, identity or
container is used. There is no Activity, FlutterView, notification or input
injection. It does **not** qualify physical capture or a real call.

Requires Python 3.11+, an arm64 Android 8+ device, the checkout's Flutter SDK with its debug
arm64 engine cached, Android SDK/build-tools 35 and JDK 17+. The builder takes
explicit embedding runtime JAR/AAR dependencies: tracing, lifecycle-common,
core, Kotlin stdlib and ReLinker. The qualified set was tracing 1.2.0,
lifecycle-common 2.7.0, core 1.13.1, Kotlin stdlib 1.9.22, ReLinker 1.4.5.
Use the corresponding files from the local Gradle cache. These are harness
runtime dependencies, not changes to the application's dependency pins.

```sh
TMPDIR=/private/tmp/ python3 test/native/android_media_lifetime_headless/build.py \
  /private/tmp/xveil-headless-media-qa \
  --flutter-sdk "$FLUTTER_ROOT" --android-sdk "$ANDROID_SDK_ROOT" \
  --java-home "$JAVA_HOME" \
  --runtime "$TRACING_AAR" --runtime "$LIFECYCLE_JAR" \
  --runtime "$CORE_AAR" --runtime "$KOTLIN_JAR" --runtime "$RELINKER_AAR"
```

Build output must be a new private directory outside the checkout. It retains
one installable debug APK and SHA-256 source/kernel/runtime/engine provenance.
The script does not install, launch, sign a project commit or change app pins.
Its generated certificate signs only this isolated QA package.

Before installing, confirm that `network.veil.qa.headless.screenlifetime` does
not already belong to another test. Never replace a real xVeil package. The
normal app need not be closed. Verify the installed APK against `source-proof.json`.

```sh
adb -s "$QA_DEVICE" install --no-streaming /private/tmp/xveil-headless-media-qa/probe.apk
adb -s "$QA_DEVICE" shell am instrument -w \
  network.veil.qa.headless.screenlifetime/qa.Probe
```

Require **all nine named values to be `pass`** in `INSTRUMENTATION_RESULT`,
not merely successful process exit or `INSTRUMENTATION_CODE: -1`. Failures
include a private Dart stack; keep output private. Ten-second per-case and
thirty-second native watchdogs bound a stuck harness; they are not latency
assertions. Ordering is controlled by explicit stop/start reply gates.

Cases cover native-stop teardown with different/same-call successors, a plugin
successor, two real-FSM hangup/new-call cases starting from camera fallback,
ordinary camera/teardown, hangup without a successor, two overlapping
screen-consent replies, and retention of an already-running projection across
a same-call route rebuild. Production platform overrides and test hooks are not
added. The probe is a Dart entrypoint, not a host `flutter test` suite.

After the run, stop/uninstall only this QA package and verify no process remains:

```sh
adb -s "$QA_DEVICE" shell am force-stop network.veil.qa.headless.screenlifetime
adb -s "$QA_DEVICE" uninstall network.veil.qa.headless.screenlifetime
adb -s "$QA_DEVICE" shell pidof network.veil.qa.headless.screenlifetime
```

The final command must return no PID. Delete private build intermediates when
finished; the debug Flutter engine is large. Do not retain multiple APK copies.
