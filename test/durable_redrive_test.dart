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
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// 1:1 fake link with an [online] switch (offline = the SENDER's egress drops,
/// so an offline B still RECEIVES but its acks are lost — the asymmetric-loss
/// shape that forces durable re-drives) and direct inbound injection.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  bool online = true;

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
    if (!online) return; // our egress is down — drop
    final p = peer;
    if (p == null || p._me != dst) return; // routed by dst, like the real net
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

void main() {
  // ── Receive-handler idempotency (raw duplicates, as a mailbox re-delivery /
  // cross-restart durable re-drive presents them: no session dedup to hide
  // behind). These pin the property the durable migration RELIES on: processing
  // the same frame twice must converge to the same state, with no duplication.
  group('receive-handler idempotency on raw duplicate frames', () {
    late NodeId a, b;
    late _Link tB;
    late HiddenVolumeStorage sB;
    late MessagingService mB;

    setUp(() async {
      a = _id(1);
      b = _id(2);
      tB = _Link(b);
      sB = HiddenVolumeStorage(_memOpener());
      await sB.open(password: 'b', createIfMissing: true);
      mB = MessagingService(tB, sB)..start();
      addTearDown(mB.dispose);
      await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    });

    Future<void> injectMessage(String id, String body, int seq) async {
      tB.inject(
          a,
          WireEnvelope.message(body,
                  id: id, sentAtMs: 1000 + seq, seq: seq)
              .encode());
      await _settle();
    }

    test('duplicate edit applies once: text converges, history holds ONE '
        'edit version, log does not regrow', () async {
      await injectMessage('m1', 'original', 1);
      final edit = WireEnvelope.edit('m1', 'edited', seq: 2).encode();
      tB.inject(a, edit);
      await _settle();
      tB.inject(a, edit); // re-drive of the same frame
      await _settle();

      final msg = (await sB.loadMessages(a.hex)).single;
      expect(msg.body, 'edited');
      expect(msg.edited, isTrue);
      final history = await sB.loadMessageHistory(a.hex, 'm1');
      expect(history.length, 2,
          reason: 'original + exactly one edit version — the duplicate '
              'must not add a third');
    });

    test('a STALE edit re-driven after a newer one does not regress the text '
        '(R5 strictly-newer)', () async {
      await injectMessage('m1', 'original', 1);
      final older = WireEnvelope.edit('m1', 'first edit', seq: 2).encode();
      final newer = WireEnvelope.edit('m1', 'second edit', seq: 3).encode();
      tB.inject(a, older);
      await _settle();
      tB.inject(a, newer);
      await _settle();
      tB.inject(a, older); // out-of-order re-drive of the superseded edit
      await _settle();

      expect((await sB.loadMessages(a.hex)).single.body, 'second edit',
          reason: 'the older seq must never overwrite the newer text');
    });

    test('duplicate delete stays deleted and is a harmless no-op', () async {
      await injectMessage('m1', 'to be unsent', 1);
      final del = const WireEnvelope.del('m1').encode();
      tB.inject(a, del);
      await _settle();
      expect(await sB.loadMessages(a.hex), isEmpty);
      tB.inject(a, del); // re-drive
      await _settle();
      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sB.isMessageDeleted(a.hex, 'm1'), isTrue);
    });

    test('duplicate clear applies once and converges: <= watermark erased, '
        'newer kept', () async {
      await injectMessage('m1', 'old 1', 1);
      await injectMessage('m2', 'old 2', 2);
      await injectMessage('m3', 'kept', 3);
      final clear = WireEnvelope.clear(jsonEncode({a.hex: 2}), seq: 4).encode();
      tB.inject(a, clear);
      await _settle();
      tB.inject(a, clear); // re-drive
      await _settle();

      final left = await sB.loadMessages(a.hex);
      expect(left.map((m) => m.id), ['m3'],
          reason: 'seq 1..2 cleared, seq 3 kept — twice-applied is the same');

      // A message arriving AFTER the duplicate clear, above the watermark,
      // still lands (the duplicate must not have widened the clear).
      await injectMessage('m4', 'newer still', 5);
      expect((await sB.loadMessages(a.hex)).map((m) => m.id), ['m3', 'm4']);
    });

    test('duplicate accept keeps a single accepted contact', () async {
      await sB.upsertContact(
          Contact(nodeId: a, status: ContactStatus.pendingOutgoing));
      final accept = const WireEnvelope.accept().encode();
      tB.inject(a, accept);
      await _settle();
      expect((await sB.getContact(a))!.status, ContactStatus.accepted);
      tB.inject(a, accept); // re-drive
      await _settle();
      expect((await sB.getContact(a))!.status, ContactStatus.accepted);
      expect((await sB.loadConversations()).length, 1);
    });

    test('duplicate reconnect keeps a single pendingIncoming intro', () async {
      await sB.removeConversation(a); // B does not know A at all
      final reconnect = const WireEnvelope.reconnect('').encode();
      tB.inject(a, reconnect);
      await _settle();
      tB.inject(a, reconnect); // re-drive
      await _settle();

      final contact = await sB.getContact(a);
      expect(contact!.status, ContactStatus.pendingIncoming);
      expect((await sB.loadConversations()).length, 1);
      expect(await sB.loadMessages(a.hex), isEmpty,
          reason: 'an empty re-intro greeting stores no message');
    });
  });

  // ── Durable re-drive per migrated control-frame type: the frame survives a
  // lost first live attempt (and a restart), the flush re-drives it, the
  // receiver processes it once + acks, and the ack retires it from the outbox.
  group('durable re-drive of migrated control frames', () {
    late NodeId a, b;
    late _Link tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;
    late DateTime clock;

    Future<void> flushA() async {
      await mA.flushOutbox();
      await _settle();
    }

    setUp(() async {
      clock = DateTime(2026, 1, 1, 12);
      a = _id(1);
      b = _id(2);
      tA = _Link(a);
      tB = _Link(b);
      tA.peer = tB;
      tB.peer = tA;
      sA = HiddenVolumeStorage(_memOpener());
      sB = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      mA = MessagingService(tA, sA, now: () => clock)..start();
      mB = MessagingService(tB, sB, now: () => clock)..start();
      addTearDown(mA.dispose);
      addTearDown(mB.dispose);
      // Empty greeting: the handshake stores no message, so each test's
      // conversation holds exactly what the test itself seeds.
      await mA.sendRequest(b, '');
      await _settle();
      await mB.acceptContact(a);
      await _settle();
    });

    /// One delivered message from A so there is something to edit/delete/clear.
    Future<String> seed(String body) async {
      await mA.sendText(b, body);
      await _settle();
      return (await sA.loadMessages(b.hex)).firstWhere((m) => m.body == body).id;
    }

    test('EDIT lost on first attempt is re-driven, applied once, and the ack '
        'retires it', () async {
      final id = await seed('meet at noon');
      tA.online = false; // the lossy first attempt eats the edit
      await mA.editOwnMessage(id, 'meet at ONE');
      await _settle();
      expect((await sB.loadMessages(a.hex)).single.body, 'meet at noon',
          reason: 'nothing reached B yet');
      expect((await sA.pendingOutboxFrames()).length, 1);

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21)); // past the re-drive backoff
      await flushA();

      final onB = (await sB.loadMessages(a.hex)).single;
      expect(onB.body, 'meet at ONE');
      expect(onB.edited, isTrue);
      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: "B's ack retired the frame");
    });

    test('a re-driven EDIT is processed once even while the acks are lost '
        '(receiver dedup), then converges when the ack path heals', () async {
      final id = await seed('draft');
      tB.online = false; // B receives, but every ack it sends is lost
      await mA.editOwnMessage(id, 'final text');
      await _settle();
      expect((await sB.loadMessages(a.hex)).single.body, 'final text');

      // Ack never arrived → still pending → re-drive past the backoff.
      expect((await sA.pendingOutboxFrames()).length, 1);
      clock = clock.add(const Duration(seconds: 21));
      await flushA();
      expect((await sB.loadMessageHistory(a.hex, id)).length, 2,
          reason: 'original + ONE edit — the re-drive was deduped, not '
              're-applied');

      tB.online = true;
      clock = clock.add(const Duration(seconds: 41)); // past the doubled step
      await flushA();
      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: 'the healed ack path finally retired the frame');
      expect((await sB.loadMessages(a.hex)).single.body, 'final text');
    });

    test('DELETE-for-everyone lost on first attempt is re-driven and purges '
        'the peer copy', () async {
      final id = await seed('remove me');
      tA.online = false;
      await mA.deleteForEveryone(id);
      await _settle();
      expect((await sB.loadMessages(a.hex)).length, 1,
          reason: 'the unsend never reached B');

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sB.isMessageDeleted(a.hex, id), isTrue);
      expect(await sA.pendingOutboxFrames(), isEmpty);
    });

    test('CLEAR lost on first attempt is re-driven and empties the peer copy',
        () async {
      await seed('history line');
      tA.online = false;
      await mA.clearConversation(b);
      await _settle();
      expect((await sB.loadMessages(a.hex)), isNotEmpty,
          reason: 'the clear never reached B');

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sA.pendingOutboxFrames(), isEmpty);
    });

    test('two conversations cleared at the SAME seq do not collide in the '
        'outbox (peer-scoped frame id)', () async {
      // A third party C. The _Link fake routes to ONE peer, so point A's link
      // at the intended destination before each interaction (the seq streams
      // are per-conversation either way — the collision under test is in A's
      // OWN outbox ids, not on the wire).
      final c = _id(3);
      final tC = _Link(c);
      final sC = HiddenVolumeStorage(_memOpener());
      await sC.open(password: 'c', createIfMissing: true);
      final mC = MessagingService(tC, sC, now: () => clock)..start();
      addTearDown(mC.dispose);
      tC.peer = tA;

      tA.peer = tC;
      await mA.sendRequest(c, '');
      await _settle();
      await mC.acceptContact(a);
      await _settle();

      tA.peer = tB;
      await seed('to B');
      tA.peer = tC;
      await mA.sendText(c, 'to C');
      await _settle();

      // Clear BOTH while offline: same per-conversation seq on each stream.
      tA.online = false;
      await mA.clearConversation(b);
      await mA.clearConversation(c);
      await _settle();
      final pending = await sA.pendingOutboxFrames();
      final clearIds =
          pending.map((f) => f.frameId).where((x) => x.startsWith('clear:'));
      expect(clearIds.length, 2,
          reason: 'both clears must be enqueued — a seq-only id would have '
              'collapsed them to one');

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      tA.peer = tB;
      await flushA();
      tA.peer = tC;
      clock = clock.add(const Duration(seconds: 41));
      await flushA();

      expect(await sB.loadMessages(a.hex), isEmpty, reason: 'B side cleared');
      expect(await sC.loadMessages(a.hex), isEmpty, reason: 'C side cleared');
    });

    test('ACCEPT lost on first attempt is re-driven; the honoured accept is '
        'acked and retired', () async {
      // Fresh pair: C requests A; A accepts while its egress is down.
      final c = _id(3);
      final tC = _Link(c);
      final sC = HiddenVolumeStorage(_memOpener());
      await sC.open(password: 'c', createIfMissing: true);
      final mC = MessagingService(tC, sC, now: () => clock)..start();
      addTearDown(mC.dispose);
      tC.peer = tA;
      tA.peer = tC;

      await mC.sendRequest(a, '');
      await _settle();
      expect((await sA.getContact(c))!.status, ContactStatus.pendingIncoming);

      tA.online = false;
      await mA.acceptContact(c);
      await _settle();
      expect((await sC.getContact(a))!.status, ContactStatus.pendingOutgoing,
          reason: 'the accept never reached C');
      expect(
          (await sA.pendingOutboxFrames()).map((f) => f.frameId),
          contains('accept:${c.hex}'));

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect((await sC.getContact(a))!.status, ContactStatus.accepted,
          reason: 'the re-driven accept completed the handshake');
      expect(
          (await sA.pendingOutboxFrames()).map((f) => f.frameId),
          isNot(contains('accept:${c.hex}')),
          reason: "C's ack (sent from the accept arm) retired the frame");
    });

    test('call health heartbeat is live-only and never enters durable outbox',
        () async {
      tA.online = false;
      await mA.sendCallSignal(
        b,
        const CallSignal(callId: 'call-live', type: CallSignalType.health),
      );
      await _settle();

      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: 'liveness beats are superseded by the next beat and must not '
              'survive as restart/outbox work');
    });

    test('non-contact group-call lifecycle re-drives by membership and dispatches',
        () async {
      await sA.removeConversation(b);
      await sB.removeConversation(a);
      final gid = _id(8);
      mA.allowStrangerGroupSync = (peer, groupIdHex) async =>
          peer == b && groupIdHex == gid.hex;
      String? received;
      mB.onGroupCallSignal = (peer, frameJson) async {
        if (peer == a) received = frameJson;
        return true;
      };
      final signal = GroupCallSignal(
        groupId: gid,
        callId: 'room',
        author: a,
        membershipEpoch: 1,
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true),
        sentAtMs: clock.millisecondsSinceEpoch,
        nonce: '00112233445566778899aabb',
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      tA.online = false;
      await mA.sendGroupCallSignal(b, signal, '{"ciphertext":true}');
      await _settle();
      expect(received, isNull);
      expect(
        (await sA.pendingOutboxFrames()).single.frameId,
        startsWith('gcall:${gid.hex}:room:announce:'),
      );

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();
      expect(received, '{"ciphertext":true}');
      expect(
        (await sA.pendingOutboxFrames()).map((frame) => frame.frameId),
        isEmpty,
      );
    });

    test('stale group-call lifecycle retires before a non-contact re-drive',
        () async {
      await sA.removeConversation(b);
      await sB.removeConversation(a);
      final gid = _id(8);
      mA.allowStrangerGroupSync = (peer, groupIdHex) async => true;
      var received = false;
      mB.onGroupCallSignal = (_, _) async {
        received = true;
        return true;
      };
      final signal = GroupCallSignal(
        groupId: gid,
        callId: 'stale-room',
        author: a,
        membershipEpoch: 1,
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true),
        sentAtMs: clock.millisecondsSinceEpoch,
        nonce: 'ffeeddccbbaa998877665544',
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      tA.online = false;
      await mA.sendGroupCallSignal(b, signal, '{}');
      await _settle();
      clock = clock.add(const Duration(minutes: 3));
      tA.online = true;
      await flushA();
      expect(received, isFalse);
      expect(await sA.pendingOutboxFrames(), isEmpty);
    });

    test('repeated renegotiates enqueue DISTINCT durable frames (a type-only '
        'id would dedup the second toggle away)', () async {
      tA.online = false;
      await mA.sendCallSignal(
        b,
        const CallSignal(
          callId: 'reneg',
          type: CallSignalType.renegotiate,
          media: CallMedia(audio: true, video: true, screen: true),
        ),
      );
      clock = clock.add(const Duration(seconds: 1));
      await mA.sendCallSignal(
        b,
        const CallSignal(
          callId: 'reneg',
          type: CallSignalType.renegotiate,
          media: CallMedia(audio: true, video: true),
        ),
      );
      await _settle();

      final ids = (await sA.pendingOutboxFrames())
          .map((f) => f.frameId)
          .where((x) => x.startsWith('call:reneg:renegotiate:'))
          .toList();
      expect(ids.length, 2);
      expect(ids.toSet().length, 2, reason: 'sentAt-keyed ids must differ');
    });

    test('stale durable call offer is retired instead of re-driven forever',
        () async {
      tA.online = false;
      await mA.sendCallSignal(
        b,
        CallSignal(
          callId: 'call-stale',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true, video: true),
          posture: CallPosture.direct,
        ),
      );
      await _settle();
      expect(
          (await sA.pendingOutboxFrames()).map((f) => f.frameId),
          contains('call:call-stale:offer'));

      tA.online = true;
      clock = clock.add(const Duration(minutes: 3));
      await flushA();

      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: 'a missed real-time call is no longer useful minutes later');
      expect(await sB.pendingOutboxFrames(), isEmpty,
          reason: 'the stale offer was not delivered to B');
    });

    test('peer inbound within the nudge grace does not duplicate a just-sent '
        'call frame; the backoff re-drive still heals a lost ack', () async {
      tB.online = false; // B receives, but every ack it sends is lost
      var offers = 0;
      final sub = tB.messages().listen((m) {
        try {
          if (WireEnvelope.decode(m.payload).frameId == 'call:dup:offer') {
            offers++;
          }
        } catch (_) {}
      });
      addTearDown(sub.cancel);

      await mA.sendCallSignal(
        b,
        CallSignal(
          callId: 'dup',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
        ),
      );
      await _settle();
      expect(offers, 1);

      // B's health beat lands seconds later — the call's steady inbound. The
      // nudge must NOT rewind the just-sent offer (its ack is merely in
      // flight) into a duplicate re-drive.
      clock = clock.add(const Duration(seconds: 2));
      tA.inject(
        b,
        WireEnvelope.callSignal(
          const CallSignal(callId: 'dup', type: CallSignalType.health)
              .encode(),
        ).encode(),
      );
      await _settle();
      expect(offers, 1,
          reason: 'inbound during the grace must not duplicate the send');

      // The ack really was lost → the regular backoff re-drive still fires.
      clock = clock.add(const Duration(seconds: 21));
      await flushA();
      expect(offers, 2, reason: 'the durable guarantee is untouched');
    });

    test('RECONNECT to a wiped peer is durable: re-intro survives the lost '
        'first attempt, and accepting heals the conversation end-to-end',
        () async {
      // B wipes A completely (Case-A): A's plain messages now hit B's consent
      // gate and drop.
      await sB.removeConversation(a);
      await mA.sendText(b, 'anyone home?');
      await _settle();
      expect(await sB.getContact(a), isNull, reason: 'message dropped at gate');

      // First reconnect attempt fires past the threshold — but the live path
      // eats it (A offline at that moment).
      tA.online = false;
      clock = clock.add(const Duration(minutes: 3));
      await flushA();
      expect(
          (await sA.pendingOutboxFrames()).map((f) => f.frameId),
          contains('reconnect:${b.hex}'));
      expect(await sB.getContact(a), isNull);

      // The durable pipeline re-drives it once the egress heals — no need to
      // wait out the 15-min reconnect ladder.
      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();
      expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming,
          reason: 're-driven re-intro surfaced on the wiped peer');

      // B re-accepts → the stuck message flows → everything retires.
      await mB.acceptContact(a);
      await _settle();
      clock = clock.add(const Duration(seconds: 41));
      await flushA();
      await mB.flushOutbox();
      await _settle();
      clock = clock.add(const Duration(minutes: 11)); // past any frame backoff
      await flushA();
      await mB.flushOutbox();
      await _settle();

      expect((await sB.loadMessages(a.hex)).map((m) => m.body),
          contains('anyone home?'),
          reason: 'the conversation healed after re-accept');
      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: "B now acks A's durable frames — reconnect retired");
      expect(await sB.pendingOutboxFrames(), isEmpty,
          reason: "A acked B's accept — nothing left pending");
    });

    test('a pending RECONNECT is retired when every stuck message hits its '
        'give-up (no forever re-drive at a ghost peer)', () async {
      tA.peer = null; // B is gone for good — nothing A sends arrives anywhere
      await mA.sendText(b, 'into the void');
      await _settle();

      // Walk the fake clock past the reconnect threshold (frame enqueued), then
      // past the per-message give-up (message → failed → frame retired).
      for (var i = 0; i < 8; i++) {
        clock = clock.add(const Duration(minutes: 16));
        await flushA();
      }

      expect((await sA.loadMessages(b.hex)).single.status,
          MessageStatus.failed);
      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: 'the reconnect frame did not outlive the messages it '
              'was reviving');
    });

    test('a durable frame survives a RESTART: a fresh service over the same '
        'storage re-drives it', () async {
      final id = await seed('pre-restart');
      tA.online = false;
      await mA.editOwnMessage(id, 'edited before restart');
      await _settle();
      expect((await sA.pendingOutboxFrames()).length, 1);

      // "Restart": tear down the service, keep the storage, bring up a new one.
      await mA.dispose();
      final mA2 = MessagingService(tA, sA, now: () => clock)..start();
      addTearDown(mA2.dispose);

      tA.online = true;
      await mA2.flushOutbox(); // no in-memory backoff yet → immediate re-drive
      await _settle();

      expect((await sB.loadMessages(a.hex)).single.body,
          'edited before restart');
      expect(await sA.pendingOutboxFrames(), isEmpty);
    });

    test('a frame to a REMOVED conversation is retired, not re-driven into a '
        'void relationship', () async {
      final id = await seed('temp');
      tA.online = false;
      await mA.editOwnMessage(id, 'never mind');
      await _settle();
      expect((await sA.pendingOutboxFrames()).length, 1);

      await sA.removeConversation(b); // relationship torn down locally
      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect(await sA.pendingOutboxFrames(), isEmpty,
          reason: 'moot frame dropped with its conversation');
      expect((await sB.loadMessages(a.hex)).single.body, 'temp',
          reason: 'nothing was delivered — the frame was retired locally');
    });
  });
}
