# Transactional addition to an existing master

Status: routed conversion and existing-master addition use the journal and
authenticated recovery path. Final qualification is recorded below. Managed
production defaults remain OFF; this is not a release or physical/OEM claim.

## Preserve the original roster without a smaller limit

The existing-master path previously created a child and wrote its profile
before publishing the new roster. Its earlier conversion receipt stayed in
place: there was no durable append plan to recover an interruption between
those steps. This did not prove the cause of an earlier user report.

Routed additions now persist the exact planned child before creating it and
record its actual keys before personalized payload. The same controller and
recovery screen handle both conversion and addition. The screen describes an
interrupted addition separately in all supported languages.

Conversion keeps its existing self-contained v1 record. Append uses a bounded
v2 record containing the original roster's row count and SHA-256 commitment,
the parent key witness and planned child. The original roster stays durable
in the master throughout the operation. It is not duplicated into a 16 KiB
journal or truncated to the conversion record's 32-row bound.

Append decoding requires the actual strict roster. It accepts either the exact
original rows or those rows followed by the exact already-known child. Every
original label, key, locator, anonymity value and order is bound by the digest.
Missing, changed or unrelated rows refuse recovery without replacement. The
count guard exceeds the number of minimum-size rows fitting the application's
existing roster-file ceiling; existing row labels retain their original size.
The small atomic writer and file format limits were not enlarged.

Each fresh attempt also gets a random 128-bit identifier, retained across its
snapshots/key attachment and bound into its receipt. Identical parameters do
not authorize an old abort against a new attempt. A regression demonstrated
that failure before this identifier was added. The identifier in the current retired receipt cannot be
prepared again as fresh work. Accepted older plans without a tag remain
readable/recoverable; they cannot be newly prepared after retirement. The tag
is private operation metadata, not a password verifier or an authentication key.

Before the first await, request ownership includes the complete private roster
snapshot even though serialized append metadata is compact. Temporary loaded
keys and encodings are wiped. Hash-set duplicate checks avoid a quadratic scan
when materializing a large roster.

## Completion, refusal and uncertainty

The parent accepts only an absent/exact roster for conversion or an exact
base/full roster for append. It verifies the full roster before atomically
publishing its non-replayable completion receipt and cleared pending marker.
Supported unjournaled older masters can start an addition after strict roster
validation. A prior receipt must have the recognized complete/aborted shape;
unknown or malformed records are not reset.

A new conversion root still requires bootstrap-only data. An existing master
may contain other settings/files: addition preserves them instead of requiring
the whole master to be blank. Profile, node-credential and conflicting pending
operation guards remain; no child, arbitrary file or unrelated setting is erased.

An explicitly rejected foreign/occupied candidate receives no personalized
write. While its keys are still unknown to the plan, the owner can atomically
replace that exact obligation with an aborted receipt and clear pending-master.
The original roster remains unchanged. This prevents a reused hidden password
from stranding an otherwise valid master. An advanced plan cannot be aborted;
a stale abort cannot cancel a replacement plan. No candidate deletion or scan
of unknown hidden spaces was added.

On a transient failure, normal addition parks the actual pending parent for
authenticated continuation rather than restarting an old active child. A
failed router factory can retire its old facade without changing the locator;
recovery therefore selects a fresh facade at that exact authenticated root.
This was caught by six normal-operation failure controls during implementation.

A lost final reply is different from an uncommitted addition. Its test reached
the actual native completion commit but reproduced restoration of an obsolete
cached membership. That path now locks and clears the cache, allowing ordinary
authenticated unlock to classify the durable full roster. It does not hide a
committed new child behind a resumed old view or claim an uncertain result was
an uncommitted operation.

## Evidence

- The previous application path failed all four updated ordinary creation /
  append / cold-open cases: the latest append or refusal had no matching
  operation receipt. Two cases exposed the old conversion digest; two expected
  the new explicit aborted status. This is protocol evidence, not a claim of
  reproducing a user's original data-loss scenario.
- Twenty-four deterministic model/journal cases cover large commitments, owned
  snapshots, changed base/child fields, second additions, abort refusal/retry,
  lost abort replies, stale aborts with changed or identical parameters,
  retired attempt reuse, accepted legacy records and malformed metadata.
- Six actual AppController/native factory-failure cases cover conversion and
  append in every master mode. The planned slot is saved before creation;
  continuation is offered without a new node-start request, and the original
  source reopens with its payload and keys unchanged.
- Forty-two controller cases start after actual SIGKILL checkpoints: conversion
  and append each cover all nine preparation mode combinations plus later
  child-created/key-known/profile/roster boundaries for every master mode.
  Ordinary cold entry returns to both identities, preserving source data and
  already accepted newer child data.
- Three native large-roster cases retain 128 reference rows through addition
  and a cold handle reopen. The fixture contains one actual original source
  and synthetic additional references, not 128 running identities. Its roster
  exceeds 48 storage chunks while the append record stays below 16 KiB.
  An extra master setting/file and the actual original source payload survive.
- The lost final-reply regression failed with an old ready view before its
  handling changed. It now verifies locked state, ordinary reauthentication,
  the full two-row membership and access to both actual stores.

The initial broad run also exposed over-strict bootstrap inspection against
legitimate master metadata. The corrected append branch and the existing
mixed-roster/erasure tests pass targeted checks; conversion inspection remains
strict. Development fixture-size mistakes and compilation errors are not
counted as product regressions or successful qualification.

The final frozen-source run passed all 289 tests across 28 suites, with no
skips (8 minutes 49 seconds). Full-library analysis plus changed test/support
files completed without issues. The 23-file source/test/localization digest
manifest matched before and after qualification.
The existing native library's hash and source provenance were verified. No Rust
source, native package or GUI application launch changed in this cycle.
Process-death checks are not power-loss or physical-OEM qualification. Node
start counters verify controller admission, not real socket teardown.

## Remaining activation work

The legacy non-router creation path remains separate. Universal router/default
activation, destructive maintenance and Windows directory durability,
credential/model inventory, packaged cold recovery including custom-source
compaction, physical OEM checks, release AOT and all-target native packaging
still need their full qualification. Existing hidden data must not be silently
migrated or dropped to enable the new enumerable encrypted default.
