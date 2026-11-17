# A retired Android video renderer must not stop its successor

Base: `8093a381`. This fixes a local decoded-video surface lifetime family.
It does not attribute the original Windows 10 waiting-camera report.

## Evidence

MainActivity owns one remote-video renderer, but the Dart bridge tracked only
an instance-local generation. Starting another bridge did not retire the first
one: its later stop or stats reply could clear the current global texture and
stop the new native surface. A cancelled start also sent an unconditional global
stop, and a start waiting for its initial stop could resume after cancellation
and attach the old engine. A failed current start did not request cleanup.

Twenty-two gate-controlled cases run against the unchanged base: sixteen fail
by assertion and six controls pass. They cover same/replacement bridge objects,
late success/malformed/failure responses, initial stop cancellation, old live/
stopped stats, explicit retired-owner stop, normal success/refusal, detach reply
fences, synchronous notifier reentrancy and the polling gate.

The fixtures preserve command FIFO: a command changes the synthetic native
resource when received; only its already-produced asynchronous reply is held.
A late direct stop by an obsolete bridge reproduces the bug without relying on
reply reordering. This is a controlled platform-boundary reproduction, not proof
that every synthetic delayed-reply schedule occurred on a physical device.

## Change

The shared platform resource has one request owner, claimed before the first
await. Replacing a request retires its old local texture, diagnostics and timer.
Only the current owner can publish state or send a platform stop. Late startup
and stats replies are ignored; a failed current startup cleans up its own source.

Stop acknowledgements are tracked for both the initiating and retiring owners.
An obsolete bridge can still join its detach fence before its caller frees the
old engine, without issuing a stop of the new surface. Existing best-effort
platform teardown error handling is retained.

The stats timer is installed before publishing the texture: synchronous notifier
listeners may stop or replace it. Startup rechecks ownership after publication.
An old poll's finally block cannot reopen the timer gate of a newer request.
Explicit stats requests remain supported alongside the bounded periodic poll.

Two deliberate mutants verify the delicate boundaries: moving timer creation
after publication produces two orphan-timer assertion failures; removing the
superseded-start detach wait produces two premature-completion assertion failures.
Both mutants are restored byte-for-byte before final qualification.

No platform-channel method/argument, native ABI, codec, wire, permission or
transport policy changes. No image or sound data is recorded.

## Qualification and limits

**751 related tests passed, zero skipped**, across eighteen suites covering
media startup, direct/group call FSMs/controllers, native camera/video lifecycle,
plugin capture/retirement, diagnostics and the video-frame widget. With
XVEIL_DIAGNOSTICS=true, **198 tests passed, zero skipped** across six overlapping
media/diagnostic/widget suites. These counts are not added as unique cases.
`dart analyze lib test` reports no issues after new test-style findings were
corrected.

Selected core/storage libraries match their producer hashes and 1,144 recorded
Rust/Cargo inputs. All fifty current hidden-volume binding checksums match;
selected binaries remain unchanged after testing. No native build is performed.

Two early candidate assertions compared the initial zero-frame texture to the
legitimate first stats update. Those oracles were corrected by settling current
stats before taking the comparison snapshot; they are not project findings.
The final base counts above use the corrected fixture.

All checks are headless with TMPDIR=/private/tmp/. No app window, focus change,
OS input, installed-app replacement, phone operation or seed operation is used.
Physical Android/Windows 10 capture, network video delivery and the full call
teardown matrix remain outside this component qualification. No push or release.
