# Contact-request API admission

## Confirmed defect

`POST /v1/contacts` treated the legacy `MessagingService.sendRequest` boolean
as local submission success. For a pending contact, that boolean describes
relay deposit. The service already persists the complete request in the local
Outbox before either relay or live delivery.

When relay deposit failed, the GUI-hosted API and headless twin therefore
returned HTTP 400 with “nothing was sent; try again”, although the request
and its greeting were already admitted and eligible for retry. This can invite
an unnecessary duplicate command. It is a confirmed API classification defect,
not an attribution of the reported one-way Windows conversation.

## Change

The messaging service exposes a typed contact-submission result: refused,
durably queued, relay-deposited, ordinary message submitted, or an allowed
empty no-op for an accepted contact. Both API hosts use local admission.
The existing `sendRequest` boolean contract is preserved for UI callers.

HTTP success still uses the existing response shape and does not promise
delivery, relay acceptance or peer consent. An invalid invite, blocked contact
or failed durable enqueue remains an error. No wire format, consent decision,
retry policy, ratchet barrier or own-device mailbox policy changes.

## Evidence

The regression drives the actual HTTP endpoint, provider wiring, messaging
service and storage adapter with an in-memory KV backend. Its relay explicitly
throws on every deposit. Before checking HTTP status, the test proves that
deposit was attempted but refused, and that exactly one request is durable,
addressed to the intended peer and sharing the stored greeting's ID.

The original implementation produced **five passes and one assertion failure**:
all durable-state assertions passed, but the HTTP response was 400. An earlier
fixture changed only the relay's own registration flag and inherited successful
deposit; its six passes did not reproduce the failure and are not credited as
baseline evidence.

The final ten-case HTTP suite also checks successful relay deposit, invalid
bare IDs, blocking without any new greeting/queue/deposit, refusal before
Outbox admission, and both ordinary-message and empty-no-op behavior for
accepted contacts. Three of these ten cases check target validation, including
the headless source-wiring control, rather than exercising HTTP.

**262 related tests pass, zero skips**, across 13 suites: API, identity-bound
bearers, request restart/retry, consent, handshake ACK/ingress, Outbox and the
headless contract. Native-storage variants use a previously qualified library
after matching its recorded SHA-256 and validating all 50 current binding
checksums. A preceding run without that library passed 254 tests and skipped
eight native controls; it is not credited as native qualification.

`dart analyze lib test` reports no issues. The real Flutter-free CLI entry point
also builds as AOT and exits successfully with `--help`. This checks compilation
and startup, not an actual headless contact exchange. The HTTP transport and
relay are controlled fixtures; the user's Windows 10 hardware, interactive
conversation and network remain open.

All checks run in the background without launching an application window,
changing focus or injecting input. The already running user application stays
untouched. No push, deployment or release is performed.
