# Public cloud capability links

Status: CLOUD-2B multi-provider v2 is implemented and cross-device verified.
Legacy single-record descriptors remain published for old resolvers.

## Privacy and authority

A link is a bearer capability for one immutable cloud revision. It grants no
membership, write, list, delete or identity lookup authority. The fixed binary
`xveil://cloud/v1#…` fragment contains a random 256-bit share id and bearer key,
the random onion-service public key, a capability-scoped app id, endpoint,
expiry, and an AEAD-encrypted manifest. Neither the URL, public descriptor nor
request transcript contains the owner's sovereign `node_id`.

Manifest metadata and every 2 KiB content chunk use ChaCha20-Poly1305 with
context-bound AAD. A request MAC binds the share, temporary return service/app,
endpoint, piece, chunk and nonce. Malformed, unauthorised, expired, revoked and
unavailable requests are dropped silently. Decrypted bytes remain in RAM and
verified plaintext is committed only through the deniable content store.

Revocation first removes the local handler and encrypted active-registry row,
then withdraws the descriptor asynchronously. The active/revoke event is also
replicated in the signed device-group log; trusted group history can therefore
retain the previous encrypted event until group compaction. Revocation cannot
erase a copy already downloaded by a bearer, which the UI states explicitly.

## Implemented network shape

veil-core/veilclient now provide random ephemeral onion identities whose seeds
are zeroized after provisioning, blinded DHT descriptors, idempotent withdraw,
and node-independent capability app ids derived from a high-entropy alias. The
Flutter transport keeps capability traffic on a separate IPC client so normal
mailbox/rendezvous work cannot head-of-line block it.

An owner hosts up to six active shares on endpoint slots 40–45. A recipient
creates a transient random return service on its own IPC connection, requests
bounded chunks anonymously, authenticates each response, verifies the manifest
piece hash, and only then adopts the content id without copying an existing
blob. Retiring provider endpoints are not reused until native descriptor
withdrawal finishes.

Owner devices converge the encrypted share seed/link and revoke tombstone via
the signed sovereign device-group log, and host the same pseudonymous service
key and app id. Each of at most eight current device members receives its rank
in the sorted private member set. That rank selects a v2 descriptor DHT key and
also domain-separates the rendezvous cookie and registration key, so two owners
that choose the same relay cannot collapse into one relay registration. A
membership change rehosts every active share if the local rank changed; devices
outside the first eight retain the encrypted row but do not publish it.

A resolver queries all eight current-period slots plus the legacy record in a
fixed shape, validates each descriptor and canonical key, and deduplicates
identical route bodies. Adjacent periods are queried only if the current period
has no valid candidate. Anonymous capability requests fan out to at most three
providers; the request nonce rotates the starting candidate across retries.
Malformed, revoked and unavailable providers still produce no response oracle.

Registry rows and signed device events live in the deniable file-store v2,
with read migration from the old KV settings. This is required for the stated
six-active-share limit: the legacy settings payload overflowed at three links.

## Verification state

Automated coverage checks strict codec limits and tamper rejection, wrong-key
and wrong-chunk failure, silent unauthorised probes, bounded endpoint allocation,
background withdrawal without premature slot reuse, provider rehost/revoke,
fake-network end-to-end download, no-copy adoption, and two-owner signed-log
active/revoke convergence.

The macOS fixture has verified seed zeroization, stable pseudonymous service/app
identity, idempotent withdrawal, full host/probe/response behavior, UI entry
points, link creation, local adoption and revoke.

The final cross-device run on 2026-07-13 closed the previously blocked bearer
path without resetting any fixture. macOS created and hosted an 8192-byte
revision; Android fetched it anonymously, adopted the exact content id, passed
integrity verification and retained a local replica across app restart. The
owner then revoked the share. A third device (iOS Simulator), which did not
already possess that content id, received no response and committed neither an
item nor a partial blob. The owner's active registry was empty immediately
after revoke. Test items were deleted after verification; the share remained
revoked. This proves create → anonymous download/adopt → revoke → post-revoke
silent denial for the single-provider v1.

The v2 native path was verified on 2026-07-13 with macOS and Android hosting the
same deterministic debug-only service/app identity in slots 0 and 1. An
independent iOS Simulator requester first received slot 0 with both online,
then slot 1 with macOS killed, and finally slot 0 with Android force-stopped.
Both hosts reported identical public keys and scrubbed seed buffers. The probe
kept the seed in RAM and returned only the provider slot, never a sovereign id.

The old physical macOS/Android fixture could not verify the production
device-log convergence in this run: both stores still point at device group
`9e6f04b1…`, but its bundle is absent (`epoch:null`, no members). The Dart
service test therefore proves distinct sorted slots, membership-driven rehost,
and the ninth-device no-publish rule, while the physical probe proves the exact
native DHT/relay/failover path. Repairing that legacy fixture or using a fresh
sovereign two-owner group remains useful for a full production-row convergence
rerun; it is not a limitation of the verified multi-candidate transport.
