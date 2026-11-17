# Group capture intent across startup and engine replacement

Base: `2bc06cc0`. This extends the
[capture-intent forwarding checks](../group-camera-intent-2026-11-17/README.md)
to initial startup and audio-to-video upgrade. It does not attribute the
original Windows 10 camera report or qualify physical recording.

## Evidence from the base runtime

| Controlled case | Assertion failures | Observation |
| --- | ---: | --- |
| Group FSM: OFF / OFF→ON while video mount waits | 2 | Late completion restores OFF to ON, or issues two enable commands instead of the latest one |
| Real FSM/controller: OFF during initial permission/identity wait | 2 | The native-engine stand-in receives camera start while the FSM still says OFF |
| Old camera permission resolves after another engine starts | 1 | Video mounts on the replacement engine |
| Video mount queued before stop/replacement | 2 | Obsolete queued work reports success and mounts video after its session was revoked |
| Reused call ID in another group/channel: microphone state | 2 | The media controller borrows the previous scope's unmuted state |
| Queued microphone choice for a new engine | 2 | A command unmutes the retiring engine, or the new engine loses the requested mute |

The first run has five assertion failures and 117 passing controls. The queue,
scope and microphone subsets were separately repeated against the exact base
media runtime. No setup failures are credited. The combined table describes
component/FSM invariants, not eleven attributed user incidents or demonstrated
network exploits. In particular, scope-reuse and queued-engine tests exercise
the media controller API; an original GUI path for those cases is not claimed.

## Change

The group FSM versions camera operations. OFF invalidates a pending ON even
before video capability is published, while a newer ON remains usable. Current
room ownership is checked again before post-camera announcements.

The group media controller now uses the existing CallCameraState alongside
CallMicrophoneState. Both are bound before an engine operation enters its lane,
so choices made while that operation waits are retained. Startup reads current
intent rather than reapplying its captured camera flag. An explicit stop clears
intent at the request boundary; delayed physical cleanup cannot erase a newer
queued room's choice. Failed/same-call restarts retain the owner's choice.

Capture state is keyed by group, channel and call ID in a private in-memory
scope. A first candidate keyed camera state only by call ID; scope-reuse controls
caught that new regression before commit. The microphone had the corresponding
scope omission already on the base. The complete scope separates both without
changing wire IDs, room membership rules or persisted data.

Each engine also records its owning session request. Old permission/queued
video work cannot mount on another engine, and microphone/camera commands for
a pending new session cannot act on the retiring one. Current-engine checks
cover Android camera starts, callbacks and late cleanup; the existing source
identity/epoch checks remain intact.

## Qualification

**484 tests pass, zero skips on the macOS host**, across ten suites: group FSM,
teardown, passive rooms, production group media with controlled engines,
group overlay/audio/source priority, direct FSM, route operations and shared
camera state. `dart analyze lib test` reports no issues.

The added controls include unchanged ON, OFF→ON, same-call restart, failed-start
retry, a distinct new call, queued stop/start, group/channel scope reuse and
mute/unmute at engine handover. Explicit gates and engine counters qualify the
wait boundaries. The camera-permission cases run only where that branch exists
(macOS/iOS); portable queued-lane cases independently cover session revocation.
All were selected without skips in the credited host run.

Real FSM/controller fixtures use synthetic group authorization/signaling and
controlled permissions/engines. Engine counters qualify API invocation and
initialization posture, not microphone samples, pixels, codec output or network
delivery. Physical platform permission/capture behavior remains separate work.

No native ABI, camera/screen consent policy, encryption, routing or own-device
mailbox changes. No OS dialogs, GUI launches, focus changes or input injection;
no native builds, real capture, profiles, phones or relays. Owned test processes
exit and the existing user application remains running. Staged privacy and
whitespace checks pass; no push or release.
