# Group screen-share hand-back and observed OS stops

Base: `dcc61af7`. This follows the
[one-to-one continuation fix](../screen-share-continuation-2026-11-17/README.md).
It qualifies application control flow, not physical capture or the original
Windows 10 camera report.

## Confirmed group defect

The group FSM checked the current room after awaiting source start/stop and
camera restoration. That prevented an obsolete room snapshot being published,
but the camera command had already happened. A late stop could invoke camera
enable after leaving, replacing or disposing the room. Its captured camera flag
also ignored camera OFF/ON chosen while the source stop was waiting. Finally,
a refused manual stop was published as a completed stop.

Six corrected baseline cases fail assertions on the original source: three
terminal/ownership cases, both intent changes, and refusal. Six earlier controls
pass. The initial fixture checked active immediately after `startCall`, which
deliberately starts media asynchronously. Those setup failures are not credited;
the qualified fixture awaits the actual active event before exercising the race.

The service now checks the full current room owner/live predicate before another
capture command, updates the current snapshot, and restores only its current
camera intent. A second check after camera I/O prevents an unrelated room's
announcement. A refused manual start/stop does not establish a transition.

## OS notification is different from a manual request

The broader group test exposed a necessary distinction: an owned
`screenShareStopped` event reports a stop that already occurred. The existing
N-party test intentionally has a media stub whose redundant stop returns false;
requiring success there lost the OS-revoked projection update.

Both services now route that event through a private observed-stop path. The
manual API still requires successful source transition. An observed stop can
fold the already-ended share even if redundant cleanup returns false. All
ownership checks still apply before camera restoration and announcement; the
observed event cannot authorize work in a replacement call or room.

The prior one-to-one fix had introduced the same regression for that combination
of OS event and false cleanup result. A separate test against the exact base
runtime fails its screen-state assertion; the candidate passes. This regression
is acknowledged as ours, not attributed to a user's device.

## Verification

- **20 group teardown tests pass:** the six reproduced cases, existing lifetime
  and membership controls, unchanged on/off intent, concurrent mic/channel-epoch
  updates, OS stop, replacement ownership, and changes while camera restoration
  itself waits. Fake sources have explicit entry/release gates. The new fixture
  disposes services, stream sources and fake group services.
- **442 related tests pass, zero skips**, across nine suites: group FSM,
  teardown, passive rooms, production group media with controlled engines,
  group overlay/audio/source-priority, one-to-one FSM and route operations.
- The N-party test still exercises real GroupService signaling/folding with
  synthetic signing/storage. It is not a cryptographic/native network stand.
- `dart analyze lib test` is clean. Staged privacy and whitespace checks pass.
  Unrelated formatter changes were excluded.

The first broader candidate had 437 passing tests and one genuine OS-revocation
regression. That failure prompted the event/manual distinction; only the final
442-test run is credited as green.

## Limits

Counters here prove controller invocations, local state and signaling, not a
physical camera opening or stopping. Group camera control still has a void
result contract; this does not add per-device capture outcome reporting or
qualify overlapping opposite hardware operations. OS event ownership remains
the media controller's responsibility. The new replacement controls qualify a
previously started event whose cleanup completes after ownership changed.

No native build, camera/microphone capture, user profile, phone, relay, GUI app,
focus change or OS input was involved. The existing user app remains running,
test processes exit, and no installed binary, push or release changes.

The subsequent [capture-intent qualification](../group-camera-intent-2026-11-17/README.md)
connects the group FSM to the production media controller: a choice changed
while sharing must reach capture rollback, not only the Call snapshot. It also
qualifies Android fallback/ownership with injected sources, without claiming
physical Android camera behavior.
