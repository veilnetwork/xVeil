# Durable master-creation intent: preparation backend

Status: backend foundation qualified; application creation/recovery integration
is still incomplete. Managed production defaults remain OFF. No release or
platform activation is implied by this report.

## Problem and scope

Pending-master admission already prevents an unfinished master from becoming an
ordinary identity. A marker alone cannot reconstruct the original source roster
or the intended new child after process death. The normal application creation
path still needs to retain these facts before creating that child.

This change adds a bounded, private creation-intent codec and preparation
backend. It does not yet connect the backend to `AppController`, initialize a
child profile, publish a completed roster, clear the pending marker, activate a
node or delete anything. Full authenticated recovery remains required.

## Persisted boundaries

- The intent contains the exact root locator and key witness, copied source
  rows, and the planned child locator, label and anonymity before child keys
  exist. It never persists a password. Actual child keys can be attached once;
  changed source rows, locators or replacement keys are refused.
- The intent and pending-master marker are published together using the
  existing `StoredFileSettingWriter` transaction. Unsupported stores refuse;
  there is no sequential file/marker fallback. The codec stays within the
  writer's existing 16 KiB bound, with at most 32 base rows. Count admission
  alone does not guarantee that maximum-length labels fit the byte bound.
- Root authentication compares the declared witness and the opened store's
  exported keys. The caller must retain exclusive storage-operation ownership
  and perform generation checks; this backend is not a concurrent-owner lock.
- A separate read-only master inspection permits only bootstrap data, this
  private intent and an absent or exactly matching completed roster. It does
  not widen ordinary identity-bootstrap inspection. Existing profile, node
  configuration, sovereign credentials, foreign metadata, conflicting setup
  stages or changed roster data prevent writes.
- Requests snapshot sensitive buffers before their first await, returned
  intents own their buffers, and temporary key/encoding buffers are wiped.
  Exact accepted retries are read-only. A cancelled or lost reply does not
  replace an accepted publication with an empty state.
- Intent data stays inside the selected protected master, outside the public
  catalog and preference metadata. In an explicitly unencrypted master this
  data has the same plaintext exposure as its existing roster and linked keys.

Attaching a child key records the authenticated owner's supplied key; it does
not independently prove the child's contents. The future application owner
must reopen and reconcile that exact planned child before payload writes or
activation. Completion also needs a durable final receipt protocol so a later
retry cannot replay an obsolete secret intent.

## Qualification

The final sequential Flutter run passed **120 tests across nine suites**, with
no skipped cases. It includes codec/journal controls, atomic file-and-setting
publication, strict identity/master admission and existing identity recovery.
Analysis of the changed library areas and new fixtures reports no issues.

Nine host-native cases cover three storage modes and three real child-process
SIGKILL boundaries: immediately before atomic publication, after base-intent
publication, and after recording the physically created child's actual keys.
The parent verifies exit by SIGKILL, reopens the real store and checks marker /
intent agreement, exact root keys, original source profile and sentinel,
catalog preservation, and the child's actual keys where applicable. Before
publication, both marker and intent are absent and preparation can be retried.
After publication, the accepted intent remains readable. No master profile or
completed roster is published by these tests.

Deterministic controls also cover caller-buffer mutation, wrong root/key,
conflicting or malformed records, cancellation before and after commit, lost
commit replies, unsupported writers, immutable child attachment and changed
inline/chunked rosters. Fixture compilation failures during development are
not counted as product regressions or successful qualification.

The native library's hash and unchanged Rust-source provenance were verified
before the runs. No Rust source or native packaging changed in this cycle.
These are host process-death checks, not power-loss, physical Android/OEM,
Windows durability, release-AOT or full application qualification. No GUI
application was started for this cycle's checks.

## Remaining work

Connect ordinary master creation to planned-child allocation and atomic
preparation; reconcile interrupted child creation without replacement on
authentication failure; record actual child keys before personalized payloads;
finish child/roster publication and a durable non-secret completion receipt;
then wire authenticated application recovery with cancellation and lifecycle
ownership. Qualify those complete paths before considering default activation.
