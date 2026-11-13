# Network handover notifications for independent identity nodes

Status: **confirmed mechanism, released in xVeil 0.13.100+119**.
[Release qualification](../release-0.13.100-2026-11-13/README.md).
SDK, storage, native media and call timeouts are unchanged.

## Failure and reproduction

The application had one `NetworkReconnect` queue for every online identity.
One notification used `Future.wait` to contact their independent nodes. Initial
notifications ran concurrently, but the next attachment generation waited for
every previous receipt. A node still waiting for IPC therefore held back the
next handover of another node whose previous receipt had already completed.

Two controlled tests fail on the released provider: block either the active node
or another online identity at its notification boundary, then publish a cellular
observation. The healthy node still has only the previous Wi-Fi notification.
The gate remains closed throughout the failing assertion: no elapsed-time
threshold, delayed timer or mobile-provider behavior is needed to reproduce it.

This is an application dispatch barrier. It is not evidence that the original
single-identity NETCALL-01 pauses, TCP delivery stalls or provider restrictions
were caused by this barrier.

## Change

Each concrete identity transport now owns its existing serialized
`NetworkReconnect` queue. OS events and the initial platform query are shared.
The queue still waits for that node's receipt, coalesces newer observations,
deduplicates duplicates and retries failures with the original bounded backoff.
One node's pending operation no longer holds the other queues.

Provider changes initialize newly online nodes from the latest observation.
Each OS event also refreshes session targets, preserving the old fresh lookup
when a session changes its node set without replacing its provider value.
An active identity also present in the all-online session is notified once.

Removing a node cancels its observation/retry owner. An already admitted native
operation is allowed to settle; re-adding that same transport waits for its
completion before creating a fresh owner. This keeps one native notification
per transport even across removal/re-addition. No abandoned queue of successor
operations is accumulated. Disposal cancels source subscriptions and timers.

An intermediate candidate failed both the returning-node overlap check and the
in-place session refresh check. Those candidates were corrected before the
final related suite; their failures are not counted as green checks.

## Qualification

- **24 network tests**, including the two original assertion-red cases, pass.
  New cases cover blocked active/background identities, latest-generation
  coalescing, a returning busy node, dynamic addition/removal, initial-query
  staleness, an event with no nodes online and provider disposal.
- **358 related tests passed, zero skipped** across network reconnect, call
  service, route serialization/qualification, receive activity, network activity
  and direct-endpoint service tests.
- Scoped analysis and formatting pass. SDK/HV revisions and native pins remain
  unchanged. No Rust build or hardware qualification is included in these
  results. Ordinary cellular handover and the original call pause remain open.

The report contains no addresses, account labels, transport/call identifiers,
container paths, raw logs or correlation tokens. Private test logs retain the
red assertions and final results separately.

[Provider](../../../lib/state/network_reconnect.dart),
[regressions](../../../test/network_reconnect_test.dart).
