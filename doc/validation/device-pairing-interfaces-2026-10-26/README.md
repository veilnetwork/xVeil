# Device pairing interfaces and independent device checks

Local work after the published 0.13.93 release. No release, push, production
installation, public relay deployment or user-profile migration was performed.

## Confirmed LAN defects

The QR advertises up to six local addresses. The client previously tried them
sequentially: an endpoint accepting TCP but never answering held a working
endpoint behind its 12-second read timeout. Several such waits could exceed
the UI's 20-second no-response timer. A real-socket regression failed its
two-second completion bound before correction and passed afterwards, including
closure of the losing connected socket.

Exchanges now race at most six distinct endpoints and accept only a successfully
AEAD-authenticated response. Winning TCP establishment alone is insufficient.
The existing connect/read time limits remain; pending connection tasks and
connected losing sockets are cancelled/closed. Repeated request/ready messages
are already idempotent in the owning ceremony. No mailbox fallback was added.

The server previously closed every listener if any discovered interface failed
to bind. A discovered adapter can disappear before the asynchronous binds finish.
A real-socket regression failed with a socket error before correction. It now
passes for either ordering of reachable/missing interfaces, verifies an actual
encrypted exchange and advertises only the successfully bound host. If none
binds, startup still fails; wildcard/multicast rejection is unchanged. The QR
screen uses the actual bound host list instead of the discovery candidates.

Validation: 44 pairing, invite, link and device-screen tests passed; three-file
static analysis and whitespace checks passed. Tests include faster invalid AEAD
responses, bounded/deduplicated fanout, wrong tickets, unavailable endpoints,
large token exchange, restart ordering and both LAN regressions. Dual-stack
loopback fixtures model independently reachable endpoints; this does not add
IPv6 addresses to production QR discovery or relax its private IPv4 validation.

## Independent A/B/C protocol checks

Current native CLI/FFI were built together from local Veil e01a79d9 with no
compiled-in seeds, using the guarded external target filesystem. No low-difficulty
feature was selected. Three independent application processes used encrypted
fixture containers and a local three-relay island. A/B shared an identity; C
used another. These tests exercise the existing linking hooks, not the full
one-QR UI sequence.

- Old A/C history arrived on newly linked B. Incoming C text reached A/B;
  outgoing A text reached B/C with the same logical ID. B-to-C authenticated
  delivery was established before revocation checks.
- With B stopped, A sent text to C. C then stopped; a new B process recovered
  the text while A remained available. No claim is made for recovery without
  any source online.
- After offline revoke and document propagation, old B did not receive new
  identity traffic or deliver marked text/call attempts to C during the bounded
  observation, and re-admitting that revoked physical key was rejected.
- C rang both A and B. Simultaneous accepts converged to one active media
  endpoint; the winner's and C's receive counters advanced, and hangup
  finished the call everywhere.
- A separate anonymous run made B answer without an explicit C/B join, first
  while A was online, then with A stopped. Both runs received onion audio RTP
  in both directions, counters continued advancing over five seconds and B's
  hangup reached C. Aggregate timings/counters are in results.json.

All three process tests passed. This is protocol/state/packet-flow evidence,
not a live speech, camera quality, Windows 10, physical Android or full QR UI
qualification. It does not establish that every symptom in the user's Windows
report has been resolved. The complete 63-scenario campaign was not rerun.

All owned worker/runner process groups and relay processes were verified exited.
Logs, bearer keys, native clocks, fixture containers and identifiers remain in
private evidence storage; only aggregate counts, relative timings and labels
A/B/C are recorded here. Unrelated existing validation files were preserved.
