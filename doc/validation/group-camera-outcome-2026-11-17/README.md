# Group camera start outcomes and capture posture

Base: `4ff20632`. This follows the
[group capture ownership work](../group-capture-startup-2026-11-17/README.md)
and does not attribute the original Windows 10 one-to-one camera report.

## Base evidence

The group controller ignored `startCamera()` refusal/exception, and the group
FSM had no capture-failure feedback. Audio/video receive could start correctly
while the local UI and participant media announcement kept camera ON.

Ten exact-base desktop cases fail the camera-posture assertion: false return
and exception in each of initial startup, toggle ON, audio-to-video upgrade,
failed screen-share recovery and camera hand-back after sharing. These use
real GroupCallService and VeilGroupCallMediaController with controlled native
engines and group/transport boundaries.

A separate Android-source selection on the exact base has one assertion failure
for refused startup and two passing controls (OFF and replacement before the
answer). A further Android source-exception case fails with an unhandled source
error and incorrect camera posture. The latter is not counted as a pure
assertion-only failure. It uses a controlled source exception, not a demonstrated
exception from a physical device driver.

## Change

Group media now records camera-start success/refusal and emits local failure
feedback scoped to group, channel and call ID. Explicit stop retires this owner
at the request boundary. Engine request, source identity and capture epoch
checks prevent an old Android answer from reporting against a newer source.

The group FSM consumes only current, still-failed feedback. It marks camera OFF,
retains the live call and video receive, and announces the actual local media
posture. A subsequent ON can retry capture on the same engine. Command failures
also use the existing camera-operation epoch: an older failed command cannot
undo a newer successful ON. The subscription is retired during disposal.

Desktop startup, toggle and failed-share restoration use the same outcome
reporter. Android refusal/exception retires the failed source, preserves audio
and receive, and emits feedback only if that source still owns capture. No
frame-rate watchdog, new polling loop or automatic choice of another camera
was added.

Diagnostics reuse the existing cameraStart event and numeric capture allowlist.
The in-memory room identifiers used to route local feedback are not exported;
driver text and paths are not copied into the anonymous report.

## Qualification

**627 passed, zero skipped on the macOS host**, across twelve suites: group media,
FSM, teardown, passive rooms, overlay/audio/source priority, direct-call FSM and
media startup, route operations, camera state and diagnostic journal.
**51 camera cases also pass with XVEIL_DIAGNOSTICS=true**, including the actual
report check with numeric evidence and private-text/room-ID exclusion.
`dart analyze lib test` reports no issues after removing unused test locals and
adding required braces; these cleanup edits do not change tested behavior.

Controls cover recovery after each refusal, unchanged successful capture,
screen ownership, OFF/stop/replacement during Android startup, mismatched group/
channel/call failure events, already-recovered capture, disposal, and a failed
old camera command completing after a newer ON. No timing threshold establishes
the result: native/source outcomes and asynchronous gates are controlled.

These are headless FSM/component checks. They do not qualify physical Windows
10 camera capture, network video delivery or the user's driver. The original
Windows complaint remains unattributed. No test window was opened/activated and
no keyboard/mouse input was sent. The existing user's Mac app stayed running.
Native libraries, submodule revisions, installed apps, engine pins and seeds
were unchanged; nothing was pushed or released.
