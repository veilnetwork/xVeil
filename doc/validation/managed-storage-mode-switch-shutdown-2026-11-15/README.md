# Packaged storage choices and retired service shutdown

## Storage evidence

The isolated macOS debug bundle runs the normal application entrypoint with
managed storage and its authenticated local driver explicitly enabled. It uses
synthetic identities in its own application namespace and profile. Onboarding
selects manual peers without adding any; no production relay or user container
is modified. The encrypted default was qualified in the preceding
[session-shutdown cycle](../managed-app-session-shutdown-2026-11-15/README.md).

This cycle explicitly selects **unencrypted** storage through normal onboarding.
The resulting payload has an ordinary SQLite header. After application lock,
ordinary SQLite opens its populated KV/log tables without a key. A synthetic
Unicode note is saved through the application's cloud service. After process
death, the real lock screen offers **Open without password**, and reopening
returns the same identity and the note's exact byte digest. The original three
encrypted payload files remain byte-identical across plaintext creation and
activity.

Normal onboarding then explicitly selects **hidden** storage in that same QA
profile. It creates a third, distinct identity in the legacy hidden container.
The public catalog still contains exactly the encrypted and unencrypted entries;
no hidden locator or count is added to it. A second synthetic Unicode note
survives process death and password unlock through the actual UI, including its
generic hidden-space selection. All four managed payload files remain
byte-identical across hidden onboarding and activity. Returning to both managed
identities preserves their identifiers; the plaintext note still matches.

These are mode-selection and persistence checks, not a proof of every
cross-mode migration, crash boundary or hidden-space deniability property.
Recovery certificate copying uses the real UI. The native save-file dialog is
not qualified. The preceding report's clipboard-preservation claim is corrected:
immediate restoration can be cleared by the later unconditional secret timer.

## Additional lifecycle defects

Immediate lock after a successful unlock exposed four uncaught storage errors,
even though all identity and note checks passed. A ready state is not a promise
that every startup reader has settled.

1. A fallback messaging provider can be retired by transport/provider
   replacement before the application closes its native stack. Riverpod starts
   disposal but cannot await it, and the controller previously had no owner for
   that retired instance. Its registered cloud/device-sync cleanup continued
   after storage or the ratchet handle had closed.
2. Eager conversations, pending-clear and messaging listeners could still
   start reads while the old ready identity remained visible during teardown,
   or when an eager listener returned on the locked screen.
3. Joining only cloud local loading missed its initial materialized index/claim
   publication. The next packaged candidate still exposed one uncaught cloud
   write and one Flutter build-time error; that candidate is not qualified.
4. A network status strip on the outgoing home route could resolve session
   services while lock/navigation was rebuilding it. It must be inert outside
   an admitted ready session, including during teardown.

A session-level owner now retains current and retired fallback-service closers.
The controller joins them before closing native handles or session resources.
Provider disposal and controller cleanup join the same future; errors remain
reportable, and a failed closer cannot skip independent resource cleanup.
Hosted all-online pipelines keep their existing session owner.

Fallback services outside an admitted session expose their usual streams but
start no readers, retries or mailbox registrations. Conversations and pending
clear readers use that same admission boundary. The network strip returns
before resolving network/session dependencies when admission is closed. The
cover-only screen lock does not end the ready session.

Cloud close now joins initial startup through the index/claim publication, then
removes subscriptions and timers. In production, the initial sync records are
read from the local device-group journal; background replica fetches/posts are
not awaited by startup. Close does not add a join on capability network rehosting.
Reconciliation stops before further cleanup/backfill when closed after publishing
its local views.

## Regression evidence

- The retired-provider control fails because lock finishes and storage closes
  before an explicitly gated accepted shutdown task. With the owner, lock waits
  and the task observes its still-open storage.
- The eager conversation control records a dependency read after admission is
  sealed. The fixed version records none and exposes empty lists.
- Four fallback checks count actual startup storage reads in ending, locked,
  preparing and recovery states. Disabling admission makes all four fail with
  one forbidden read each. The initial weaker stream-only checks passed with
  admission disabled and were rejected; they are not credited as controls.
- A gated first cloud publication proves that close previously returned while
  startup was still writing. The fixed close waits for that publication.
- Two widget controls fail when the banner resolves session dependencies while
  locked or ending; the fixed widget resolves neither.
- A failed-closer check retains its error through lock while confirming storage
  is closed and the application reaches its locked state.
- Final qualification passes **570 checks in 38 serial Flutter suites**, with
  source hashes and four pinned host-library digests unchanged throughout.
  Focused analysis of all ten changed implementation/test files is clean.
  The existing capability delayed-rehost regression passes unchanged.
- The disappearing-preview fixture now provides an identity together with its
  synthetic ready state. Its original expired-preview and stored-byte assertions
  remain intact; no production admission rule is relaxed for the fixture.

## Provenance and limits

The final rebuilt application completes six immediate ready/identity/data/lock
cycles: plaintext, encrypted, hidden, encrypted, hidden, plaintext. Both note
digests remain exact. Its full captured log contains 400 lines with no dropped
entries and **zero uncaught errors**. Each cycle uses the real native stack;
no timeout or error reporting is suppressed to obtain that result. This is a
bounded smoke qualification, not a claim that every lifecycle race is eliminated.

The consumed source manifest has 3,035 inputs. The copied project differs only
in its documented QA host names/identifiers. The rebuilt Dart kernel must contain
the new session-owner markers; its digest and the executable digest are recorded
separately from the native input and signed-bundle digests. Actual mapped native
libraries are checked against the bundle. The preceding report documents the
pinned SQLite reconstruction, hidden-volume asset and isolated Veil target.
The owned application is locked before termination, its actual process exit is
observed, and its debug port is closed. This does not qualify graceful exit or
power loss.

This remains a debug, ad-hoc macOS qualification. Release AOT, Android/Windows
packaging, platform-specific credential storage and full cross-mode maintenance
still require their own checks. Managed storage remains disabled in production
defaults. No push, release or production seed update is included.
