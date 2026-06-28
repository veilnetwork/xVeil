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

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// 1:1 link that also captures the clear frames it carries, so a test can assert
/// a clear event leaks NO message id/text on the wire (only the watermark).
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  final List<WireEnvelope> clears = [];

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.clear) clears.add(env);
    peer?._in.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Future<void> _until(Future<bool> Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  group('clear propagates as an event (messaging)', () {
    late NodeId a, b;
    late _Link tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;

    setUp(() async {
      a = _id(1);
      b = _id(2);
      tA = _Link(a);
      tB = _Link(b);
      tA.peer = tB;
      tB.peer = tA;
      sA = HiddenVolumeStorage(_mem());
      sB = HiddenVolumeStorage(_mem());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      mA = MessagingService(tA, sA)..start();
      mB = MessagingService(tB, sB)..start();
      await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
      await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    });

    tearDown(() async {
      await mA.dispose();
      await mB.dispose();
    });

    test('A clears -> B converges to the same emptied state, and the clear '
        'frame carries ONLY a watermark (no message id/text)', () async {
      await mA.sendText(b, 'from A one');
      await mA.sendText(b, 'from A two');
      await mB.sendText(a, 'from B one');
      // Both sides hold the exchanged messages.
      await _until(() async =>
          (await sB.loadMessages(a.hex)).isNotEmpty &&
          (await sA.loadMessages(b.hex)).length >= 2);
      expect(await sB.loadMessages(a.hex), isNotEmpty);

      await mA.clearConversation(b);

      // A cleared locally.
      expect(await sA.loadMessages(b.hex), isEmpty, reason: 'A cleared its view');
      // B received the clear EVENT and converged.
      await _until(() async => (await sB.loadMessages(a.hex)).isEmpty);
      expect(await sB.loadMessages(a.hex), isEmpty,
          reason: 'B converged on the propagated clear');

      // Deniability: the wire clear frame carries only the watermark map — no
      // cleared message id, no message text.
      expect(tA.clears, isNotEmpty, reason: 'a clear frame was sent');
      final env = tA.clears.last;
      expect(env.id, isNull, reason: 'no message id on a clear frame');
      final body = jsonDecode(env.body);
      expect(body, isA<Map>(), reason: 'body is the {author: hw} watermark');
      (body as Map).forEach((k, v) {
        expect(k, isA<String>());
        expect(v, isA<int>(), reason: 'only per-author seq numbers travel');
      });
      expect(env.body.contains('from A'), isFalse,
          reason: 'no message text leaks in the clear frame');
    });
  });

  group('clear watermark fold (storage)', () {
    late NodeId conv;
    late HiddenVolumeStorage s;

    setUp(() async {
      conv = _id(9);
      s = HiddenVolumeStorage(_mem());
      await s.open(password: 'p', createIfMissing: true);
      await s.upsertContact(
          Contact(nodeId: conv, status: ContactStatus.accepted));
    });

    Future<void> incoming(int seq, String body) => s.appendMessage(Message(
          id: 'm$seq',
          conversationId: conv.hex,
          direction: MessageDirection.incoming,
          body: body,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000 * seq),
          status: MessageStatus.delivered,
          author: conv.hex,
          seq: seq,
        ));

    test('applyRemoteClear erases <= watermark but KEEPS newer messages',
        () async {
      await incoming(1, 'one');
      await incoming(2, 'two');
      await incoming(3, 'three'); // newer than the clear
      expect((await s.loadMessages(conv.hex)).length, 3);

      // Peer cleared up to seq 2 on its stream.
      await s.applyRemoteClear(conv, conv.hex, 7, {conv.hex: 2});

      final after = await s.loadMessages(conv.hex);
      expect(after.map((m) => m.id), ['m3'],
          reason: 'seq 1,2 cleared; seq 3 (> watermark) survives');
    });

    test('born-clear: a message that arrives AFTER the clear but <= the '
        'watermark never surfaces (convergence on reordering)', () async {
      // The clear lands first (seq 2 watermark), with no messages present yet.
      await s.applyRemoteClear(conv, conv.hex, 7, {conv.hex: 2});
      // Now the "late" pre-clear messages arrive out of order.
      await incoming(1, 'late one');
      await incoming(2, 'late two');
      await incoming(3, 'after the clear');

      final after = await s.loadMessages(conv.hex);
      expect(after.map((m) => m.id), ['m3'],
          reason: 'seq 1,2 are born-cleared on arrival; seq 3 surfaces');
    });
  });
}
