# Late group-call refusals must not end a replacement call

Base: `b4da2d66`. This is a separate local call-lifetime defect, not an
attribution of the Windows 10 camera, notification or one-way-chat reports.

## Reproduction

The real GroupCallService awaited an announce/join broadcast, handled a null
result by ending the current call, and only checked its original call identity
on the successful branch. Leaving and starting another call during that wait
allowed the old refusal to end the replacement, stop its media and release its
call slot. Even without a replacement it overwrote the user's hangup result
with an error and repeated media teardown.

Join also handled a delayed admission exclusion before checking which call was
current. That verdict could end the replacement instead of the ringing call
whose membership had been read.

Fourteen gate-controlled cases run against the unchanged base: nine fail by
assertion and five controls pass. They cover start/join refusal while current,
after leave, after replacement in the same group or another group, and after
disposal; join exclusion covers current, leave and both replacements. Gates are
released and outstanding operations joined even on failed assertions.

## Change and controls

Both broadcast outcomes now check the original call's live identity before
acting. Join checks the same boundary immediately after its admission reads,
before interpreting an exclusion. These checks use the existing group/channel/
call identity and disposed/live-state guard. A refusal or authoritative exclusion
still ends its own current call. No signature, ACL, key, sender, transport or
wire policy changes.

Replacement tests wait for actual active state and observe media stop counts
and the real CallSlot owner. A stale completion cannot rewrite the call, stop
its media or release its slot. The fixtures inject incoming signals at the
already-authenticated GroupService event boundary; cryptographic verification
and physical signaling are outside these particular FSM tests.

## Qualification

**1,269 tests passed, zero skipped**, across sixteen suites: group calls/core/
epochs, Space access/lifecycle, group teardown/source priority/audio/overlays,
group media, direct call FSM/startup/camera outcomes and diagnostic journal.
The fourteen new cases pass with the existing success-continuation guards.
`dart analyze lib test` reports no issues.

Native suites explicitly select the previously qualified core/storage libraries.
Both input hashes and 1,144 recorded Rust/Cargo source inputs match; all fifty
hidden-volume binding checksums pass. Selected binaries remain unchanged after
testing. No native build is performed.

Checks run headlessly with TMPDIR=/private/tmp/. No app windows, focus changes,
OS keyboard/mouse input, installed-app changes or seed operations are performed.
No push or release is performed.
