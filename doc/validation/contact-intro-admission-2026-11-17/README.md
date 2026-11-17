# Introduction admission must preserve a concurrent contact decision

Base: `6e36b333`. This continues the
[incoming request qualification](../incoming-contact-decision-2026-11-16/README.md).
It does not establish the cause of the reporting user's one-way Windows chat.

## Confirmed mechanism

An incoming request/reconnect prepared a pending contact, then discovered old
introductions and stored the greeting outside the contact decision lane. Accept
or block could finish while those reads waited. The old handler subsequently
evicted an earlier introduction and/or appended the new unverified request body
to an already decided conversation. The accepted fast path did not cover a
decision made after preparation.

The deterministic reproduction pauses actual MessagingService processing after
reading the cap candidates or after looking up the arriving introduction. It
then saves accept/block before releasing that read. On the unchanged base,
**eight assertion failures and four passing pending controls** verify the exact
message IDs: cap processing replaces an earlier ID; append processing adds the
new ID after the decision. Gates establish ordering, without timing thresholds.

## Change

Storage now provides guarded pending-introduction append and eviction. Both
recheck the latest contact under the same contact write lane as accept/block;
a synchronous owner/consent lease refuses work invalidated by a local decision
or service teardown. Candidate discovery stays outside the lane. Logical deletes
are protected by the lane and the existing erasure guard; required physical
scrubbing finishes outside the contact lane before return. Storage shutdown
joins the operation, including scrub.

Accepted re-requests still create a durable acceptance response. Blocked or
retired work declines carrier admission. Deleted/expired introductions still
follow the shared store's handled outcome. The normal message append, expiry
checks and required own-device publication path remain shared; no network or
async publication callback is run under the contact write lane.

An intermediate candidate protected message data but missed the acceptance
response/decline when the durable decision changed without the service cache
notification. Four assertion failures in the expanded fixture exposed that gap;
the final handler reads fresh consent and preserves those outcomes too.

A second gate after pending preparation exposed a late pending-status callback
after accept/block: **eight assertion failures and four controls** on the first
candidate. Notification now requires current consent and emits the actual
pending status, rather than the obsolete preparation result. This qualification
covers the service callback; it is not a physical sibling-device exchange.

## Qualification and limits

The final fixture has **36 passing cases**: three pause points, local and direct
durable accept/block, a pending control, and service shutdown, each on ordinary
asynchronous storage and the real hidden-volume worker. It checks exact retained
IDs, publication and decline outcomes, durable acceptance frames, current
contact status and history after closing/reopening the container.

**419 tests passed, zero skipped**, across eighteen related suites covering
consent, incoming/initial/retried requests, acceptance, handshake ingress/receipts,
mailbox stash, decision/preferences/publication, expiry and erasure.
`dart analyze lib test` reports no issues.

An existing outgoing-expiry test expected an empty replacement request after its
greeting expired. The same expectation fails with unchanged base contact/store
handlers: current submission intentionally refuses that send. Only the test was
updated to assert the typed refusal, absent request and absent Outbox frame;
no outgoing-expiry behavior was changed for that expectation. Fixture compilation
errors, a nonexistent suite path, a zero-test selector and an immediate network
send oracle for detached egress were excluded from defect evidence.

The native library was checked against the previously qualified artifact SHA
and all 50 current binding checksums, without a Rust build. Tests use
TMPDIR=/private/tmp/ and a separate synthetic container. No app window is opened
or activated, no keyboard/mouse input is sent, and the existing user's Mac app
remains running. Installed apps, native submodules and seeds are unchanged.
No push or release is performed. The original Windows 10 complaint remains
unattributed.
