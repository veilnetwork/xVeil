# Android projection ownership during profile erasure

## Confirmed defects

Two behavior tests failed on the previous implementation: whole-profile capture
retirement overlooked a running screen projection, and a source constructed
before erasure could request capture after the next profile was admitted.
The prior session-specific stop protocol already joined pending consent and
retained failed native cleanup; this change makes it reachable by profile erasure.

## Change

A projection captures its profile lifetime at construction and registers before
accepted consent work. Retirement immediately stops frame delivery and requests
session-specific native cancellation, then joins the accepted start reply before
releasing its resource registration. Failed cleanup stays registered for retry.
A late successful start cannot restore the retired source.

Denial or a busy channel may release an unused registration. A later retry must
re-register with the original lifetime; it cannot join a new profile. Sources
created late by direct/group call controllers receive those controllers' original
capture lifetime, rather than reading whichever lifetime is current after awaits.
Profile admission sealing rejects frame-sink rebind and drops subsequent frames.

The existing channel/session owner remains authoritative. An old stop cannot
stop or detach a replacement, and registrations are forgotten only after both
accepted start/stop work and channel ownership have ended. An ordinary screen
privacy cover does not stop an ongoing screen-sharing call. Whole-profile
retirement has its separate stronger semantics.

## Validation

- Both prior-code behavioral regressions passed after the fix. Additional cases
  cover pending consent, native-stop refusal/retry, immediate frame/rebind
  fencing, a busy source retry, late source construction and preservation of
  ongoing screen-sharing under an ordinary privacy cover.
- 441 checks passed across 27 serial Flutter suites: capture ownership,
  direct/group media, application teardown, screen locks, native profile wipe,
  projection lifecycle, permission handling and desktop screen transitions.
- The native erasure fixture verifies that refused projection stop preserves
  actual synthetic payloads, six OS-key fixture records and absence of an
  erasure intent. Retry reaches the same session and completes deletion. A
  second fixture holds consent while cancellation has already been requested;
  erasure waits for that accepted reply before removing payloads and keys.
- A deliberate registration-omission mutant failed at the actual
  payload-preservation assertion: the synthetic legacy file was removed.
  Production sources were restored before the passing broad suite.
- Two projection erasure cases passed again after a test-only brace cleanup.
  Analysis of all five affected Dart files reported no issues. Frozen source
  inventories and four pinned native-library hashes matched around runs.
  No Android/native engine was rebuilt or installed.

## Limits

Method-channel projection facts are modeled. The native fixture uses real
profile workers and filesystem erasure on synthetic data, with synthetic OS-key
records. It does not prove physical MediaProjection or foreground-service
shutdown. The existing Android implementation is unchanged in this cycle.
Independent native observations and device qualification remain necessary;
method-channel acknowledgement and an empty Dart registry are not substituted
for them. AAudio/Camera2, Wi-Fi resources, cold application recovery and packaged
migration/maintenance remain separate requirements. Managed storage remains
disabled. No push, device installation or release is part of this cycle.
