// `prefer_initializing_formals` is suppressed deliberately: the constructor
// takes external NAMED params (`client`, `fetchApp`, …) but the fields are
// private (`_client`, …), and Dart forbids private `this._x` formals as
// cross-library named arguments — so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../../core/ids.dart';
import 'veil_mailbox.dart';

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
/// message capped at one 512-byte cell, so a real (KB-sized) `MailboxPutPayload`
/// is split across N chunks; the relay reassembles by `content_id` before
/// storing. (The FETCH reply path already fragments, so only PUT needs this.)
const int kMailboxPutChunkDataBytes = 240;

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
class VeilNetworkMailboxRelay implements VeilMailboxRelay {
  VeilNetworkMailboxRelay({
    required veil.VeilClient client,
    required veil.AppHandle fetchApp,
    required Uint8List srcAppId,
    required int replyEndpointId,
    int putHopCount = 1,
    int putReplicaFanout = 3,
    Duration fetchTimeout = const Duration(seconds: 12),
  })  : _client = client,
        _fetchApp = fetchApp,
        _srcAppId = srcAppId,
        _replyEndpointId = replyEndpointId,
        _putHopCount = putHopCount,
        _putReplicaFanout = putReplicaFanout,
        _fetchTimeout = fetchTimeout {
    if (_srcAppId.length != 32) {
      throw ArgumentError('srcAppId must be 32 bytes, got ${_srcAppId.length}');
    }
  }

  final veil.VeilClient _client;
  final veil.AppHandle _fetchApp;
  final Uint8List _srcAppId;
  final int _replyEndpointId;
  final int _putHopCount;
  final int _putReplicaFanout;
  final Duration _fetchTimeout;

  @override
  Future<void> put({
    required NodeId receiver,
    required Uint8List contentId,
    required NodeId sender,
    required Uint8List blob,
  }) async {
    final replicas =
        await _client.mailbox.lookupRendezvousReplicas(receiver.bytes);
    final usable = replicas
        .where((r) => r.rendezvousKemPk.length == 32)
        .take(_putReplicaFanout)
        .toList();
    debugPrint('xVeil[stash-put]: dst=${receiver.hex.substring(0, 8)} '
        'replicas_resolved=${replicas.length} usable(KEM)=${usable.length}');
    if (usable.isEmpty) {
      throw StateError(
          'no rendezvous replica with a usable KEM key for ${receiver.hex} — '
          'recipient has not advertised a mailbox relay (or ad not resolved yet)');
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
    var anyOk = false;
    for (final r in usable) {
      try {
        for (final chunk in chunks) {
          await _client.sendAnonymousDirect(
            targetNodeId: r.relayNodeId,
            targetX25519Pk: Uint8List.fromList(r.rendezvousKemPk),
            targetAppId: kMailboxAppId,
            targetEndpointId: kMailboxPutEndpointId,
            srcAppId: _srcAppId,
            data: chunk,
            hopCount: _putHopCount,
          );
        }
        anyOk = true;
      } catch (e) {
        lastErr = e;
      }
    }
    if (!anyOk) {
      throw StateError('all ${usable.length} mailbox deposits failed: $lastErr');
    }
  }

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie, // ignored — verified identity is the auth
  }) async {
    // Resolving our own mailbox ad over the DHT can transiently time out
    // (LookupRendezvousReplicasResp); treat that as "nothing this round" so the
    // caller's periodic drain retries rather than surfacing a transient error.
    final List<veil.RendezvousReplica> replicas;
    try {
      replicas = await _client.mailbox.lookupRendezvousReplicas(me.bytes);
    } catch (_) {
      return const [];
    }
    if (replicas.isEmpty) {
      // We have not (yet) advertised a mailbox relay we can fetch from.
      return const [];
    }
    // Try our published relays in order until one answers within the window. A
    // send that throws (circuit not yet formed) or a relay that doesn't answer
    // in time falls through to the next replica; if none answer we return empty
    // and the caller retries on its next drain tick.
    for (final r in replicas) {
      final completer = Completer<veil.IncomingMessage>();
      final sub = _fetchApp.messages().listen((m) {
        if (!completer.isCompleted) completer.complete(m);
      });
      try {
        await _fetchApp.sendAnonymousAuthenticatedWithReply(
          dstNodeId: r.relayNodeId,
          dstAppId: kMailboxAppId,
          dstEndpointId: kMailboxFetchEndpointId,
          replyEndpointId: _replyEndpointId,
          data: Uint8List(0),
        );
        final reply = await completer.future.timeout(_fetchTimeout);
        return decodeMailboxFetchResp(reply.data);
      } on FormatException {
        // A malformed reply IS a real fault (not a transient) — surface it.
        rethrow;
      } catch (_) {
        // Transient (send threw / no reply in window) — try the next replica.
        continue;
      } finally {
        await sub.cancel();
      }
    }
    return const [];
  }

  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
  }) async {
    // No-op: the network mailbox has no ack endpoint. FETCH is non-destructive
    // (blobs age out via the relay's quota / validity window); de-duplication
    // is receiver-side by contentId. See the class doc.
  }
}
