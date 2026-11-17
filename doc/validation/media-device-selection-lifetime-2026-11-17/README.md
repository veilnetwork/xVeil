# Delayed media-device choices must retain their call and preference owner

Base: `d2cd1322`. This is control-flow qualification. It does not attribute the
reporting user's Windows 10 camera or historical audio failure.

## Confirmed mechanisms

Microphone/speaker selection captured an engine, awaited discovery and then
controlled that engine without checking its call/session owner again. Native
Camera2 teardown deliberately awaits its callback drain before releasing the
engine. A device choice could therefore resume after hangup began while that
old engine was still valid, control it and report success.

The same methods resolved profilePreferences only after that await. A profile
backend handoff made the old operation adopt the new profile and write its
device choice there. Camera selection already checked its media epoch, but did
not bind the preference owner; it had the same profile-handoff gap when the
backend changed before media teardown began.

| Controlled baseline | Result |
| --- | --- |
| Microphone/speaker × hangup, hangup+profile handoff, profile handoff before media teardown | Six assertion failures: late selection accepted and preference saved |
| Microphone/speaker in the current call/profile | Two passing controls |
| Camera choice after profile backend handoff | One assertion failure; its unchanged handler selected/saved the new camera |
| Camera choice in the current profile | One passing control |

The audio fixture uses the list API's actual async return, not a synthetic
discovery delay. A controlled camera stop fence keeps the native-engine double
valid; assertions verify it is not disposed at the decision point. This is not
an oracle that merely counts a harmless rejected call on a destroyed wrapper.
The same camera/engine/source adapter used for the prior direct-camera tests
runs headlessly on the host. Profile handoff replaces the real plugin backend
with another isolated in-memory backend; it does not use personal files.

## Change

Audio selection binds the engine, call, media epoch and preference lifetime
before discovery. It rejects a changed owner before native selection or
preference mutation. Camera selection retains the same bound preference lifetime
and checks it alongside its existing session guards, including before deferred
Android source replacement.

ProfilePreferencesLifetime now exposes its existing ownership predicate as a
pure synchronous isCurrent getter. The existing active-lifetime guard delegates
to the same predicate; retirement, admitted-write draining and backend file
ownership retain their previous semantics. A retired backend cannot become
current again merely by reinstalling that instance.

An intermediate candidate awaited preferences before native audio selection.
Two additional controls exposed its regression: unavailable optional persistence
must not skip a valid live native route change. The final implementation checks
ownership without I/O and preserves the prior native-selection/failed-preference
result contract. Admitted preference writes still belong to their bound owner;
no stale operation resolves a replacement profile after its await.

## Qualification

**678 tests passed, zero skipped**, across thirteen suites: direct media/FSM,
camera intent, Android camera outcomes, media routes, group media/FSM/teardown,
three preference ownership/storage suites and the diagnostic journal.
`dart analyze lib test` reports no issues.

The added cases cover eight audio ownership scenarios, two optional-persistence
controls, two camera-profile scenarios and the pure ownership predicate without
reads. Normal system-role/explicit-device selection and capture rollback tests
remain intact. No device ID, user preference label or profile value from a real
installation is used.

All checks use TMPDIR=/private/tmp/. No GUI window, input injection, physical
camera/microphone capture, native build, installed-app change or seed operation
is performed. The existing user's Mac app remains running. No push or release
is performed.

## Separate group-call finding, still open

The first related run had 675 passes and one timeout in the existing group audio
watchdog fixture. That individual candidate case and both unchanged-base
watchdog cases subsequently passed; the final full related run also passes.
These observations do not establish the timeout's cause or erase it.

An independent gated probe confirms a concrete GroupService blockage:
broadcastGroupCallSignal awaits its sender inside the per-group mutation lane,
while ingestGroupCallFrame needs that same lane. With the sender gate held,
incoming validation cannot finish; after release the exact same frame validates
successfully. Its before-release assertion fails on the current implementation.
This is one assertion failure, not a timeout/performance threshold. Cleanup
releases the gate, joins both futures, closes synthetic stores and removes the
owned temporary probe. The probe source and result remain private for the next
cycle; it is not included in the 678 passing tests.

Production GUI/headless wiring uses MessagingService.sendGroupCallSignal;
heartbeats await live sending. The scope proven here is the held-sender/local-
validation dependency. A production mutual deadlock and attribution of the
earlier watchdog timeout are not established. This separate issue is active;
fixing it must preserve group/channel membership and epoch authorization, rather
than suppressing the watchdog or bypassing ACL checks.
