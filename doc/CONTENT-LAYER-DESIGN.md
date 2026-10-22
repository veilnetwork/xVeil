# Decentralized content layer — design

Started 2026-06-27. User vision: transfer files of ANY size + SHARE some files
publicly (a PeerTube analog), decentralized, BitTorrent-style. Replaces the
abandoned direct app-stream push approach (proven NOT to traverse NAT
phone↔desktop; see doc/ANYSIZE-FILE-TRANSFER-PLAN.md). Later anonymous onion
content streams did gain NAT traversal and now accelerate the same verified
receiver-pull protocol; they are not the abandoned `WireKind.fileStream` push.

## Endpoint credit for reliable content streams (2026-10-22)

The reliable content response can negotiate a 256 KiB read window. This bounds
bytes admitted beyond the receiver's application reads, including the manifest,
so a fast producer cannot overflow the SDK receive queue while a sink is slow.
The receiver returns an eight-byte big-endian cumulative byte count before its
next read after each 64 KiB, allowing acknowledgements to return while the
remaining window is in flight. The sender validates cumulative increments
and waits with a bounded idle timeout. It retains the stream until final credit
or peer close/abort, so an early sender close cannot race late credits. The
known-length receiver returns final consumed credit when closing. Credits acknowledge application reads;
piece hashes, verified writes and final content verification remain separate.

Negotiation preserves the existing 48-byte request layout. Bit 62 of the offset
requests credit; a supporting sender removes it and sets bit 31 of the manifest
length prefix. An older sender treats the marked offset as beyond EOF and sends
only its ordinary manifest. A new receiver aborts that metadata-only attempt and
reopens the original range without the marker. A bounded five-minute peer cache
avoids repeating this probe. Old receivers continue to receive the original
uncredited response. Compatibility fallback does not consume payload retries.

This operates between endpoints inside the existing reliable stream. Relays
remain unaware of content type and receive no traffic priority. It introduces
no mailbox delivery, relay storage or change to content identity and hashes.

## Transport decision (proven on-device)
- legacy veil **streams** (App family) + real-time data (`AppRtData`) are **direct-
  session-only** — no relay/onion egress, so they DON'T cross NAT. Verified:
  `open_stream` phone→desktop fails `NO_SESSION` (code 6).
- the later anonymous onion stream transport DOES cross NAT and is the current
  bulk data plane after a contentId request; manifest and hash verification stay
  authoritative, with datagram control/piece fallback and resume logic.
- veil **datagrams** (Delivery family) DO traverse NAT via relays (proven: the
  chat already delivers both ways). They are lossy, unordered, ≤6144 B/msg.
- **Anonymity is a per-user TOGGLE.** Default = relay-forward (low latency, fewer
  hops, less anonymity). Opt-in = onion (strong anonymity, the user accepts the
  latency/quality cost — "the tradeoff is on whoever enables anonymity").
- ⇒ Files (and later calls) ride the **datagram/relay path**, with app-level
  reliability (BitTorrent-style: hash-verified pieces, re-request the missing).

## Why datagrams fit (and streams don't)
Order-independence + per-piece hash verification means loss/reorder is harmless:
reassemble by index, verify each piece, re-request failures. No head-of-line
blocking. This is exactly BitTorrent — and (for calls later) exactly RTP.

## Components

### 1. ContentManifest — DONE (xVeil 2f93a9f, `lib/domain/content_manifest.dart`)
File → 256 KiB pieces, SHA-256 per piece, self-authenticating `contentId` (hash
of the canonical manifest). Verifies each PIECE and the WHOLE without trusting
the sender/relays. JSON form rejects a tampered (non-self-consistent) manifest.
The "torrent file". 5 tests.

### 2. ExternalBlobStore — DONE (xVeil c35db42)
Encrypted at-rest store OUTSIDE the deniable container (key from the container),
streaming AEAD, opaque names, orphan-GC. Where large/shared blobs live.

### 3. Piece-transfer protocol — NEXT
Over datagrams (the proven NAT path), reusing the wire-chunk machinery:
- Sender advertises a `contentManifest` wire frame (the manifest, ≤ a few KB for
  reasonable files; large manifests chunk like a piece).
- Receiver requests pieces it lacks (a `pieceRequest{contentId, bitfield/indices}`),
  sender streams each piece as ≤4000 B wire chunks (fits the 6144 auth_deliver
  cap), receiver reassembles a piece, VERIFIES its hash, re-requests on failure.
- PACING + windowing so the manifest/first frames don't drown in a burst (the
  on-device failure mode). Backpressure via outstanding-piece window.
- Swarm-ready: a piece can come from ANY peer that has it + verifies the same.

### 4. Provider discovery (swarm) — LATER
Publish `provider{contentId} = me` into the veil DHT (like the rendezvous ad /
relay-key records — self-authenticating DHT values). A fetcher resolves providers
for a contentId, then runs the piece-transfer against one or more. Enables
PeerTube-style fetch-by-id from multiple sources.

### 5. Public sharing / publish — LATER
A "publish" action: store the blob (ExternalBlobStore), build the manifest,
announce the provider record. A "subscribe/fetch by contentId" entry point + UI.
Access control for non-public shares (manifest sealed to recipients).

## Reuse / integration
- Small 1:1 chat files keep the existing in-container deniable datagram path.
- Large + shared files use ContentManifest + ExternalBlobStore + the piece
  protocol. `Message.fileExternal` + a `contentId` ref ties a chat message to a
  manifest/blob.
- `veil_seal/unseal` (FFI) encrypts external blobs.

## Open questions
- Relay-forward WITHOUT full onion: confirm the Delivery path can be configured
  for fewer hops (throughput) — the relay machinery exists (delivery.rs route_cache
  / recursive-relay); needs a low-anonymity/high-throughput mode knob.
- Manifest distribution for large files (manifest itself chunked + hash-verified).
- Calls/video: a future low-latency profile of the SAME datagram path (RTP-like),
  anonymity-off by default; reuses provider/relay but needs jitter/latency tuning.
