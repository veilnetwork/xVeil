# Attachment capture at privacy boundaries

## Confirmed defects

Three behavior tests failed on the previous implementation:

- The in-app screen lock could cover a still-open attachment camera.
- A photo/video chooser opened before that lock could start capture after the
  lock/unlock cycle.
- Full container lock did not reach an independently owned attachment camera.

These are host reproductions using real lock controllers and the production
capture widget/actor over a modeled camera backend. They are not attribution of
an earlier camera, call-audio or user-storage report.

## Change

Both privacy-lock entrypoints now interrupt registered attachment work before
publishing the lock or awaiting teardown. Only privacy-sensitive attachment
resources participate; the registry does not hang up ongoing calls when the
screen cover is raised. Strong whole-profile retirement remains separate.

An admission is captured before a chooser/permission await and bound to its
original profile and privacy generation. Lock invalidates all old admissions
synchronously. Old widgets, delayed choices and late outputs cannot acquire a
fresh one on resume. A new user action after unlock can obtain a fresh admission.

Known output files retain cleanup ownership even when their admission has
expired. Lock prevents a new consumer, joins an already accepted reader and
attempts deletion. Failed cleanup stays registered for retry and strong erasure;
errors do not become successful absence or a request to repeat a completed send.
No global registry is cleared or replaced to simulate shutdown.

## Validation

- All three integration tests were behavioral failures before the fix, then
  passed: actual screen-lock controller with capture widget, a delayed chooser,
  and actual container-lock controller with an independently owned camera actor.
- 419 checks passed across 24 serial Flutter suites: capture ownership/output,
  camera/direct/group-call/recording lifetimes, native profile-wipe/guards,
  composer/bounded files, application teardown and screen-lock policy,
  identity changes, verifier lifecycle and throttling.
- The screen-lock case additionally verifies that lifecycle resume cannot revive
  the old camera and a fresh explicit capture after unlock can open a new one.
  Registry tests distinguish privacy-sensitive resources from call resources,
  reject foreign/old admissions and retain refused cleanup for erasure retry.
- File tests hold an accepted reader through privacy interruption and verify a
  stale late output remains cleanup-owned but cannot be consumed. Native wipe
  fixtures still preserve actual synthetic payloads and key records on refusal.
  The refused-file fixture counts attempts before retry rather than assuming
  only one cleanup request can occur during the enclosing lock/wipe sequence.
- Analysis of all ten affected Dart files reported no issues. Frozen source
  inventories and four pinned native-library hashes matched around test runs.
  No native engine or packaged application was rebuilt. ADB listed no devices;
  runtime Android qualification was not performed.

## Boundaries

Actual Android/iOS camera shutdown and physical privacy behavior still require
runtime qualification. The capture registry is process-local; independent native
media shutdown and cold profile recovery remain open. This change does not claim
that every microphone, call, projection or native writer has stopped. It does not
change the existing screen-lock policy of retaining an open container/network.
Managed storage remains disabled, and no push or release is part of this cycle.
