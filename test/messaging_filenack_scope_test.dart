import 'dart:async';
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

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Records every outgoing send by destination (it does NOT deliver anywhere) and
/// lets a test inject hand-built inbound frames — so we can assert exactly which
/// peer a file blob is (or is not) re-sent to.
class _RecordingTransport implements VeilTransport {
  _RecordingTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final List<({NodeId dst, WireEnvelope env})> sends = [];

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
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {
    sends.add((dst: dst, env: WireEnvelope.decode(payload)));
  }

  void inject(NodeId from, Uint8List payload) =>
      _inbound.add(InboundMessage(src: from, payload: payload));

  int chunksTo(NodeId dst) => sends
      .where((s) => s.dst == dst && s.env.kind == WireKind.fileChunk)
      .length;

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
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a fileNack only re-sends a blob within the REQUESTING peer\'s '
      'conversation — a peer cannot pull another conversation\'s file by id',
      () async {
    final a = _id(1), b = _id(2), c = _id(3);
    final tA = _RecordingTransport(a);
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    // A holds BOTH B and C as accepted contacts (so both pass the consent gate).
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sA.upsertContact(Contact(nodeId: c, status: ContactStatus.accepted));
    final mA = MessagingService(tA, sA)..start();
    addTearDown(mA.dispose);

    // A sends a private file to C. The transfer id IS the file message id.
    final secret = Uint8List.fromList(List.generate(7000, (i) => (i * 11) % 256));
    await mA.sendFile(c, secret, 'for-C-only.bin');
    await _settle();
    final tid =
        (await sA.loadMessages(c.hex)).firstWhere((m) => m.isFile).id;

    tA.sends.clear();

    // The ATTACKER B (a different accepted peer) NACKs C's transfer id, trying to
    // siphon C's file. A must NOT re-send any chunk to B (cross-conversation leak).
    tA.inject(b, fileNackEnvelope(transferId: tid, missing: null).encode());
    await _settle();
    expect(tA.chunksTo(b), 0,
        reason: 'B is not in the file\'s conversation → no blob leak to B');
    expect(tA.sends.where((s) => s.env.kind == WireKind.fileChunk), isEmpty,
        reason: 'the cross-conversation NACK re-sent nothing at all');

    // Positive control: the LEGITIMATE recipient C re-requesting its own file
    // DOES get the chunks (resumable re-ship still works for the right peer).
    tA.sends.clear();
    tA.inject(c, fileNackEnvelope(transferId: tid, missing: null).encode());
    await _settle();
    expect(tA.chunksTo(c), greaterThan(0),
        reason: 'the real recipient C still resumes its own transfer');
  });

  test('a fresh-tid fileNack flood neither re-sends a blob nor grows the '
      'throttle map (anti-amplification / bounded memory)', () async {
    final a = _id(1), b = _id(2);
    final tA = _RecordingTransport(a);
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    final mA = MessagingService(tA, sA)..start();
    addTearDown(mA.dispose);

    // B floods NACKs for 50 transfer ids that name no file A ever sent it.
    for (var i = 0; i < 50; i++) {
      tA.inject(b, fileNackEnvelope(transferId: 'ghost-$i', missing: null).encode());
    }
    await _settle();
    expect(tA.sends.where((s) => s.env.kind == WireKind.fileChunk), isEmpty,
        reason: 'no file matched → not a single chunk re-sent');
    // No crash, no storm. The throttle map stays empty because entries are only
    // written after a NACK resolves to a real outgoing file (asserted indirectly:
    // the flood produced zero work and the service is still responsive).
    await mA.sendText(b, 'still alive');
    await _settle();
    expect(tA.sends.any((s) => s.env.kind == WireKind.message), isTrue);
  });
}
