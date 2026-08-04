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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.clear) clears.add(env);
    peer?._in.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
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

Future<void> _until(
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
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
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: a, status: ContactStatus.accepted),
      );
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
      // Both sides hold all three exchanged messages before the clear. Waiting
      // for only A's two local rows made this assertion scheduling-dependent:
      // B's in-flight row could legitimately arrive after the clear watermark.
      await _until(
        () async =>
            (await sB.loadMessages(a.hex)).length >= 3 &&
            (await sA.loadMessages(b.hex)).length >= 3,
      );
      expect(await sB.loadMessages(a.hex), isNotEmpty);

      await mA.clearConversation(b);

      // A cleared locally.
      expect(
        await sA.loadMessages(b.hex),
        isEmpty,
        reason: 'A cleared its view',
      );
      // B received the clear EVENT and converged.
      await _until(() async => (await sB.loadMessages(a.hex)).isEmpty);
      expect(
        await sB.loadMessages(a.hex),
        isEmpty,
        reason: 'B converged on the propagated clear',
      );

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
      expect(
        env.body.contains('from A'),
        isFalse,
        reason: 'no message text leaks in the clear frame',
      );
    });
  });

  group('clear watermark fold (storage)', () {
    late NodeId conv;
    late SpaceOpener opener;
    late HiddenVolumeStorage s;
    // Our own author id — the one stream a peer's clear may not reach past
    // what we actually hold.
    final selfHex = _id(1).hex;

    setUp(() async {
      conv = _id(9);
      opener = _mem();
      s = HiddenVolumeStorage(opener);
      await s.open(password: 'p', createIfMissing: true);
      await s.upsertContact(
        Contact(nodeId: conv, status: ContactStatus.accepted),
      );
    });

    Future<void> incoming(int seq, String body) => s.appendMessage(
      Message(
        id: 'm$seq',
        conversationId: conv.hex,
        direction: MessageDirection.incoming,
        body: body,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000 * seq),
        status: MessageStatus.delivered,
        author: conv.hex,
        seq: seq,
      ),
    );

    /// One of OUR messages, by the honest local route: no seq is supplied, so
    /// storage allocates the next slot in our own stream.
    Future<Message> mine(HiddenVolumeStorage into, String body) =>
        into.appendMessage(
          Message(
            id: 'out-$body',
            conversationId: conv.hex,
            direction: MessageDirection.outgoing,
            body: body,
            timestamp: DateTime.fromMillisecondsSinceEpoch(500),
            status: MessageStatus.sent,
            author: selfHex,
          ),
        );

    test(
      'applyRemoteClear erases <= watermark but KEEPS newer messages',
      () async {
        await incoming(1, 'one');
        await incoming(2, 'two');
        await incoming(3, 'three'); // newer than the clear
        expect((await s.loadMessages(conv.hex)).length, 3);

        // Peer cleared up to seq 2 on its stream.
        await s.applyRemoteClear(conv, conv.hex, 7, {
          conv.hex: 2,
        }, selfHex: selfHex);

        final after = await s.loadMessages(conv.hex);
        expect(
          after.map((m) => m.id),
          ['m3'],
          reason: 'seq 1,2 cleared; seq 3 (> watermark) survives',
        );
      },
    );

    test('born-clear: a message that arrives AFTER the clear but <= the '
        'watermark never surfaces (convergence on reordering)', () async {
      // The clear lands first (seq 2 watermark), with no messages present yet.
      await s.applyRemoteClear(conv, conv.hex, 7, {
        conv.hex: 2,
      }, selfHex: selfHex);
      // Now the "late" pre-clear messages arrive out of order.
      await incoming(1, 'late one');
      await incoming(2, 'late two');
      await incoming(3, 'after the clear');

      final after = await s.loadMessages(conv.hex);
      expect(
        after.map((m) => m.id),
        ['m3'],
        reason: 'seq 1,2 are born-cleared on arrival; seq 3 surfaces',
      );
    });

    // "Clear for everyone" names BOTH authors on purpose — clearing only the
    // sender's half would leave the conversation half-standing, and the button
    // says what it does. What the sender may NOT do is reach past what our own
    // stream has actually produced.
    test('an honest clear still erases both sides: their messages AND the ones '
        'we already sent', () async {
      await incoming(1, 'theirs one');
      await incoming(2, 'theirs two');
      final first = await mine(s, 'ours one');
      final second = await mine(s, 'ours two');
      expect([first.seq, second.seq], [1, 2], reason: 'sanity: our slots 1,2');
      expect((await s.loadMessages(conv.hex)).length, 4);

      // Exactly the map emitClearConversation builds: the conversation
      // high-water, which in a 1:1 chat covers both authors.
      await s.applyRemoteClear(conv, conv.hex, 7, {
        conv.hex: 2,
        selfHex: 2,
      }, selfHex: selfHex);

      expect(
        await s.loadMessages(conv.hex),
        isEmpty,
        reason: 'everyone means everyone — our own sent messages go too',
      );
    });

    test('a clear reaching past what our stream ever produced is held to what '
        'we hold, so the chat is not muted for good', () async {
      final first = await mine(s, 'ours one');
      expect(first.seq, 1, reason: 'sanity: one slot of ours exists');

      // No honest sender can know a slot of ours we never emitted. Above that
      // line this stops being "erase what exists" and becomes "suppress what
      // has not happened yet" — which used to leave the person writing into a
      // chat that showed nothing back, with no notice and no trace.
      await s.applyRemoteClear(conv, conv.hex, 7, {
        selfHex: 3000,
      }, selfHex: selfHex);
      expect(
        await s.loadMessages(conv.hex),
        isEmpty,
        reason: 'what DID exist is still cleared',
      );

      final later = await mine(s, 'ours two');
      expect(later.seq, 2);
      expect(
        (await s.loadMessages(conv.hex)).map((m) => m.id),
        ['out-ours two'],
        reason: 'the next message we write surfaces normally',
      );
    });

    test(
      'the bound is what persists, so a restart does not restore the reach',
      () async {
        await mine(s, 'ours one');
        await s.applyRemoteClear(conv, conv.hex, 7, {
          selfHex: 3000,
        }, selfHex: selfHex);
        await s.close();

        // Same container, fresh storage object — the fold is rebuilt from the
        // stored rows, which is how the original reach survived every restart.
        final reopened = HiddenVolumeStorage(opener);
        await reopened.open(password: 'p', createIfMissing: true);
        await mine(reopened, 'after restart');
        expect(
          (await reopened.loadMessages(conv.hex)).map((m) => m.id),
          ['out-after restart'],
          reason: 'the refold reads the bounded watermark, not the sent one',
        );
        await reopened.close();
      },
    );

    test("the sender's OWN entry is left exactly as sent — it may clear its "
        'stream above anything that ever reached us', () async {
      await incoming(1, 'theirs one');

      // Above every sequence of theirs we hold: legitimate, because they know
      // their own stream and we may simply not have received the rest yet.
      await s.applyRemoteClear(conv, conv.hex, 7, {
        conv.hex: 9,
      }, selfHex: selfHex);
      expect(await s.loadMessages(conv.hex), isEmpty);

      // A straggler from below their watermark, arriving late: born-cleared,
      // which is the whole reason the watermark travels.
      await incoming(5, 'straggler');
      expect(
        await s.loadMessages(conv.hex),
        isEmpty,
        reason: 'born-clear on the sender own stream must keep working',
      );

      await incoming(10, 'after the clear');
      expect((await s.loadMessages(conv.hex)).map((m) => m.id), ['m10']);
    });

    test('a watermark entry for a third author is dropped — a sender speaks '
        'only for its own stream and ours', () async {
      final third = _id(5).hex;
      await s.appendMessage(
        Message(
          id: 'x1',
          conversationId: conv.hex,
          direction: MessageDirection.incoming,
          body: 'from a third author',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          status: MessageStatus.delivered,
          author: third,
          seq: 1,
        ),
      );

      await s.applyRemoteClear(conv, conv.hex, 7, {
        third: 500,
      }, selfHex: selfHex);

      expect(
        (await s.loadMessages(conv.hex)).map((m) => m.id),
        ['x1'],
        reason: 'the entry names neither the sender nor us',
      );
    });
  });
}
