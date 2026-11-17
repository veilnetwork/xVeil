# Queued group rosters at session retirement

Base: `aecac8fd`. This follows the
[group capture startup qualification](../group-capture-startup-2026-11-17/README.md).
It covers the media operation lane rather than the original Windows 10 camera
or one-way-contact reports.

## Confirmed mechanism

Incoming joins can queue several `update` calls behind a slow peer-channel open.
Stop or a replacement start invalidates the active session immediately, before
its physical cleanup reaches that lane. Previously an already queued update
read the session epoch only when it finally entered `_syncPeersLocked`. It thus
borrowed the newer epoch while the retiring engine still existed, opened more
channels and attached peers to that engine before cleanup.

| Base-runtime case | Result |
| --- | --- |
| Queued roster, then stop | Assertion failure: another outgoing channel opens |
| Queued roster, then stop/new call | Same assertion failure |
| Queued roster, then same-call rebuild | Same assertion failure |
| Real GroupCallService: two incoming joins, then leave | Assertion failure: queued joins reopen channels after the FSM is ended |
| Queued roster, continuing session | Passing control: both rosters apply |
| Roster queued behind its own initial startup | Passing control: channel and video mount succeed |

The first five-case base run has three assertion failures and two passing
controls. The FSM case was then independently run on the unchanged base and
failed the channel-open assertion. No setup failure is credited. Explicit
completers gate channel/identity waits; no latency threshold is used.

## Change

The public `update` captures the session request before queuing. On entry and
after peer synchronization it requires that request to remain current and to
own the engine. The shared peer-sync helper also refuses a retiring engine
whose request differs from the active session, including after asynchronous
secret/channel work. Existing cleanup closes a channel whose in-flight open
completed after cancellation.

An update for an initial start may still queue before the engine exists: the
ownership checks run after entering the lane, when that start has completed.
A same-call rebuild preserves capture choices as before, while its earlier
queued roster snapshots are retired with their old session request.

No peer authorization, key derivation, group membership, wire format or
transport policy was weakened or changed.

## Qualification and limits

**490 passed, zero skipped on the macOS host**, across ten suites: production
group media with controlled engines/transports, group FSM, teardown, passive
rooms, overlay/audio/source-priority policy, direct-call FSM, route operations
and camera state. `dart analyze lib test` reports no issues. The focused roster
selection passes seven cases, including an existing source-headroom control.

The FSM fixture uses real GroupCallService and VeilGroupCallMediaController,
with synthetic admitted group signals and recording media/transport stand-ins.
It proves late open/attachment calls to a retiring session; it does not measure
physical recording, received audio after leave or a network authorization bypass.
The Windows 10 reports remain unattributed.

All checks were headless. No GUI app was opened or activated, and no keyboard
or mouse input was sent. The existing user's Mac app stayed running. Native
libraries/submodule revisions, installed apps, engine pins and seeds were not
changed. No push or release was performed.
