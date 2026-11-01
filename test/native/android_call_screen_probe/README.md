# Call-only Android window probe

Builds a separate **network.veil.callscreenprobe** app from the current native
CallScreenActivity, VeilDaemonService and CallActionCapability sources. No
Flutter engine, network connection, identity, microphone, camera or user files.
It qualifies the Android notification/window boundary, not a media call or the
xVeil Dart/MainActivity host. Android SDK 36 and the checkout's Gradle/JDK setup
are required. Build output must be a new private directory outside the repo.

```sh
TMPDIR=/private/tmp/ python3 test/native/android_call_screen_probe/build.py /private/tmp/xveil-call-screen-probe
adb install -t /private/tmp/xveil-call-screen-probe/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n network.veil.callscreenprobe/com.veil.veil_flutter.Harness
```

Immediately lock the phone. Seven seconds after creation the harness posts an
incoming call through the production service with a synthetic contact name
and a tiny generated avatar. Pass `--ez avatar false` to `am start` to test the
initials fallback. The test-only harness can render its own synthetic view to
`files/call-screen.png`; no screenshot/export method is added to production. With notifications/full-screen
access permitted and no OS interruption suppression, the call-only screen
should appear over the keyguard. Answer → generic ongoing screen, End → window
and incoming notification disappear. The host validates the same scoped,
one-use capability before recording either action. The app UI must not become
visible over the keyguard. On Android 13+, allow notifications for this test
package; on Android 14+, allow its full-screen notifications in system settings.

For an automated touch driver, inspect button bounds with `uiautomator dump`.
`adb shell run-as network.veil.callscreenprobe cat shared_prefs/proof.xml` should
contain `accept=true`, `hangup=true` and `latePresentationRejected=true`. No call IDs or addresses are logged.
Retain `source-proof.json` with private test evidence.

```sh
adb shell am force-stop network.veil.callscreenprobe
adb uninstall network.veil.callscreenprobe
adb shell pidof network.veil.callscreenprobe
```

The final command must return no process. Do not uninstall or clear any real
xVeil package. This probe's results do not demonstrate mic/permission behavior
on a first real call, speaker audibility, camera access or background delivery.
