# Warm recipient across device revocation — 24 October 2026

SDK **`cc52c17b`**, parent **`50fa7a2f`**. **PASS for the bounded local scenario.**
This improves discovery of signed revocations behind a warm sender-key cache;
it does not introduce instantaneous global revocation during partitions.

## Finding and correction

C had already authenticated B as a device of X. After missing A's revocation
of B, C could continue using that verified key. Receive-side revalidation read
only C's local DHT document; a warm ratchet did not necessarily take the
certificate-miss path that would compare reachable document holders.

An initial run with no repeated application traffic did not observe the new
document within 120 seconds after the first old-B attempt. This was not proof
of accepting a key after learning its revocation. In a subsequent old-SDK run
with B attempting messages every five seconds, the document eventually updated
and the post-update authorization checks passed. The defect is delayed refresh
behind a warm cache, not a demonstrated cryptographic verification bypass.

The receive callback now also schedules a background document comparison for
previously verified senders. It uses the existing verified freshest-holder
lookup and revocation-cache invalidation. Local document changes are still
applied synchronously before opening each packet. Unverified identity claims
continue through the separate bounded certificate warmer.

Document refresh has a 30-second per-sender cooldown, at most four starts per
second, four concurrent jobs, 128 recent entries and a ten-second job timeout.
These bound work, not guaranteed revocation propagation time. This adds bounded
DHT traffic for active known senders; it does not block audio/video on a lookup,
add relay priorities, expose media types or change mailbox policy.

## Independent-process experiment

A/B are X; C is Y. Three independent application/native workers and three local
relay processes use a sealed loopback island. Before revocation, B→C and
C→A/B messages arrive exactly once. Existing native admin bans block C in both
directions on all peers, including previous direct links. C reports zero native
sessions before and after A revokes offline B; its process stays alive and its
local document remains stale. B later restarts with its original device key.

The fixture lifts the bans without restarting C, sends C→X, then tries old-B
messages. It observes the current-document barrier using **local DHT reads**;
there is no forced fetch, document injection or cache reset by the fixture.

| Observation | Previous SDK | Corrected SDK |
| --- | --- | --- |
| C already has the current document before the first old-B attack | No | Yes |
| First old-B attack observed in C's history | Yes, before learning revocation | No |
| Additional wait from that observation to the document barrier | 44.872 s | 0.030 s; document was already present |
| After the barrier, new C→A message absent on B and new B→C attack absent on C for at least 60 s | Pass | Pass |
| Later A→C positive control | Pass | Pass |
| Full selected run, including startup and teardown | 202.859 s | 163.330 s |

The 0.030-second figure is a local observation after the document was already
present. It is **not** end-to-end revocation propagation latency. Both active
variants pass the two-minute document barrier; the old run is not reported as
a failing post-document authorization regression.

## Validation and limits

35 resolver tests and two shared lookup-budget tests pass, as do Clippy with
warnings denied, Rust formatting and Dart analysis. The new CLI and client
library were built together on the monitored external build volume, frozen,
and their hashes checked. All 199 existing native FFI exports are unchanged.
Hidden-volume remains `c4ba1fa8`.

This is protocol-level isolation through existing native admin controls, not
kernel network namespaces or every physical network failure. Negative evidence
comes from observed message histories, not a ciphertext-recipient/decryption
audit. No revoked call, clock skew, hours/days partition, Windows or physical
phone run on the new SDK is qualified here. The full multi-device checklist
remains open. The separate [phone file run](../poco-relay-bidirectional-2026-10-24/README.md)
used the preceding SDK and does not qualify this refresh change on Android.

All owned workers and relays exited; independent checks confirmed process
absence and removal of temporary fleet containers. Original fixture identities
were preserved. Public evidence is restricted to booleans, counts, timing,
source hashes and commit references in [summary.json](summary.json). Raw logs,
identifiers, keys, addresses, ports and payloads remain private. The original
untracked October 17 matrix was preserved.
