// `prefer_initializing_formals` is suppressed deliberately: the constructor
// takes external NAMED params (`client`, `fetchApp`, …) but the fields are
// private (`_client`, …), and Dart forbids private `this._x` formals as
// cross-library named arguments — so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:typed_data';

import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../../core/ids.dart';
import 'mailbox_deposit_targets.dart';
import 'relay_key_cache.dart';
import 'veil_mailbox.dart';
import 'package:xveil/core/log.dart';

/// BLAKE3("veil.mailbox.v1") — the well-known mailbox built-in app id
/// (veil `veil_mailbox::MAILBOX_APP_ID`). Senders deposit at
/// `(relayNodeId, MAILBOX_APP_ID, putEndpoint)`; receivers fetch from
/// `(myRelayNodeId, MAILBOX_APP_ID, fetchEndpoint)`.
final Uint8List kMailboxAppId = Uint8List.fromList(const [
  0xd4, 0x17, 0xcf, 0x22, 0x72, 0x89, 0x07, 0x40, //
  0xe2, 0xe1, 0xb6, 0xb1, 0xb5, 0x74, 0x12, 0x95,
  0x6b, 0x3e, 0xfc, 0xc6, 0xfd, 0xd4, 0x95, 0x4f,
  0xc4, 0xd4, 0x9b, 0x1c, 0xee, 0x36, 0xf5, 0xbb,
]);

/// Mailbox endpoint ids (veil `veil_mailbox`): PUT deposit, FETCH retrieval.
const int kMailboxPutEndpointId = 1;
const int kMailboxFetchEndpointId = 2;

/// Leading byte of a FETCH request body — see `MailboxFetchRequest` on the
/// veil side. A relay that does not recognise it reads the body as "skip
/// nothing", which is what every relay did before the field existed.
const int _kFetchRequestMagic = 0xF1;

/// Content ids one request may name. Mirrors `MAX_FETCH_SKIP`: a relay
/// truncates past this, so sending more is only waste.
const int kMaxFetchSkip = 64;

/// Encode the "do not serve these" hint carried by a FETCH.
///
/// A relay serves oldest-first under a reply budget, so a blob the caller
/// keeps failing to open sits at the front and is served again on every fetch,
/// spending the slots and bytes everything behind it needs (report14 X14-M4).
/// An empty list encodes to an EMPTY BODY — byte-for-byte what every build
/// before this sent — so nothing changes for a caller with nothing to skip.
Uint8List encodeFetchRequest(List<Uint8List> skip) {
  if (skip.isEmpty) return Uint8List(0);
  final n = skip.length > kMaxFetchSkip ? kMaxFetchSkip : skip.length;
  final out = BytesBuilder();
  out.addByte(_kFetchRequestMagic);
  out.add((ByteData(2)..setUint16(0, n)).buffer.asUint8List());
  for (var i = 0; i < n; i++) {
    final cid = skip[i];
    if (cid.length != 32) continue;
    out.add(cid);
  }
  return out.toBytes();
}

/// Receiver-authenticated SLICE: "give me `content_id` from `offset`".
///
/// The way a blob larger than one FETCH reply comes out of the store. A blob
/// carries one ML-KEM envelope PER RECIPIENT DEVICE, so its size follows the
/// identity rather than the message — past a few devices nothing of any size
/// fits a reply, and the deposit side (chunked, up to a megabyte) was never the
/// limit. A relay predating this endpoint binds nothing and drops the request;
/// the blob then ages out exactly as it did before.
const int kMailboxSliceEndpointId = 5;

/// Receiver-authenticated ACK: "drop my blob `content_id`". Relays older than
/// the endpoint simply have nothing bound there and drop the deliver — the ack
/// is fire-and-forget, so mixed fleets degrade to the old TTL-only behavior.
const int kMailboxAckEndpointId = 3;

/// `replyEndpointId` for a send the target never answers: veil reads 0 as "no
/// reply block", so it builds no ephemeral reply circuit for it. Nothing is
/// ever delivered to endpoint 0, so a block addressed there was undeliverable
/// by construction — which is why the value is free to carry this meaning.
/// A daemon predating the reading builds the unused circuit as before.
const int kNoReplyEndpointId = 0;

/// Encode a `MailboxPutPayload` (veil-proto `ipc.rs`) for the network PUT wire:
///   receiver_id(32) | content_id(32) | sender_id(32) | blob_len(u32 BE) | blob
///   | push_env_len(u16) | cap_token_len(u16) | wake_env_len(u16)
///
/// SECURITY: the wire `sender_id` is the relay's UNTRUSTED hint — the relay
/// overrides it with the authenticated session source (`0` for an anonymous
/// deposit) and the receiver must never trust it. We send ALL-ZERO so the
/// deposit does not deanonymize the sender to the relay; the real sender
/// identity travels sealed inside the opaque E2E [blob]. The optional push /
/// capability / wake-HMAC trailers are absent in this first integration.
Uint8List encodeMailboxPut({
  required Uint8List receiverId,
  required Uint8List contentId,
  required Uint8List blob,
}) {
  assert(receiverId.length == 32);
  assert(contentId.length == 32);
  final b = BytesBuilder(copy: false);
  b.add(receiverId);
  b.add(contentId);
  b.add(Uint8List(32)); // sender_id: 0 = anonymous (untrusted wire hint)
  final lenBe = ByteData(4)..setUint32(0, blob.length, Endian.big);
  b.add(lenBe.buffer.asUint8List());
  b.add(blob);
  b.add(Uint8List(2)); // push_envelope: absent
  b.add(Uint8List(2)); // capability_token: absent
  b.add(Uint8List(2)); // wake_hmac_envelope: absent
  return b.toBytes();
}

/// Max `chunk_data` bytes per PUT chunk — MUST match veil-proto
/// `MAILBOX_PUT_CHUNK_DATA_BYTES`. A deposit travels as a sender-anonymous onion
/// message capped at ONE anonymous cell, so a `MailboxPutPayload` larger than
/// this is split across N chunks; the relay reassembles by `content_id` before
/// storing. (The FETCH reply path already fragments, so only PUT needs this.)
///
/// Was 240, sized against the 512-byte cell veil used until 2026-08-07. The cell
/// is 8192 now and a chunk is one cell on the wire either way, so a ~1.5 KB
/// deposit cost seven whole cells for 1.7 KB of content. At 7680 every deposit
/// that can ever be fetched back is a single chunk (the FETCH reply budget caps
/// a servable blob near 5.6 KB). The Rust side pins this against the real cell
/// budget in `a_full_deposit_chunk_fits_one_anonymous_cell`.
const int kMailboxPutChunkDataBytes = 7680;

/// Encode one `MailboxPutChunkPayload` (veil-proto `ipc.rs`):
///   content_id(32) | chunk_index(u16 BE) | chunk_total(u16 BE) | chunk_data
Uint8List encodeMailboxPutChunk({
  required Uint8List contentId,
  required int chunkIndex,
  required int chunkTotal,
  required Uint8List chunkData,
}) {
  assert(contentId.length == 32);
  final b = BytesBuilder(copy: false);
  b.add(contentId);
  final hdr = ByteData(4)
    ..setUint16(0, chunkIndex, Endian.big)
    ..setUint16(2, chunkTotal, Endian.big);
  b.add(hdr.buffer.asUint8List());
  b.add(chunkData);
  return b.toBytes();
}

/// Split an encoded `MailboxPutPayload` into PUT chunks of ≤
/// [kMailboxPutChunkDataBytes], each keyed by [contentId] for relay reassembly.
List<Uint8List> chunkMailboxPut(Uint8List contentId, Uint8List payload) {
  final total =
      (payload.length + kMailboxPutChunkDataBytes - 1) ~/ kMailboxPutChunkDataBytes;
  return [
    for (var i = 0; i < total; i++)
      encodeMailboxPutChunk(
        contentId: contentId,
        chunkIndex: i,
        chunkTotal: total,
        chunkData: Uint8List.sublistView(
          payload,
          i * kMailboxPutChunkDataBytes,
          ((i + 1) * kMailboxPutChunkDataBytes).clamp(0, payload.length),
        ),
      ),
  ];
}

/// Decode a `MailboxFetchRespPayload` (veil-proto `ipc.rs`) from a FETCH reply:
///   count(u16 BE) | [ sender_id(32) | content_id(32) | deposited_at(u64 BE)
///                      | blob_len(u32 BE) | blob ] * count
///
/// An empty list means "nothing for you" (the relay cannot distinguish that
/// from an un-served request). Throws [FormatException] on a malformed reply so
/// a single corrupt frame surfaces rather than silently dropping a drain.
List<StoredMailboxBlob> decodeMailboxFetchResp(Uint8List data) {
  if (data.length < 2) {
    throw const FormatException('mailbox fetch reply too short for count');
  }
  final bd = ByteData.sublistView(data);
  final count = bd.getUint16(0, Endian.big);
  final out = <StoredMailboxBlob>[];
  var off = 2;
  for (var i = 0; i < count; i++) {
    const header = 32 + 32 + 8 + 4;
    if (off + header > data.length) {
      throw FormatException(
          'mailbox fetch reply truncated at entry $i (need ${off + header}, '
          'have ${data.length})');
    }
    final senderId = Uint8List.fromList(data.sublist(off, off + 32));
    final contentId = Uint8List.fromList(data.sublist(off + 32, off + 64));
    // deposited_at (off+64..off+72) is informational — not surfaced here.
    final blobLen = bd.getUint32(off + 72, Endian.big);
    final blobStart = off + header;
    final blobEnd = blobStart + blobLen;
    if (blobEnd > data.length) {
      throw FormatException(
          'mailbox fetch reply blob $i overruns (need $blobEnd, '
          'have ${data.length})');
    }
    out.add(StoredMailboxBlob(
      senderId: NodeId(senderId),
      contentId: contentId,
      blob: Uint8List.fromList(data.sublist(blobStart, blobEnd)),
    ));
    off = blobEnd;
  }
  return out;
}

/// Encode a `MailboxSliceReqPayload` (veil-proto `ipc.rs`):
///   content_id(32) | offset(u32 BE)
Uint8List encodeMailboxSliceReq(Uint8List contentId, int offset) {
  if (contentId.length != 32) {
    throw ArgumentError('content id must be 32 bytes');
  }
  final out = Uint8List(36);
  out.setRange(0, 32, contentId);
  ByteData.sublistView(out).setUint32(32, offset, Endian.big);
  return out;
}

/// One window of a stored blob, as the relay answers a slice request.
class MailboxSlice {
  const MailboxSlice({
    required this.contentId,
    required this.offset,
    required this.totalLen,
    required this.bytes,
  });

  final Uint8List contentId;
  final int offset;

  /// Full length of the blob, stated in EVERY slice. Zero means the relay holds
  /// no such blob for us — an answer, not an empty window, so a blob that aged
  /// out or was acked from another device ends the walk instead of repeating it.
  final int totalLen;
  final Uint8List bytes;
}

/// Decode a `MailboxSlicePayload`:
///   content_id(32) | offset(u32 BE) | total_len(u32 BE) | len(u32 BE) | bytes
///
/// Throws [FormatException] on anything malformed — including a length that
/// overruns the frame, which is the shape a hostile relay would use to make us
/// allocate on its word rather than on its bytes.
MailboxSlice decodeMailboxSliceResp(Uint8List data) {
  const header = 32 + 4 + 4 + 4;
  if (data.length < header) {
    throw const FormatException('mailbox slice reply too short for header');
  }
  final bd = ByteData.sublistView(data);
  final len = bd.getUint32(40, Endian.big);
  if (header + len > data.length) {
    throw FormatException(
        'mailbox slice reply overruns (need ${header + len}, '
        'have ${data.length})');
  }
  return MailboxSlice(
    contentId: Uint8List.fromList(data.sublist(0, 32)),
    offset: bd.getUint32(32, Endian.big),
    totalLen: bd.getUint32(36, Endian.big),
    bytes: Uint8List.fromList(data.sublist(header, header + len)),
  );
}

/// Network-path mailbox relay transport — the PROVEN anonymous onion path,
/// satisfying the same [VeilMailboxRelay] port the dormant [MailboxOrchestrator]
/// already drives. Unlike the local-IPC adapter ([VeilFlutterMailboxRelay],
/// `put/fetch/ack` against a directly-connected relay with an `authCookie`),
/// this reaches a REMOTE relay over anonymous circuits:
///
///   * [put]   — resolve the receiver's published rendezvous replicas
///     ([veil.VeilMailbox.lookupRendezvousReplicas]) and fan a sender-anonymous
///     `sendAnonymousDirect` deposit out to each (K-replica redundancy; the
///     service is fire-and-forget — no per-put ack on the wire).
///   * [fetch] — resolve OUR OWN published relay and send an AUTHENTICATED
///     `sendAnonymousAuthenticatedWithReply` to its FETCH endpoint; the relay
///     verifies our cryptographic identity (NO cookie — the verified identity
///     IS the authorization) and answers our pending blobs over the one-time
///     reply path, which surfaces on [fetchApp]'s reply endpoint.
///   * [ack]   — NO-OP. There is no network ack endpoint; FETCH is
///     non-destructive (blobs age out via the relay's quota / validity window),
///     so de-duplication is receiver-side by `contentId` (the orchestrator's
///     `alreadyHave` check). Re-fetching simply re-returns not-yet-aged blobs.
///
/// The receiver must have registered a rendezvous publisher advertising its
/// relay (+ that relay's KEM key) BEFORE either side can address it — that
/// startup wiring lives outside this transport.
/// Thrown by [VeilNetworkMailboxRelay.fetch] when EVERY known relay was tried
/// but none answered (send threw / no reply in the window). Distinct from a
/// relay answering with an empty mailbox: an unreachable drain leaves the
/// receiver UNCERTAIN whether mail is waiting, so the drain loop must keep
/// polling at a bounded cadence rather than treat it as an idle/empty inbox and
/// back off exponentially (which strands pending mail at the relay for minutes).
class MailboxDrainUnreachable implements Exception {
  MailboxDrainUnreachable(this.relaysTried, this.lastError);

  /// How many relays were attempted before giving up this round.
  final int relaysTried;

  /// The last underlying send/timeout error (for diagnostics).
  final Object? lastError;

  @override
  String toString() =>
      'MailboxDrainUnreachable($relaysTried relay(s) tried, last: $lastError)';
}

/// The largest SEALED blob a relay will store, and the per-blob header it
/// charges on top.
///
/// Not a policy of ours — the relay's, mirrored (`MAX_BLOB_BYTES`). It used to
/// be a FETCH reply's worth, 5632 bytes, because a reply was the only way out
/// of the store and a blob nobody could fetch sat at the head of an
/// oldest-first queue starving everything behind it.
///
/// That ceiling refused messages nobody could have made smaller. A blob carries
/// one ML-KEM envelope PER RECIPIENT DEVICE, so its weight follows the identity
/// rather than the message: measured on the stand, a 2874-byte frame sealed to
/// 13937 bytes for an identity with two other devices, and every deposit to
/// that identity was refused. Shrinking what the app sends could not help — the
/// cost is charged per blob and it is the ENVELOPES that grow.
///
/// The relay now announces such a blob in its FETCH reply and serves it a
/// window at a time from [kMailboxSliceEndpointId], so the deposit cap is the
/// store's own again.
///
/// Mirrored rather than asked for because the PUT is sender-anonymous: there is
/// no reply path to carry a refusal, so the only way for a sender to know is to
/// apply the same rule.
const int kMailboxBlobMaxBytes = 1024 * 1024;
const int kMailboxPerBlobWireHeaderBytes = 32 + 32 + 8 + 4;

/// What one FETCH reply can carry, and therefore what a relay predating the
/// slice endpoint would accept at all.
///
/// Kept after the deposit ceiling moved past it, because it is still the line
/// between "every relay can deliver this" and "only an updated one can".
const int kMailboxLegacyReplyBudget = 6144 - 512;

/// Thrown by [VeilNetworkMailboxRelay.put] for a blob no relay would store.
///
/// This is not a transient failure and a retry will not help: the deposit is
/// refused for its SIZE, which does not change. It is raised anyway — rather
/// than logged and swallowed — because the alternative is what happened before:
/// the sender reported the deposit as done, the frame left the outbox, and the
/// recipient waited for something that had never been stored.
class MailboxBlobTooLarge implements Exception {
  MailboxBlobTooLarge(this.blobBytes, this.receiver);

  final int blobBytes;
  final NodeId receiver;

  @override
  String toString() =>
      'MailboxBlobTooLarge(${blobBytes}B + $kMailboxPerBlobWireHeaderBytes hdr '
      '> $kMailboxBlobMaxBytes for ${receiver.short} — the relay refuses a blob '
      'a FETCH reply cannot carry back; the frame has to be smaller, or the '
      'fan-out narrower)';
}

class VeilNetworkMailboxRelay implements VeilMailboxRelay {
  VeilNetworkMailboxRelay({
    required veil.VeilClient client,
    required veil.AppHandle fetchApp,
    // The PUT-source AppHandle — retained HERE for the relay's whole lifetime.
    // Passing only its app_id let the caller's local handle become garbage: the
    // AppHandle NativeFinalizer then fired veil_app_close on GC, the daemon
    // unbound the endpoint, and EVERY subsequent deposit was rejected as
    // SPOOFED_SRC (status 4) until app restart — killing the offline-mailbox
    // path minutes after startup (GC timing) on 2026-07-17's stand.
    required veil.AppHandle srcApp,
    required int replyEndpointId,
    int putHopCount = 1,
    int putReplicaFanout = 3,
    // 12s let a relay that never answers FETCH (e.g. one that doesn't serve the
    // mailbox path) stall a full 12s every drain — on a shared IPC that
    // periodically froze the UI. 5s fails fast; a relay that genuinely has mail
    // answers well inside it.
    Duration fetchTimeout = const Duration(seconds: 5),
    // Last-known-good relay KEM keys, keyed by relay node_id. When present, the
    // FETCH goes STRAIGHT to the relay with its known key (no flaky self-resolve
    // that returns NoRendezvous); absent → fall back to the self-resolving send.
    // Null on the loopback/dev path. The key is PUBLIC, so caching/passing it
    // leaks nothing.
    RelayKeyCache? relayKeyCache,
  })  : _client = client,
        _fetchApp = fetchApp,
        _srcApp = srcApp,
        _replyEndpointId = replyEndpointId,
        _putHopCount = putHopCount,
        _putReplicaFanout = putReplicaFanout,
        _fetchTimeout = fetchTimeout,
        _relayKeyCache = relayKeyCache {
    if (_srcAppId.length != 32) {
      throw ArgumentError(
        'srcApp.appId must be 32 bytes, got ${_srcAppId.length}',
      );
    }
  }

  final veil.VeilClient _client;
  final veil.AppHandle _fetchApp;
  final veil.AppHandle _srcApp;

  Uint8List get _srcAppId => _srcApp.appId;
  final int _replyEndpointId;
  final int _putHopCount;
  final int _putReplicaFanout;
  final Duration _fetchTimeout;

  /// How long the fetch window stays open for the remaining relays once one has
  /// already answered. Sized to cover ordinary spread between healthy relays
  /// (they answer within a few hundred ms of each other), not to outwait a sick
  /// one — that is what the next pass is for. See the note at the arming site.
  static const Duration _stragglerGrace = Duration(milliseconds: 700);

  /// How long one slice round trip may take before the pass gives up on it.
  /// An onion round trip, so seconds rather than milliseconds; a miss costs a
  /// retry on the next drain, never a lost blob.
  static const Duration _sliceTimeout = Duration(seconds: 20);

  /// Rounds one announced blob may take before the pass abandons it. Derived,
  /// not picked: the store caps a blob at [kMailboxBlobMaxBytes] and a window
  /// carries at least a kilobyte, so a blob that needs more rounds than this
  /// could not have been stored. It bounds a relay that answers forever with
  /// short windows.
  static const int _maxSliceRounds = kMailboxBlobMaxBytes ~/ 1024 + 8;
  final RelayKeyCache? _relayKeyCache;

  /// Last logged known-relay count — the steady-state drain plan is logged
  /// only when this changes, not on every pass (log-noise budget).
  int? _lastLoggedKnownRelayCount;

  /// Last drain pass's reply outcome (`replies/expected`), for change-only
  /// logging: one slow/dead relay makes EVERY pass time out with the same
  /// shortfall, and a line per pass is pure idle noise. Log when the outcome
  /// CHANGES — including the recovery back to a full window, which the
  /// per-pass timeout line never showed at all.
  String? _lastReplyOutcome;

  /// Deadline on each unbounded await inside [put]. The deposit path had two
  /// (replica lookup, per-chunk anonymous send), and a native future that
  /// never resolves — a circuit that never builds, a lookup the DHT never
  /// answers — hung the whole deposit with NO error. Measured live
  /// 2026-08-16: one such hang held the messaging layer's single background
  /// slot 10+ minutes; the caller-side stash deadline (45s) frees the slot,
  /// but only THIS one names the step that actually stalled.
  static const Duration _putStepTimeout = Duration(seconds: 20);

  @override
  Future<void> put({
    required NodeId receiver,
    required Uint8List contentId,
    required NodeId sender,
    required Uint8List blob,
  }) async {
    // A deposit the relay CANNOT store must fail here, where the caller can see
    // it — not succeed here and be refused there.
    //
    // The PUT is sender-anonymous and therefore fire-and-forget: there is no
    // reply path, so the relay's refusal reaches nobody. It refuses for a good
    // reason — a blob larger than a FETCH reply can carry could be stored and
    // never fetched, so accepting it would wedge the receiver's queue — but the
    // sender then reported the deposit as done. Measured on a two-device stand:
    // `stash OK` at the source, `recovered=0` at the sibling, and the truth only
    // in a relay log on a server:
    //
    //   PUT rejected (recv=b11f7179 blob 6976B + hdr > fetch budget 5632B
    //                 — would be permanently unfetchable)
    //
    // We hold the sealed blob right here, so this is an exact check rather than
    // an estimate of one. Throwing puts the frame back in the outbox, where an
    // undeliverable frame belongs, instead of marking it delivered.
    if (blob.length + kMailboxPerBlobWireHeaderBytes > kMailboxBlobMaxBytes) {
      throw MailboxBlobTooLarge(blob.length, receiver);
    }
    // LOUD while the fleet is mixed. A relay that predates the slice endpoint
    // still refuses this deposit at its own door, and the refusal reaches
    // nobody — the PUT is sender-anonymous, so there is no reply path to carry
    // it. That is the exact shape of the defect this endpoint exists to close:
    // a message nobody could have made smaller, dropped without a word.
    //
    // Not an error, because against an updated relay it is the ordinary case.
    // The line goes away on its own as relays update.
    if (blob.length + kMailboxPerBlobWireHeaderBytes > kMailboxLegacyReplyBudget) {
      // The content id names WHICH frame class pays the slice tax (6 onion
      // round trips per window at the receiver) — without it this line says
      // only that somebody, somewhere, deposits oversized, which is exactly
      // enough to misattribute. Measured 2026-08-17: a backlog of ~30KB
      // blobs took a drain pass hours; the id is what lets the diet start
      // at the right table.
      devLog(() =>
          'xVeil[send]: deposit of ${blob.length}B to ${receiver.short} '
          '(cid=${NodeId(contentId).short}) needs a relay that serves '
          'slices — one predating the endpoint will drop it');
    }
    // An ad that will not resolve is a ROUTING miss, not a verdict on the
    // peer, so a throw here would be the wrong shape: the fallback below is
    // exactly for the case where this returns nothing. A timeout counts as
    // nothing for the same reason — a DHT that did not answer inside the step
    // budget has told us as little as one that answered empty.
    var replicas = const <veil.RendezvousReplica>[];
    try {
      replicas = await _client.mailbox
          .lookupRendezvousReplicas(receiver.bytes)
          .timeout(_putStepTimeout);
    } catch (e) {
      devLog(() => 'xVeil[stash-put]: ad lookup FAILED dst=${receiver.short} '
          '— falling back to the last relays that held this peer\'s mailbox: $e');
    }
    // A usable deposit target = the replica's relay + that relay's public
    // X25519 (the PUT's seal target). Prefer the key carried by the ad itself
    // (v5 KEM field); when the ad is KEM-LESS — e.g. the recipient's node
    // republished its slots after a restart before the app layer re-attached
    // the relay key — the ad still NAMES the relay, and the relay's key is a
    // public value we usually already hold (the drain warms every candidate
    // into the relay-key cache) or can fetch with a one-hop relay-dir lookup.
    // Without this fallback a recipient restart black-holed deposits for as
    // long as no KEM-bearing ad was resolvable (observed ~19 min on the
    // stand): texts AND file offers from the peer silently stopped arriving.
    //
    // NO CAPABILITY TOKEN IS INVOLVED, which is why the cached fallback is
    // sound at all. [encodeMailboxPut] writes the token trailer as ABSENT on
    // every deposit, and the relay's `put_with_capability` accepts a tokenless
    // PUT under the default `require_capability_token = false` (it lands in the
    // Anonymous eviction pool rather than being refused). So the ad carries
    // nothing a deposit needs beyond the relay's identity and key — it is a
    // DIRECTORY entry, not a credential, and a lapsed one costs us the address
    // and nothing else.
    final plan = await planMailboxDeposit(
      receiver: receiver,
      adReplicas: [
        for (final r in replicas)
          (
            relay: NodeId(Uint8List.fromList(r.relayNodeId)),
            kemPk: r.rendezvousKemPk.length == 32
                ? Uint8List.fromList(r.rendezvousKemPk)
                : null,
          ),
      ],
      resolveRelayKem: _resolveRelayKem,
      fanout: _putReplicaFanout,
      cache: _relayKeyCache,
    );
    final usable = plan.targets;
    devLog(() => 'xVeil[stash-put]: dst=${receiver.hex.substring(0, 8)} '
        'replicas_resolved=${replicas.length} usable(KEM)=${usable.length} '
        'via=${plan.source.name}');
    if (usable.isEmpty) {
      // BOTH the ad and the cache came up empty, so this peer is genuinely
      // unaddressable and the caller's unresolved-peer backoff should hold —
      // that is what keeps a stranger from being hammered every flush tick.
      throw MailboxPeerUnresolved(
          'no rendezvous replica with a usable KEM key for ${receiver.hex}, and '
          'no remembered relay either — recipient has never advertised a mailbox '
          'relay to us (or the remembered one aged out)');
    }
    final payload = encodeMailboxPut(
      receiverId: receiver.bytes,
      contentId: contentId,
      blob: blob,
    );
    // The PUT exceeds the single-cell anonymous-send budget, so split it into
    // chunks the relay reassembles by content_id. Each chunk is its own
    // sender-anonymous send (the onion transport is untouched).
    final chunks = chunkMailboxPut(contentId, payload);
    // Fan out to every usable replica; a replica "succeeds" only when ALL its
    // chunks were handed to circuits (a partial set is stale-evicted relay-side).
    // Succeed overall if AT LEAST ONE replica took the full set (K-replica
    // redundancy). Throw only if all fail, so the caller's outbox retries.
    Object? lastErr;
    final accepted = <MailboxDepositTarget>[];
    for (final r in usable) {
      try {
        for (final chunk in chunks) {
          await _client
              .sendAnonymousDirect(
                targetNodeId: r.relayNodeId,
                targetX25519Pk: r.kemPk,
                targetAppId: kMailboxAppId,
                targetEndpointId: kMailboxPutEndpointId,
                srcAppId: _srcAppId,
                data: chunk,
                hopCount: _putHopCount,
              )
              .timeout(_putStepTimeout);
        }
        accepted.add(r);
      } catch (e) {
        lastErr = e;
      }
    }
    if (accepted.isEmpty) {
      throw StateError('all ${usable.length} mailbox deposits failed: $lastErr');
    }
    // The deposit is DONE by here, so this bookkeeping may not be able to
    // undo it. A container write that hangs would otherwise hold the messaging
    // layer's single background deposit slot until its own 45s deadline and
    // report a delivered message as failed; the write completes on its own
    // afterwards either way.
    await recordMailboxDeposit(
      receiver: receiver,
      accepted: accepted,
      source: plan.source,
      cache: _relayKeyCache,
    ).timeout(_putStepTimeout, onTimeout: () {});
  }

  /// A relay's public X25519 from the relay directory — one hop to a connected
  /// relay, not a recursive DHT walk. The ad's own KEM field and the persisted
  /// cache are tried first by [planMailboxDeposit]; this is the last resort.
  /// Best-effort: a relay whose key cannot be found is simply not a target.
  Future<Uint8List?> _resolveRelayKem(NodeId relay) async {
    try {
      return await _client
          .lookupRelayX25519(relay.bytes)
          .timeout(_putStepTimeout);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie, // ignored — verified identity is the auth
    List<NodeId> knownRelays = const [],
    List<Uint8List> skip = const [],
  }) async {
    // Built once for the whole pass: every relay is asked the same question,
    // and an empty list encodes to an empty body — byte-for-byte what this
    // send carried before the field existed.
    final requestBody = encodeFetchRequest(skip);
    // Prefer the relay(s) we already REGISTERED with: we know them, so go
    // STRAIGHT to them instead of re-resolving our own rendezvous ad over the
    // DHT every poll. That DHT lookup transiently times out (especially on
    // mobile / right after a relay restart) and was silently stranding pending
    // mail — the deposit sits at the relay but the drain fetched nothing.
    List<Uint8List> relayIds;
    // relay node_id (hex) -> its rendezvous KEM pk, when we already hold it. The
    // KEM key lets the FETCH go STRAIGHT to the relay (key-given authenticated
    // send) instead of self-resolving the relay as a rendezvous recipient — which
    // ALWAYS fails (a relay publishes no RendezvousAd → NoRendezvous). Sourced
    // from our own resolved replicas (the SAME field the deposit uses) and/or the
    // relay-key cache. The key is a public, network-published value, so holding it
    // leaks nothing.
    final Map<String, Uint8List> kemByRelay = {};
    if (knownRelays.isNotEmpty) {
      relayIds = knownRelays.map((r) => r.bytes).toList();
      // Steady-state path — log only when the relay set SIZE changes, not on
      // every drain pass (this line alone was ~1K lines/hour of idle noise).
      if (relayIds.length != _lastLoggedKnownRelayCount) {
        _lastLoggedKnownRelayCount = relayIds.length;
        devLog(() => 'xVeil[drain]: fetch via ${relayIds.length} KNOWN '
            'relay(s) (skip DHT self-resolve)');
      }
    } else {
      // Cold path (not yet registered): resolve our own ad to find a relay.
      final List<veil.RendezvousReplica> replicas;
      try {
        replicas = await _client.mailbox.lookupRendezvousReplicas(me.bytes);
      } catch (e) {
        devLog(() => 'xVeil[drain]: own-ad DHT resolve FAILED: $e');
        return const [];
      }
      if (replicas.isEmpty) {
        devLog(() => 'xVeil[drain]: own-ad resolved 0 replicas — nothing to fetch');
        return const [];
      }
      relayIds = replicas.map((r) => r.relayNodeId).toList();
      // Capture each replica's KEM key — this is exactly what makes the deposit
      // reliable, so reuse it for the fetch instead of depending on the cache
      // having been warmed by a prior registration.
      for (final r in replicas) {
        if (r.rendezvousKemPk.length == 32) {
          kemByRelay[NodeId(r.relayNodeId).hex] =
              Uint8List.fromList(r.rendezvousKemPk);
        }
      }
    }
    // Drain the UNION across every known relay. Offline mail can land on ANY
    // relay our rendezvous ad advertises — a stale slot from a prior session, the
    // node's built-in receiver task's relay, or simply a relay the SENDER
    // resolved that differs from the one relay we registered+drained. We used to
    // fetch only the FIRST relay that answered and return, stranding deposits made
    // to the others (the exact desktop->phone offline-edit black hole).
    //
    // The relays are queried in PARALLEL. Sequentially each relay cost a full
    // onion RTT (send + reply through the anonymous path), so a 3-relay drain
    // was ~3×RTT even when all relays answered instantly — the dominant term of
    // the post-restart backlog latency (one ~4 KB blob per FETCH reply × several
    // sequential rounds). Replies arrive on the shared reply endpoint with
    // src_node_id zeroed (anonymous path), so they are NOT attributable to a
    // relay — but each relay sends EXACTLY ONE reply per FETCH, so counting
    // replies is enough: collect until every sent fetch answered or the window
    // closes. Blob attribution is unnecessary — the union dedups by content_id.
    Object? lastErr;
    var anyAttempted = false;
    final seen = <String>{};
    final aggregated = <StoredMailboxBlob>[];
    var replies = 0;
    FormatException? malformed;
    var expected = 0;
    var allSent = false;
    final window = Completer<void>();
    // Straggler grace. The window used to close only when EVERY relay had
    // answered, or on the flat [_fetchTimeout] — so one habitually slow relay
    // out of three cost the full timeout on EVERY pass, mail or no mail. That
    // is the drain's whole duration (measured: ~6s per pass against ~0.5s when
    // all three answered in time), and because the poll loop waits for the pass
    // to finish, it also stretched the cadence from 3s to ~9.3s. A message
    // therefore waited most of a cadence plus a whole timeout: the 6-20s
    // observed end-to-end on 2026-08-06.
    //
    // Waiting that long buys almost nothing. The union is already declared
    // authoritative on ONE answer below ("At least one relay ANSWERED"), the
    // deposit fans out to several replicas so a blob is rarely on one relay
    // alone, and anything genuinely missed is picked up by the next pass one
    // cadence later. So once a relay has answered, the others get a short grace
    // rather than the full window.
    Timer? graceTimer;
    void armGrace() {
      if (!allSent || replies == 0 || window.isCompleted || graceTimer != null) {
        return;
      }
      graceTimer = Timer(_stragglerGrace, () {
        if (!window.isCompleted) window.complete();
      });
    }

    final sub = _fetchApp.messages().listen((m) {
      try {
        final blobs = decodeMailboxFetchResp(m.data);
        // Union by content_id: the deposit fans out to several replicas, so the
        // SAME blob can sit on more than one relay — keep the first copy only.
        var fresh = 0;
        for (final b in blobs) {
          if (seen.add(String.fromCharCodes(b.contentId))) {
            aggregated.add(b);
            fresh++;
          }
        }
        replies++;
        // An EMPTY reply is the idle steady state (one per relay per pass) —
        // silent. Log only replies that actually carried mail; `fresh` still
        // distinguishes new blobs from cross-relay duplicates of the fan-out.
        if (blobs.isNotEmpty) {
          devLog(() =>
              'xVeil[drain]: fetch reply $replies/$expected — ${blobs.length} '
              'blob(s) ($fresh new)');
        }
      } on FormatException catch (e) {
        // A malformed reply IS a real fault (not a transient) — surface it
        // after the window closes (can't rethrow out of a stream callback).
        malformed = e;
        replies++;
      }
      if (allSent && replies >= expected && !window.isCompleted) {
        window.complete();
      } else {
        armGrace();
      }
    });
    try {
      // Fire every relay's FETCH concurrently; count successful sends.
      await Future.wait(relayIds.map((relayId) async {
        anyAttempted = true;
        // Prefer the relay's KNOWN KEM key (no flaky self-resolve): the resolved
        // replica carries it (deposit-equivalent), else the relay-key cache. The
        // key is a public, network-published value, so holding it leaks nothing —
        // it just lets the onion route straight to the relay.
        Uint8List? relayKemPk = kemByRelay[NodeId(relayId).hex];
        if (relayKemPk == null) {
          try {
            relayKemPk = await _relayKeyCache?.get(NodeId(relayId));
          } catch (_) {
            relayKemPk = null; // cache is best-effort; miss → self-resolve below
          }
        }
        final viaKeyGiven = relayKemPk != null && relayKemPk.length == 32;
        // DIRECT(key-given) is the routine happy path (one line per relay per
        // pass — pure noise). The FALLBACK is the anomaly worth seeing: a
        // relay's own ad can't self-resolve, so this send will likely fail.
        if (!viaKeyGiven) {
          devLog(() => 'xVeil[drain]: relay ${NodeId(relayId).short} fetch '
              'via self-resolve(fallback) — no KEM key');
        }
        try {
          if (viaKeyGiven) {
            // KEM-key-given mailbox FETCH: straight to (relayId, relayKemPk).
            await _fetchApp.sendAnonymousAuthenticatedDirectWithReply(
              dstNodeId: relayId,
              dstX25519Pk: relayKemPk,
              dstAppId: kMailboxAppId,
              dstEndpointId: kMailboxFetchEndpointId,
              replyEndpointId: _replyEndpointId,
              data: requestBody,
            );
          } else {
            // No known key — fall back to the self-resolving authenticated send.
            await _fetchApp.sendAnonymousAuthenticatedWithReply(
              dstNodeId: relayId,
              dstAppId: kMailboxAppId,
              dstEndpointId: kMailboxFetchEndpointId,
              replyEndpointId: _replyEndpointId,
              data: requestBody,
            );
          }
          expected++;
        } catch (e) {
          // Send itself failed — that relay contributes no reply this drain.
          // Do NOT evict the relay's KEM key here: a fetch failure is a
          // TRANSPORT hiccup (session churn, a busy relay, a lost onion cell),
          // NOT evidence the key is stale — and an always-on relay's key is
          // long-lived (identity-derived, not rotated). Evicting on a transient
          // dropped the valid key after a single timeout and stranded the drain
          // on the self-resolving fallback (which can't resolve a relay's own
          // ad), so the drain never recovered. Registration re-resolves fresh
          // if the relay ever genuinely rotates.
          lastErr = e;
          devLog(() => 'xVeil[drain]: relay ${NodeId(relayId).short} send '
              'failed ($e)');
        }
      }));
      allSent = true;
      // A reply may have landed before the last send returned, in which case
      // the listener could not arm the grace yet (it waits for `allSent` so a
      // pass cannot close before every relay was even asked).
      armGrace();
      if (expected > 0 && replies < expected) {
        // Shared window: the whole drain costs ~1 RTT instead of relays×RTT.
        // [_fetchTimeout] is now only the backstop for the case where NOTHING
        // answers at all — once anything does, `armGrace` closes the window.
        try {
          await window.future.timeout(_fetchTimeout);
        } on TimeoutException {
          // Nothing answered within the backstop.
        }
      }
      // Reported here rather than in the catch above, so an EARLY close with a
      // shortfall is as visible as a timed-out one. It was only ever logged on
      // timeout, and the grace makes the early close the common path — the
      // shortfall would otherwise have gone silent exactly when it started
      // happening on every pass.
      if (expected > 0) {
        final outcome = '$replies/$expected';
        if (replies >= expected) {
          if (_lastReplyOutcome != null) {
            _lastReplyOutcome = null;
            devLog(() => 'xVeil[drain]: reply window recovered ($outcome)');
          }
        } else if (outcome != _lastReplyOutcome) {
          _lastReplyOutcome = outcome;
          devLog(
              () => 'xVeil[drain]: reply window closed with $outcome replies');
        }
      }
    } finally {
      graceTimer?.cancel();
      await sub.cancel();
    }
    if (malformed != null) throw malformed!;
    // ANNOUNCED BLOBS. An entry with no bytes is not an empty deposit — the
    // relay refuses those at the door — it is a blob too heavy for one reply,
    // and the relay is telling us to come and get it. Collect each one window
    // by window before the drain reports what it found.
    if (aggregated.any((b) => b.blob.isEmpty)) {
      final filled = <StoredMailboxBlob>[];
      for (final b in aggregated) {
        if (b.blob.isNotEmpty) {
          filled.add(b);
          continue;
        }
        final bytes = await _collectAnnounced(
          contentId: b.contentId,
          relayIds: relayIds,
          kemByRelay: kemByRelay,
        );
        if (bytes == null) {
          // Left out rather than passed on empty: an empty blob decrypts to
          // nothing and would be acked as processed, which is how a message
          // gets dropped and called delivered. Next drain tries again.
          devLog(() => 'xVeil[drain]: announced blob '
              '${NodeId(b.contentId).short} not collected this pass');
          continue;
        }
        filled.add(StoredMailboxBlob(
          senderId: b.senderId,
          contentId: b.contentId,
          blob: bytes,
        ));
      }
      aggregated
        ..clear()
        ..addAll(filled);
    }
    final anyAnswered = replies > 0;
    // At least one relay ANSWERED (even if every answer was an empty mailbox) —
    // the union is authoritative for this drain.
    if (anyAnswered) return aggregated;
    // Reaching here means NO relay ANSWERED. That is fundamentally different from
    // "the mailbox is empty": we don't actually know whether mail is waiting,
    // only that every relay we tried failed to reply. Surface it as an error so
    // the drain loop retries at a bounded cadence instead of mistaking it for an
    // idle/empty mailbox and entering the long exponential back-off — which would
    // strand pending mail at the relay for minutes after a single transient (DHT
    // self-resolve / circuit hiccup).
    if (anyAttempted) {
      throw MailboxDrainUnreachable(relayIds.length, lastErr);
    }
    // No relay to even try (not yet registered, own-ad resolved nothing) — that
    // genuinely is "nothing to fetch", so report empty and let the caller idle.
    return const [];
  }

  /// Collect one ANNOUNCED blob: ask a relay for window after window until we
  /// hold the length it stated.
  ///
  /// Each request is its own onion round trip with its own one-time reply path,
  /// so nothing has to be reused and a lost round only costs a retry. Returns
  /// null when the walk does not complete — a relay that predates the endpoint
  /// (nothing bound there, the deliver dropped), one that no longer holds the
  /// blob, or a pass that ran out of rounds. Null means "not this time", never
  /// "nothing was there": the caller leaves the blob unacked so the next drain
  /// asks again.
  ///
  /// Relays are tried in turn because the deposit fans out to several replicas
  /// and any one of them may have aged its copy out.
  Future<Uint8List?> _collectAnnounced({
    required Uint8List contentId,
    required List<Uint8List> relayIds,
    required Map<String, Uint8List> kemByRelay,
  }) async {
    for (final relayId in relayIds) {
      final relay = NodeId(relayId);
      Uint8List? kem = kemByRelay[relay.hex];
      if (kem == null || kem.length != 32) {
        try {
          kem = await _relayKeyCache?.get(relay);
        } catch (_) {
          kem = null;
        }
      }
      final out = BytesBuilder(copy: false);
      var offset = 0;
      int? total;
      var rounds = 0;
      var ok = false;
      while (rounds < _maxSliceRounds) {
        rounds++;
        final slice = await _requestSlice(
          relayId: relayId,
          relayKemPk: kem != null && kem.length == 32 ? kem : null,
          contentId: contentId,
          offset: offset,
        );
        // No answer at all: this relay cannot serve it (or is older than the
        // endpoint). Move to the next replica rather than spending the pass.
        if (slice == null) break;
        // A stated length of zero is the relay saying it holds nothing. Also
        // the answer for a blob acked from another device — stop, do not retry.
        if (slice.totalLen == 0) break;
        if (slice.totalLen > kMailboxBlobMaxBytes) break;
        total ??= slice.totalLen;
        // A relay that changes its story mid-walk is one we cannot assemble
        // from; the bytes would be a mixture of two blobs.
        if (slice.totalLen != total) break;
        if (slice.offset != offset) break;
        if (slice.bytes.isEmpty) break;
        out.add(slice.bytes);
        offset += slice.bytes.length;
        if (offset >= total) {
          ok = true;
          break;
        }
      }
      if (!ok || total == null) continue;
      final bytes = out.toBytes();
      if (bytes.length != total) continue;
      devLog(() => 'xVeil[drain]: collected announced blob '
          '${NodeId(contentId).short} — ${bytes.length}B in $rounds slice(s) '
          'from ${relay.short}');
      return bytes;
    }
    return null;
  }

  /// One slice round trip. Correlated by (content_id, offset) carried in the
  /// answer itself, because replies share one endpoint and a straggler from an
  /// earlier round would otherwise be read as this round's answer.
  Future<MailboxSlice?> _requestSlice({
    required Uint8List relayId,
    required Uint8List? relayKemPk,
    required Uint8List contentId,
    required int offset,
  }) async {
    final want = Completer<MailboxSlice?>();
    final sub = _fetchApp.messages().listen((m) {
      if (want.isCompleted) return;
      final MailboxSlice slice;
      try {
        slice = decodeMailboxSliceResp(m.data);
      } on FormatException {
        return; // not a slice reply (a straggler FETCH answer, say)
      }
      if (slice.offset != offset) return;
      for (var i = 0; i < 32; i++) {
        if (slice.contentId[i] != contentId[i]) return;
      }
      want.complete(slice);
    });
    try {
      final req = encodeMailboxSliceReq(contentId, offset);
      if (relayKemPk != null) {
        await _fetchApp.sendAnonymousAuthenticatedDirectWithReply(
          dstNodeId: relayId,
          dstX25519Pk: relayKemPk,
          dstAppId: kMailboxAppId,
          dstEndpointId: kMailboxSliceEndpointId,
          replyEndpointId: _replyEndpointId,
          data: req,
        );
      } else {
        await _fetchApp.sendAnonymousAuthenticatedWithReply(
          dstNodeId: relayId,
          dstAppId: kMailboxAppId,
          dstEndpointId: kMailboxSliceEndpointId,
          replyEndpointId: _replyEndpointId,
          data: req,
        );
      }
      return await want.future.timeout(_sliceTimeout, onTimeout: () => null);
    } catch (e) {
      devLog(() => 'xVeil[drain]: slice request failed: $e');
      return null;
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
    List<NodeId> knownRelays = const [],
  }) async {
    // Authenticated fire-and-forget ACK to every relay this drain fetched from
    // (a deposit fans out to several replicas — each holds its own copy). The
    // relay verifies the sender identity exactly like FETCH (the verified
    // src_node_id IS the receiver whose blob is dropped), so no cookie. A relay
    // predating the ack endpoint silently drops the deliver — the blob then
    // just ages out via its 7-day TTL as before; the receiver-side dedup /
    // poisoned-blob quarantine keeps the drain correct either way.
    if (contentId.length != 32) return;
    for (final relay in knownRelays) {
      Uint8List? relayKemPk;
      try {
        relayKemPk = await _relayKeyCache?.get(relay);
      } catch (_) {
        relayKemPk = null;
      }
      try {
        if (relayKemPk != null && relayKemPk.length == 32) {
          // KEM-key-given (the same routing that makes FETCH reliable), with
          // replyEndpointId 0 = NO reply block. The ack handler never answers,
          // so the one-time reply circuit this used to build per relay carried
          // nothing back — and a drain round paid for three of them on top of
          // the three it needs for FETCH.
          await _fetchApp.sendAnonymousAuthenticatedDirectWithReply(
            dstNodeId: relay.bytes,
            dstX25519Pk: relayKemPk,
            dstAppId: kMailboxAppId,
            dstEndpointId: kMailboxAckEndpointId,
            replyEndpointId: kNoReplyEndpointId,
            data: contentId,
          );
        } else {
          await _fetchApp.sendAnonymousAuthenticated(
            dstNodeId: relay.bytes,
            dstAppId: kMailboxAppId,
            dstEndpointId: kMailboxAckEndpointId,
            data: contentId,
          );
        }
      } catch (e) {
        // Best-effort: a lost ack only delays the drop to the blob's TTL.
        devLog(() =>
            'xVeil[drain]: ack to ${relay.short} failed (non-fatal): $e');
      }
    }
  }
}
