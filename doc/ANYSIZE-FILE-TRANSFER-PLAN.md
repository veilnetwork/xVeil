# Any-size file transfer + separate encrypted blob store — implementation plan

Status started 2026-06-27. Goal: transfer files of ANY size; store LARGE files
ENCRYPTED and OUTSIDE the hidden-volume container (so the container isn't bloated
and the ~3.6 MB atomic-delete ceiling doesn't apply). Designed via a 4-facet
workflow; user-locked decisions below.

## Why (root cause this replaces)
Files were chunked into per-message anonymous datagrams (`_sendFileFrames` →
`transport.send(anonymous:true)`). That path: (1) caps a message at
`MAX_AUTH_DELIVER_MSG_BYTES = 6144` B — already fixed by shrinking the wire chunk
to 4000 B (`c984999`), so chunks now traverse; but (2) it's lossy under burst
(~89% dropped, incl. the `fileMeta` that registers the transfer) and slow
(~1 chunk / 3.5 s). A reliable **stream** transport + a real large-file store is
the fix.

## Locked decisions (user, 2026-06-27)
- **Crypto:** Rust `veil_seal`/`veil_unseal` (XChaCha20-Poly1305), audited, key
  never leaves Rust. (NOT a Dart cipher package.)
- **Routing:** ALWAYS external for files > **1 MB** (no per-conversation flag).
  ≤ 1 MB stays on the existing deniable in-container datagram path, untouched.
- **Key:** `blake3DeriveKey('xveil/large-file-key/v1', aead_root || space_id || transferId)`
  from the UNLOCKED container's `aead_root`; NEVER persisted. Blob on disk is
  opaque ciphertext, useless without the container.
- **Receiver FFI:** pull `veil_stream_accept(timeout)` (mirrors openStream/read).
- **No durable byte-offset resume** in v1; gap-fill re-ships the cheap fileStream
  frame and restarts idempotently.
- **Orphan GC (user add-on):** on unlock / storage-cleanup, scan the external
  store and DELETE any blob no message references (a vacuum for out-of-container).

## Deniability note (the real tradeoff)
An out-of-container encrypted blob LEAKS existence/size/count of large transfers
(content stays opaque via the container-derived key). The user accepted this for
files > 1 MB. Mitigations baked in: key only in container; opaque blob filenames
(blake3 keyed, no name/peer/timestamp in path); blob lives in app-private dir;
GC + delete-scrub so a deleted/orphaned blob doesn't linger.

## Stages (commit per stage)

### Stage 1 — Rust FFI foundation  [IN PROGRESS]
- `veilclient/src/handle.rs`: `AppReceiver::into_parts()` → `(msg_rx, stream_rx)`
  (additive; lets the FFI drain datagrams + streams independently — `select!` on
  one `&mut AppReceiver` is a borrow conflict). DONE.
- `crates/veilclient-ffi/src/lib.rs`:
  - `VeilApp`: `receiver` → `msg_rx` + new `inbound_streams` field; split via
    `into_parts()` at bind; recv task drains `msg_rx`. DONE.
  - `veil_stream_accept(app, timeout_ms, out_src_node_id[32], err)` → pull an
    inbound stream (NULL+no-err on timeout so Dart polls). DONE.
  - `veil_seal`/`veil_unseal` (XChaCha20-Poly1305, key32/nonce24, heap out-buf
    freed by `veil_free_buf`) + `chacha20poly1305 = "0.10"` dep. DONE.
- Verify: `cargo check -p veilclient-ffi --features node-embedded`.

### Stage 2 — Native rebuild + bundle
- `bash scripts/build-native.sh` (veilclient-ffi MUST keep `--features
  node-embedded`), `bash scripts/bundle-macos-dylibs.sh debug` (flutter won't
  recopy the dylib). Verify `nm -gU` shows `_veil_stream_accept`/`_veil_seal`/
  `_veil_unseal` + shasum bundled==target. Android: cargo-ndk per-ABI;
  ANDROID_NDK_HOME=ndk/26.3.11579264. iOS later.

### Stage 3 — Dart veil_flutter bindings
- `third_party/veil/flutter/veil_flutter/lib/src/bindings.dart`: lookups for
  veil_stream_accept, veil_seal, veil_unseal.
- `.../client.dart`: `AppHandle.acceptStream({Duration timeout})` →
  `({VeilStream stream, Uint8List srcNodeId})?` (null on timeout); `seal`/`unseal`
  helpers (run the blocking FFI on a worker isolate, like `stream.read`).

### Stage 4 — ExternalBlobStore  (`lib/data/storage/external_blob_store.dart`)
- AEAD-framed file in an app-private dir (`<support>/xVeil-blobs/<2hex>/<rest>.bin`).
- Opaque name = blake3-keyed over the file key (NO name/peer/time in the path).
- Streaming: 64 KiB segments, per-segment 24-B nonce (counter||random prefix),
  each sealed via `veil_seal` → never hold the whole blob in RAM.
- API: `open/streamingWrite/streamingRead/scrub(blobId)` + `listBlobIds()` (for GC).
- Key from the container: `HiddenVolumeStorage` must expose `aeadRoot()`/`spaceId()`
  (hidden-volume FFI already has `aead_root` — plumb a getter) → derive per-blob key.

### Stage 5 — Wire model
- `lib/data/transport/wire_envelope.dart`: append `WireKind.fileStream` (after
  `reconnect`, before `unknown`; v:2) + `fileStreamEnvelope({transferId,name,size,
  seq,sentAtMs})`. (Replaces fileMeta for the large path.)
- `lib/domain/chat.dart` (Message) + `lib/domain/event.dart` (filePost body): add
  `blobRef` (`{type:'stream', tid}`; absent/null ⇒ legacy in-container, no migration).

### ⚠️ Stage 6 — GATING PREREQUISITE: verify stream NAT-traversal
Before building the send/receive integration, PROVE that a veil app-stream
(`open_stream`/`accept_stream`) actually traverses **phone→desktop** (phone is
NAT'd). The anonymous DATAGRAM path provably does (auth_deliver delivered small
frames on-device); whether app-streams ride the same NAT-traversable relay/onion
path or a DIRECT node-to-node session (which the NAT'd phone can't accept inbound)
is UNVERIFIED — `veilclient::open_stream` → node `StreamOpen`; the node's app-
stream data plane (`veil-app/src/registry.rs send_to`) routing wasn't pinned down.
- Test: rebuild Android .so (cargo-ndk) with the new symbols, add a throwaway
  "open stream phone→desktop, write N bytes, assert received" path, run on the 2
  devices. If bytes arrive → proceed with the stream design below. If NOT →
  FALLBACK: keep the anonymous-datagram transfer but (a) PACE `_sendFileFrames`
  (send fileMeta, await a tiny ack/window, then trickle chunks so the burst
  doesn't drop the meta) and (b) make the resumable `fileQuery`/`fileNack` round
  actually drive completion (it was silent on-device — fileQuery count=0). The
  ExternalBlobStore + crypto + wire model (Stages 1-5) are reused EITHER way.

### Stage 6 — Send/receive (if streams traverse NAT)
- Send (`messaging.dart sendFile`): route on size. ≤1 MB → unchanged. >1 MB →
  store to ExternalBlobStore (encrypt-on-write), `transport.openStream(dst,...)`,
  write the blob in ≤16 MiB chunks off the UI isolate, close; emit a `fileStream`
  wire frame + a filePost event (seq, sentAt) with blobRef stream.
- Receive: an accept loop (`transport.acceptStream` poll) in the node/transport
  lifecycle; match an accepted stream to its pending `fileStream` frame by
  (srcNode, transferId); stream-read into ExternalBlobStore (encrypt-on-write,
  enforce declared size); fold the filePost (existing deleted-message guard
  applies) with blobRef stream. Decrypt-on-read when opening/saving.

### Stage 7 — Gap-fill + delete-scrub + GC + UI + tests
- Gap-fill (`_handlePeerSync`/loadEventsSince re-ship): for blobRef stream re-send
  the cheap `fileStream` frame (no blob load) + re-open the stream.
- Delete: scrub the external blob (overwrite + unlink) atomically-ish with the
  message tombstone (best-effort; the blob is opaque without the key anyway).
- **Orphan GC**: on unlock, `external_blob_store.listBlobIds()` minus the set of
  blobRef tids referenced by any message → scrub the difference.
- UI: progress for a large transfer (chat_screen); size-gate the picker.
- Tests: FakeAppHandle openStream/acceptStream over an in-memory pipe; seal/unseal
  round-trip; size-route dispatch; delete scrubs blob; gap-fill restart; GC.

## Biggest risk
Deniability cliff (above) — design choice, accepted. Secondary: modifying the
audited recv path (Stage 1 `msg_rx` swap) — mechanical, but verify messaging
still flows on-device after the rebuild.
