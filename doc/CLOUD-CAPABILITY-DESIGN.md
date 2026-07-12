# Public cloud capability links

Status: design boundary for CLOUD-2B. Contact sharing is implemented separately
through accepted 1:1 filePost/content flows. Public links MUST NOT be emulated by
putting the owner's sovereign `node_id` in a URL.

## Privacy and authority

A link is a bearer capability. Possessing it grants read access to one immutable
cloud revision; it grants no membership, write, list, delete, identity lookup or
other-content access. The URL fragment (never sent to an HTTP server) contains:

- version and random 256-bit `share_id`;
- random 256-bit content-encryption key;
- an ephemeral share public key / provider-discovery label;
- encrypted, authenticated manifest metadata (name, size, plaintext cid,
  ciphertext cid, expiry and algorithm identifiers).

The provider advertisement is signed by the ephemeral per-share key, not the
sovereign identity. It contains no owner node id, contacts, device count or cloud
index. Requests prove knowledge of the capability with a transcript-bound MAC;
invalid, expired and revoked requests are dropped silently (no read/delete
oracle). Plaintext and decrypted key material remain in RAM only.

Revocation withdraws the provider advertisement, scrubs the local share key and
stops new serves. It cannot erase bytes already downloaded by a bearer. Updating
a file creates a new immutable capability/revision; it never silently retargets
an old link.

## Network shape

The current content path opens a stream to a known holder `node_id`. Reusing it
directly would reveal the owner's stable sovereign address in every public link.
CLOUD-2B therefore requires a native pseudonymous provider-discovery primitive:

1. `share_advertise(share_id, ephemeral_pk, expiry, endpoint)` publishes a
   bounded DHT/anycast record without binding the public record to sovereign id.
2. `share_resolve(share_id)` returns several live ephemeral providers so linked
   owner devices can serve the same ciphertext and fail over.
3. `share_stream_open(share_id, provider, proof)` opens an anonymous onion stream;
   the application receives only the capability-scoped request and reply handle.
4. `share_withdraw(share_id)` removes the local advert; records expire even when
   withdrawal cannot propagate.

FFI must expose advertise/resolve/withdraw and inbound/outbound anonymous alias
streams. The existing IPC anycast concepts are not currently exported through
veilclient-ffi/Flutter and are therefore not a production capability transport.

## Storage and replication

The public object is piecewise AEAD ciphertext under the link key. Each piece
binds `share_id`, revision, piece index, total size and ciphertext manifest hash
as AAD. Providers verify ciphertext hashes without possessing plaintext; owner
devices may generate/repair ciphertext from the deniable cloud blob in bounded
RAM. The encrypted share registry (share id, encrypted manifest, expiry,
revoked-at and provider state) replicates only inside the sovereign device group.

## Required verification

- codec rejects wrong version, hostile size, malformed base64 and duplicate
  fields;
- wrong key/tamper/wrong piece index fail before plaintext release;
- anonymous resolve/open works without owner node id on the recipient;
- unauthorized probes are silent and indistinguishable from absent/expired;
- revoke stops fresh downloads, while an already downloaded copy is described
  honestly as irrevocable;
- two owner devices advertise one share, fail over and converge revoke through
  the signed device-group log;
- packet/link metadata audit proves no sovereign id is present in the URL,
  advert or capability handshake.
