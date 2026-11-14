# Android microphone-service retirement

## Confirmed defect

A refused or exceptional stop reset the Dart cache to inactive. A subsequent
stop was skipped despite the missing acknowledgement. Two behavioural tests
failed on the previous code (the eight existing foreground tests passed).
Unknown stop results now remain unknown and the next stop retries.

This service carries the Android microphone foreground grant and notification;
it does not own or capture the AAudio samples. Stopping it is not proof that the
media engine, camera, screen projection or network resources are gone.

## Ownership and erasure integration

Direct and group media controllers bind a microphone-service lifetime before
awaiting permissions. Retirement seals that object, joins its accepted command
queue and prevents delayed permission results from adopting the next profile's
service facade. A cached acknowledgement is presentation state, never evidence
of resource absence.

The production background retirement composer seals microphone admission before
requesting daemon retirement. It then obtains a native microphone retirement
owner and checks both resource owners at the existing erasure barriers. Native
microphone admission is released before daemon admission; the fresh Dart
microphone facade is published only after the daemon release succeeds. Failed
or lost release replies retain the same owners for retry.

Android START intents retain the requesting Flutter engine, a local service
generation and the daemon generation. Retirement and ordinary owner-specific
stop invalidate queued STARTs. An old engine cannot stop its replacement. A
late obsolete intent cannot tear down an already active replacement instance.

Native retirement requires the daemon's admission gate to be sealed. It releases
foreground state on every tracked service instance, retaining uncertain or
failed owners, and independently checks the application's own service status
through ActivityManager. Missing observations refuse retirement. The receipt
proves observed foreground-grant release and fenced reacquisition, not completion
of every Android onDestroy callback. No token, engine identifier or service list
is exported in an error message.

## Validation

- 231 checks passed across eight Flutter suites: foreground service, microphone
  lifetime, background lifetime, direct/group media and teardown, plus native
  profile-wipe and guard fixtures.
- New lifecycle tests exercise accepted/reentrant operations, late permission,
  acquisition refusal, missing native support, lost release replies and the
  permanent sealing of old facades after fresh admission.
- The native profile fixture uses the production background composer. Refused
  microphone retirement preserves payloads and keys before an erasure intent;
  a later adverse resource observation preserves them before native deletion.
  These tests model only microphone OS facts; profile workers and their file
  erasure are real native operations on synthetic data.
- Removing microphone verification from the composer made the second fixture
  fail at its actual payload-preservation assertion. The mutation was restored.
- The native service-gate smoke passed. Three mutants (accepting stale STARTs,
  stopping a different engine, ignoring remaining foreground state) failed.
- All 16 actual application Kotlin files and current SDK sources/resources
  compiled and packaged into an isolated debug APK. Source hashes matched before
  and after compilation; the harness has no Flutter application assets and is
  not a runtime client qualification.
- Analysis of the eight affected Dart files reported no issues. Source manifests
  and native-library hashes were checked around the host suites.

## Remaining boundary

Hardware permission/foreground behavior is not established by the host model
or by APK compilation. Real Android start/stop, foreground-service restrictions
and actual microphone capture still require device qualification. AAudio,
other capture sources, Wi-Fi locks, independent shutdown/cold recovery and
packaged migration/maintenance remain separate gates. The managed-storage
feature remains off by default. No push or release is part of this cycle.
