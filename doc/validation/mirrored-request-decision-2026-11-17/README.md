# Delayed mirrored pending status cannot replace a contact decision

Base: `aa36d84c`. This extends the
[contact decision qualification](../incoming-contact-decision-2026-11-16/README.md).
It does not attribute the reporting user's one-way Windows conversation.

## Confirmed mechanism

The current device-journal applier accepts pendingIncoming/pendingOutgoing status
events retained in device history. New pending events are no longer published,
but existing history can still be replayed. The messaging applier checked a
contact snapshot before writing an unconditional upsert based on that snapshot.

A local acceptance/block or preference update could commit while that read was
pending. The later mirrored upsert then restored pending status over the decision,
or overwrote the newer local name/pin. The existing fast-path check against an
already decided snapshot did not cover this ordering.

| Exact-base controlled case | Result |
| --- | --- |
| Two pending statuses × accept/block × ordinary/native worker | Eight assertion failures: durable decision replaced by pending |
| Two pending statuses × newer preferences × ordinary/native worker | Four assertion failures: new name replaced by old snapshot |
| Two pending statuses × absent/current/opposite pending record × ordinary/native worker | Twelve passing controls |

The combined baseline run has **12 assertion failures and 12 passing controls**.
The same 24 added cases are retained in the final suite. A gate pauses the real
contact read after obtaining its old value; the local decision/preferences are
saved before releasing it. No measured timing threshold establishes the race.

## Change

Mirrored pending statuses now use Storage.prepareContactRequest, which reads
and updates the latest relationship under the contact write lane. An acceptance
or block wins and is returned without another write; the obsolete mirror reports
no change. Pending-only changes preserve current preferences and outgoing consent
intent instead of copying the earlier snapshot.

Preparation does not grant/revoke accepted access and does not create a decision
floor or device-publication obligation. The existing ordered accepted/blocked
device-decision path and its durable ordering floor are unchanged. This adds no
mailbox delivery or wire-format change.

## Qualification and limits

**336 passed, zero skipped**, across fifteen related suites covering consent
races, incoming/initial/retried requests, primary acceptance, handshake receipts
and ingress, decision/preference sync, publication, archived policy and startup
consent. `dart analyze lib test` reports no issues.

The tests use the ordinary asynchronous store and real hidden-volume worker.
The selected native library matches the previously qualified artifact SHA and
all 50 current binding checksums, and remains unchanged after testing. No Rust
build is performed. Decision cases also verify retained pending-decision tokens,
actual CallService admission/refusal after the race, and durable status after
closing/reopening storage. Pending controls retain crossed outgoing intent;
no new decision publication is created for a doorbell.

All checks are headless with TMPDIR=/private/tmp/. No app window is launched or
activated and no keyboard/mouse input is sent. The existing user's Mac app stays
running. The fixture is not a physical sibling-device exchange, the reporter's
Windows 10 machine or a test of their visible chat widget. Original one-way-chat
cause remains open. Native submodules, installed apps and seeds are unchanged;
no push or release is performed.
