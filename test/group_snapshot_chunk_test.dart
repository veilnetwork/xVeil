import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

// A chunked group snapshot (an inline group image overflows a single
// groupEntry frame past the auth_deliver 6144 cap): the sender splits the
// bundle into groupEntryChunk frames and the receiver reassembles them by
// transferId, then ingests the joined bundle exactly like a whole snapshot.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final sent = <Uint8List>[];
  _Link? peer;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(Uint8List.fromList(payload));
    final p = peer;
    if (p == null || p._me != dst) return;
    p._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  void inject(NodeId from, Uint8List payload) =>
      _inbound.add(InboundMessage(src: from, payload: payload));

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

/// Split a bundle exactly like MessagingService.sendGroupSnapshot, returning the
/// encoded (frame-id stamped) chunk frames.
List<Uint8List> _chunkFrames(String bundle, String tid) {
  final bytes = Uint8List.fromList(utf8.encode(bundle));
  const chunk = 4000;
  final count = (bytes.length + chunk - 1) ~/ chunk;
  return [
    for (var i = 0; i < count; i++)
      groupEntryChunkEnvelope(
        transferId: tid,
        index: i,
        count: count,
        data: Uint8List.sublistView(
          bytes,
          i * chunk,
          (i + 1) * chunk < bytes.length ? (i + 1) * chunk : bytes.length,
        ),
      ).withFrameId('grpc:$tid:$i').encode(),
  ];
}

List<Uint8List> _documentChunkFrames(String frame, String tid) {
  final bytes = Uint8List.fromList(utf8.encode(frame));
  const chunk = 1800;
  final count = (bytes.length + chunk - 1) ~/ chunk;
  return [
    for (var i = 0; i < count; i++)
      cloudDocumentChunkEnvelope(
        transferId: tid,
        index: i,
        count: count,
        data: Uint8List.sublistView(
          bytes,
          i * chunk,
          (i + 1) * chunk < bytes.length ? (i + 1) * chunk : bytes.length,
        ),
      ).withFrameId('docc:$tid:$i').encode(),
  ];
}

void main() {
  late NodeId a, b;
  late _Link tB;
  late HiddenVolumeStorage sB;
  late MessagingService mB;
  late String bundle; // > 4000 bytes → several chunks

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tB = _Link(b);
    sB = HiddenVolumeStorage(_memOpener());
    await sB.open(password: 'b', createIfMissing: true);
    mB = MessagingService(tB, sB)..start();
    addTearDown(mB.dispose);
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    bundle = jsonEncode({
      'm': {'name': 'Pics'},
      'g': [
        {'body': 'y' * 12000}, // forces 3+ chunks
      ],
    });
  });

  test(
    'chunks reassemble and fire onGroupEntry ONCE with the exact bundle',
    () async {
      NodeId? gotPeer;
      String? gotJson;
      var calls = 0;
      mB.onGroupEntry = (peer, json) {
        gotPeer = peer;
        gotJson = json;
        calls++;
      };
      final frames = _chunkFrames(bundle, 'grp:z:1');
      expect(frames.length, greaterThan(1), reason: 'must actually split');
      for (final fr in frames) {
        expect(
          fr.length,
          lessThanOrEqualTo(6144),
          reason: 'each chunk must fit under the auth_deliver cap',
        );
        tB.inject(a, fr);
        await _settle();
      }
      expect(calls, 1);
      expect(gotPeer, a);
      expect(gotJson, bundle);

      // A re-driven chunk (mailbox re-delivery / restart) is deduped: no re-fire.
      tB.inject(a, frames.first);
      await _settle();
      expect(calls, 1, reason: 'seenFrames dedups the re-driven chunk');
    },
  );

  test(
    'NON-contact sender: stranger routing + chunk admission (brick 5)',
    () async {
      final stranger = _id(9); // no contact record on B
      var acceptedCalls = 0, strangerCalls = 0;
      String? viaStranger;
      mB.onGroupEntry = (_, _) => acceptedCalls++;
      mB.onGroupEntryFromStranger = (peer, json) {
        viaStranger = json;
        strangerCalls++;
      };
      // The group layer's admission: this stranger may sync ONLY group aa11.
      mB.allowStrangerGroupSync = (peer, gidHex) async =>
          peer == stranger && gidHex == 'aa11';

      // A whole groupEntry from a stranger routes to the STRANGER callback
      // (the guarded service half judges it), never the accepted one.
      tB.inject(
        stranger,
        const WireEnvelope.groupEntry(
          '{"m":{"gid":"aa11"}}',
        ).withFrameId('grp:aa11:9').encode(),
      );
      await _settle();
      expect(strangerCalls, 1);
      expect(acceptedCalls, 0);

      // Chunks for the ADMITTED group reassemble and fire the stranger path.
      for (final fr in _chunkFrames(bundle, 'grp:aa11:7')) {
        tB.inject(stranger, fr);
        await _settle();
      }
      expect(strangerCalls, 2);
      expect(viaStranger, bundle);

      // Chunks for a group the admission REFUSES never reassemble (no RAM
      // spent, nothing fires) — silent drop.
      for (final fr in _chunkFrames(bundle, 'grp:bb22:7')) {
        tB.inject(stranger, fr);
        await _settle();
      }
      expect(strangerCalls, 2);
      expect(acceptedCalls, 0);
    },
  );

  test('out-of-order chunks still reassemble byte-exact', () async {
    String? gotJson;
    mB.onGroupEntry = (_, json) => gotJson = json;
    final frames = _chunkFrames(bundle, 'grp:z:2').reversed.toList();
    for (final fr in frames) {
      tB.inject(a, fr);
      await _settle();
    }
    expect(gotJson, bundle);
  });

  test('an incomplete snapshot never fires onGroupEntry', () async {
    var calls = 0;
    mB.onGroupEntry = (_, _) => calls++;
    final frames = _chunkFrames(bundle, 'grp:z:3');
    // Deliver everything EXCEPT the last chunk.
    for (final fr in frames.take(frames.length - 1)) {
      tB.inject(a, fr);
      await _settle();
    }
    expect(calls, 0, reason: 'a partial snapshot must not ingest');
  });

  test(
    'document chunks are accepted-contact-only and reassemble once',
    () async {
      final frame = jsonEncode({'v': 1, 'body': 'd' * 9000});
      final chunks = _documentChunkFrames(frame, 'doc:${_id(10).hex}:7');
      String? received;
      var calls = 0;
      mB.onCloudDocumentFrame = (peer, json) async {
        expect(peer, a);
        received = json;
        calls++;
        return true;
      };
      for (final chunk in chunks.reversed) {
        expect(chunk.length, lessThanOrEqualTo(6144));
        tB.inject(a, chunk);
        await _settle();
      }
      expect(received, frame);
      expect(calls, 1);
      tB.inject(a, chunks.first);
      await _settle();
      expect(calls, 1);

      final stranger = _id(9);
      for (final chunk in _documentChunkFrames(frame, 'doc:${_id(10).hex}:8')) {
        tB.inject(stranger, chunk);
        await _settle();
      }
      expect(calls, 1, reason: 'document frames never use stranger admission');
    },
  );

  test(
    'document chunks withhold ACK until persistence becomes terminal',
    () async {
      final frame = jsonEncode({'v': 1, 'body': 'r' * 9000});
      final chunks = _documentChunkFrames(frame, 'doc:${_id(11).hex}:9');
      var terminal = false;
      var calls = 0;
      mB.onCloudDocumentFrame = (_, _) async {
        calls++;
        return terminal;
      };

      for (final chunk in chunks) {
        tB.inject(a, chunk);
        await _settle();
      }
      expect(calls, 1);
      expect(
        tB.sent.where((wire) => WireEnvelope.decode(wire).kind == WireKind.ack),
        isEmpty,
        reason: 'a local storage failure must leave every chunk retryable',
      );

      terminal = true;
      for (final chunk in chunks) {
        tB.inject(a, chunk);
        await _settle();
      }
      expect(calls, 2);
      final ackIds = tB.sent
          .map(WireEnvelope.decode)
          .where((envelope) => envelope.kind == WireKind.ack)
          .map((envelope) => envelope.id)
          .whereType<String>()
          .toSet();
      expect(ackIds, hasLength(chunks.length));

      tB.inject(a, chunks.first);
      await _settle();
      expect(calls, 2, reason: 'terminal chunks dedup and only re-ack');
    },
  );
}
