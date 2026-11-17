# Group camera termination must update local capture posture

Base: xVeil `b2bf18f9`, Veil `33314eac`. This is a separately reproduced group
media defect, not attribution of the reporting user's Windows 10 camera failure.

## Evidence and change

The direct-call controller already observes an explicitly stopped native camera.
The group controller only handled startup success/refusal. After a successful
start followed by capture termination, its FSM and participant announcement
continued to say camera ON. The native group statistics also omitted the
capturer's state, so application polling could not distinguish that condition.

The group native snapshot now reports the same `camera_capturing` categories as
the direct engine: 1 for a live source, 0 for a retained stopped source, -1 when
no native source exists. The existing group statistics poll observes an integer
zero only while the current engine/request owns an enabled desktop camera.
It records the existing bounded cameraStopped diagnostic and emits the existing
group/channel/call-scoped camera failure event. GroupCallService turns camera
posture OFF and announces it while retaining audio and video receive. A new ON
can restart the camera on the same engine.

Android's external producer, an absent/legacy/malformed snapshot, an OFF intent,
screen ownership and an ended session do not establish desktop camera failure.
Sparse frames, paused encoding and slow network traffic are not used as an
error signal. No watchdog, restart policy, new timer, permission prompt or
remote control of the user's camera is added. Recoverable Android camera-plugin
error strings are not interpreted as terminal native capture evidence.

## Verification

- On the base controller, nine new cases produce **one assertion failure and
  eight passing controls**. The failure is the camera posture after explicit
  termination, not a timeout or fixture-load failure. The tests drive the real
  group controller and GroupCallService with controlled engine/transport/group
  boundaries and virtual time. They check a single announcement, continued
  audio/receive, explicit retry and the source-ownership exclusions above.
- **423 tests pass, zero skipped**, across eight related media, group FSM,
  teardown, audio/source-policy and diagnostic suites. With diagnostics enabled,
  **212 pass, zero skipped**, in three overlapping suites; these counts are not
  added as unique cases. The actual exported journal retains cameraStopped/0
  and excludes the private driver-text canary and room/call identifiers.
- Analyzer and whitespace checks pass. The first source-ownership fixture had
  an invalid getter and failed to load; that attempt was corrected and is not
  counted as a baseline failure or passing qualification. A subsequent analyzer
  style finding was corrected before the final runs.
- A full macOS arm64 media dylib is built using the existing WebRTC toolchain,
  with **132 source/builder/SDK metadata/library inputs** frozen and checked
  before/after compilation. Source and binary provenance match; the build exports
  the existing 107 media symbols. A C ABI smoke reads camera absence before,
  during and after the video lifecycle, without starting camera/audio or adding
  a peer. It verifies -1 rather than falsely reporting a failed camera.

The native smoke is
`third_party/veil/flutter/veil_media/test/group_camera_stats_smoke.cc`.
On macOS, compile it with the selected full dylib, `-Wl,-export_dynamic` and
an rpath to that library's directory. Run the resulting owned process with an
external deadline. It supplies no-op callback transport functions and creates
no application window. It does not simulate a physical camera disconnect.

## Limits and cleanup

The terminal-state/FSM proof is controlled; physical camera removal, a real
group network call and the original Windows 10 device are not qualified.
Windows group-engine platform support is unchanged. Full native compilation
and the C ABI lifecycle smoke qualify the new field on macOS, not all targets.
New immutable media pins and final packages remain required before publication.

All test/probe processes exit, and the existing user's Mac app remains running.
No GUI activation or OS input, camera/microphone startup, phone installation,
user container, Windows session or production seed is touched. The small private
component/provenance pair is retained for review. No push or release.
