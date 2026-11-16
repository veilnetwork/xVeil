# Request feedback belongs to its current owner and view

Base: `720a140c`. This is presentation/command ownership work following the
[manual-retry admission fix](../contact-request-retry-2026-11-17/README.md), not
attribution of the original Windows 10 handshake report.

## Confirmed behavior

A delayed failed relay result displayed “request saved, waiting for delivery”
after the view had already shown acceptance, blocking or cancellation. It could
also display that warning after switching to another identity while the chat
State remained mounted. Both initial requests and manual retries had this path.

The warning's retry action also invoked its captured old messaging service
before checking whether the view still belonged to that identity. In an
all-online session the old service remains live by design. Changing the active
identity must not let an unrelated view initiate another request through it.

The original widget fixture produces **nine assertion failures and four passing
controls**: eight obsolete-warning cases plus the old-owner retry invocation.
Service outcomes and contact snapshots are controlled here. The fixture proves
UI behavior/service invocation, not an actual packet sent to a remote peer.

## Change

Request feedback checks the view's captured storage owner, peer and confirmed
pending contact snapshot. Completed relationships, loading/error snapshots and
another active owner cannot receive the old outcome. UI snapshot state controls
feedback only; durable consent remains enforced by the messaging service.

Initial requests now use the existing typed submission result: only a positively
admitted queued request can produce the saved-copy warning. A refused operation
does not imply that a durable copy exists, even if the presentation lags.
Submission/scroll/focus continuation also checks the originating owner.

The existing export ownership helper is renamed for this shared use without
changing its predicate. The strict source-inventory ownership test keeps the
same single allowed current-store comparison; sends and file operations still
use their captured service/store rather than retargeting to a new identity.

Snackbar retry captures its owner scope. At invocation it compares that scope's
current store with the captured one and invokes only the captured service.
Scope expiry/refusal makes no command. Leaving the chat under the same owner
still permits the existing retry; an unmounted page does not receive feedback.
An initial mounted-only candidate accidentally removed that valid behavior.
A dedicated positive control failed it; the final implementation preserves it.

## Verification and limits

The expanded **17-case widget suite** covers the nine baseline cases, unchanged
pending false/true results, typed refusal with stale pending presentation,
retry after page replacement under the same/different owner, and invocation
after disposing the captured owner scope.

**130 related tests pass, zero skips**, across eight suites: request feedback,
chat consent/ownership/read windows, file/document export and service retry/
mailbox behavior. `dart analyze lib test` reports no issues. The new UI fixtures
use controlled services and in-memory view state; the preceding service/native
admission qualification remains separate.

This does not classify a local enqueue exception as a successful queued result,
change exception/recovery policy, recall network work already admitted under the
correct owner, or prove peer receipt. Feedback follows the current confirmed
view snapshot; it is not an independent durable-state attestation.

No widget test opens a host application, changes OS focus or injects OS input.
Synthetic views, service owners and scopes are disposed, and the existing user
application remains running. No native source, data format, hidden-volume ABI,
installed package, real conversation, phone or relay changes. No push/release.
