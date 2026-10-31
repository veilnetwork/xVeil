# Receive-only audio and Windows investigation

## Confirmed code defect

The released media engine reports capture and playout startup separately, but
returns a combined failure if either device fails. xVeil previously rejected
that result even when playout had started and only capture was unavailable.
This made a missing microphone discard a usable receive path.

The application now accepts only the exact capture=failed / playout=started
case as receive-only, requires successful native mute, and publishes the actual
microphone-off posture to the local UI and remote peer. Unknown failures and
failed output remain failures. A failed retry cannot falsely turn the microphone
on; a successful retry restores normal capture. Native ABI and binaries are
unchanged.

## Verification

- FSM regression failed on the previous implementation (microphone stayed on)
  and passes with the change. Startup classification rejects unknown and
  ill-typed results as well as output failure.
- Call service, startup classification and microphone-state suites: 207 tests
  passed. Analysis of all five changed Dart files passed.
- Published Windows media DLL was tested under the real interactive user
  session, using real Windows audio devices and synthetic Opus RTP through an
  isolated mock transport. Both normal and explicitly muted capture runs
  accepted 200 packets and reached output level band 5.
- On this PC the normal probe reported **capture=started and playout=started**.
  Therefore the missing-microphone startup mechanism did **not** reproduce the
  owner's phone-to-Windows complaint. Packet acceptance/output level is not a
  measurement of audible volume or proof of a working network call.

## Full-controller follow-up

The first application patch classified receive-only startup correctly, but two
later exits still used the raw combined native result: the audio-only final
return and the early return when video admission was deferred. Consequently
that patch was incomplete. Startup now keeps the native result for diagnostics
and uses the usable audio-session result for **all** later exits.

Four additional tests drive the actual `VeilCallMediaController.start/stop`
with injected engine/channel ports: audio-only receive-only success; rejected
video startup and deferred admission while receiving audio; normal capture;
and rejection of output failure, unknown capture status, or failed native mute.
Restoring the old raw-return behavior makes the two receive-only success tests
fail. The final combined call/controller suites pass **211 tests**. Analysis is
clean. Production still creates the ordinary native engine by default.

## Network control: Mac to Windows

Two calls reached `active`: default P2P and per-contact forced relay. Both
endpoints exchanged actual Opus media through the application; this is separate
from the earlier mock-transport probe. Selected Windows snapshots:

| Route | Received audio RTP packets | Emitted output samples | Output level band |
|---|---:|---:|---:|
| P2P | 2515 | 4,750,080 | 3 |
| Relay | 4617 | 8,985,600 | 3 |

Capture and playout startup both reported 1, native speaker/microphone mute were
0, and local receive drops were 0 at those snapshots. These are point-in-time
counters, not claims of zero network loss, measured intelligibility, or audible
sound pressure. No speech recording or payload capture was retained.

A read-only observation in the real interactive Windows session also found the
QA app's active audio session at 100% volume, endpoint volume 56%, neither
muted, and the ordinary/communications default outputs on the same endpoint.
System volume, routing and mute were not changed by this observation.

Qualification limits are explicit:

- Windows uses published 0.13.94 native libraries. Its current Dart AOT and
  profile Flutter engine are rebuilt; runner/plugins are frozen from release
  because this host lacks ATL headers for a complete native build.
- The supplied host is Windows 11, not a physical qualification of the earlier
  Windows 10 reports. This QA profile does not establish the state of a user's
  separate installation.
- Mac is a versioned control using current Dart and the already verified older
  SDK `08b67a6e`, with its input/output hashes recorded privately. These calls
  are **not** a qualification of a new Mac release or of the complete current
  multi-device/revoke matrix.
- First-run native mining of a fresh Mac fixture was still running when that
  fixture was stopped. The calls used a verified copy of an existing QA profile
  instead; the original QA profile's files stayed byte-identical. The input is
  now a frozen pre-test fixture: do not roll the networked copy back to that
  cryptographic state or run both copies as live devices. The output copy is
  retained for continuation.

## Still open: the owner's phone-to-Windows call

The original phone APK, including Dart and native libraries, matches the
published normal 0.13.94 ARM64 APK byte-for-byte. It is not the diagnostics APK.
The reported no-sound symptom has not reproduced in the Mac/Windows controls;
its cause remains unknown and the report stays active.

The OS again refused ADB installation of the separate Android QA package
(`INSTALL_FAILED_USER_RESTRICTED`). A normal installer attempt also did not
install it; the shell lacked a document URI grant. No security settings were
changed. The staged APK was removed. Main app/identity and original Wi-Fi/mobile
data settings were preserved. Actual Poco-to-Windows and Wi-Fi-to-cellular
handover tests on the candidate remain unperformed.

After the calls, QA contact policies were restored. The owned Windows app and
scheduled tasks were removed from the running stand; the SSH tunnel was closed.
The Mac app did not exit after SIGTERM and was forcibly closed after media
teardown; its process and all three owned ports were verified absent/free.
Separate QA profiles are retained for subsequent tests.

Next useful work without the phone: integrate similarly bounded Windows mixer
state into opt-in anonymous diagnostics. The read-only stand probe above is an
external observation, **not yet** a feature of exported application reports.
Existing native startup/level/mute metrics remain available in diagnostic builds.

Private logs, audio-device names, addresses, keys and identity material are not
included in this document. No push or release is part of this work cycle.
