# Public cloud capability links

Status: CLOUD-2B is implemented locally and verified on macOS. Cross-device
download, simultaneous multi-provider failover and revoke convergence still
require a fresh writable device group and must not be described as verified.

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
the signed sovereign device-group log, and can host the same pseudonymous
service key and app id. The current blinded DHT descriptor resolves to one
rendezvous value, however. True simultaneous multi-candidate resolution and
measured failover between two live owners remain a native follow-up; the present
implementation must not claim that guarantee.

## Verification state

Automated coverage checks strict codec limits and tamper rejection, wrong-key
and wrong-chunk failure, silent unauthorised probes, bounded endpoint allocation,
background withdrawal without premature slot reuse, provider rehost/revoke,
fake-network end-to-end download, no-copy adoption, and two-owner signed-log
active/revoke convergence.

The macOS fixture has verified seed zeroization, stable pseudonymous service/app
identity, idempotent withdrawal, full host/probe/response behavior, UI entry
points, link creation, local adoption and revoke. Phone/cross-node fetch is
deliberately pending until the physical Android device is connected. A fresh
writable two-owner device group is also required to verify real revoke
convergence and to characterize the remaining DHT failover limitation.
