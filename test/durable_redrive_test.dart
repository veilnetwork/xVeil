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
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/state/device_silence.dart';
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

  /// Frames that actually left this egress, for tests that assert on the RATE
  /// of sending rather than on what arrived.
  int sent = 0;

  /// The durable frame id of each sent frame that carries one — so a test can
  /// count the frames it queued apart from everything else a flush sends.
  final sentFrameIds = <String>[];

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
    if (!online) return; // our egress is down — drop
    sent++;
    try {
      final fid = WireEnvelope.decode(payload).frameId;
      if (fid != null) sentFrameIds.add(fid);
    } catch (_) {}
    final p = peer;
    if (p == null || p._me != dst) return; // routed by dst, like the real net
    p._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  /// A delivery whose direct session named the DEVICE it came from, as veil
  /// reports it for a device of a multi-device identity.
  void injectFromDevice(NodeId from, NodeId device, Uint8List payload) =>
      _inbound.add(
        InboundMessage(
          src: from,
          srcDevice: device,
          payload: payload,
          provenance: SenderProvenance.sessionPeer,
        ),
      );

  void inject(NodeId from, Uint8List payload) => _inbound.add(
    InboundMessage(
      src: from,
      payload: payload,
      provenance: SenderProvenance.sessionPeer,
    ),
  );

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
      await sB.upsertContact(
        // These tests are about the durable RE-DRIVE of a clear, not about
        // whose request counts, so they name the policy instead of riding the
        // default — which now asks rather than applies.
        Contact(
          nodeId: a,
          status: ContactStatus.accepted,
          clearPolicy: ClearRequestPolicy.anyone,
        ),
      );
    });

    Future<void> injectMessage(String id, String body, int seq) async {
      tB.inject(
        a,
        WireEnvelope.message(
          body,
          id: id,
          sentAtMs: 1000 + seq,
          seq: seq,
        ).encode(),
      );
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
      expect(
        history.length,
        2,
        reason:
            'original + exactly one edit version — the duplicate '
            'must not add a third',
      );
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

      expect(
        (await sB.loadMessages(a.hex)).single.body,
        'second edit',
        reason: 'the older seq must never overwrite the newer text',
      );
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
      expect(
        left.map((m) => m.id),
        ['m3'],
        reason: 'seq 1..2 cleared, seq 3 kept — twice-applied is the same',
      );

      // A message arriving AFTER the duplicate clear, above the watermark,
      // still lands (the duplicate must not have widened the clear).
      await injectMessage('m4', 'newer still', 5);
      expect((await sB.loadMessages(a.hex)).map((m) => m.id), ['m3', 'm4']);
    });

    test('duplicate accept keeps a single accepted contact', () async {
      await sB.upsertContact(
        Contact(nodeId: a, status: ContactStatus.pendingOutgoing),
      );
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
      expect(
        await sB.loadMessages(a.hex),
        isEmpty,
        reason: 'an empty re-intro greeting stores no message',
      );
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
      // These tests are about the durable RE-DRIVE of edit / delete / clear,
      // not about whose request counts. The default now ASKS before letting
      // anybody clear, so a test riding it would be asserting the policy
      // rather than the re-drive it was written for.
      await sB.upsertContact(
        (await sB.getContact(a))!.copyWith(
          clearPolicy: ClearRequestPolicy.anyone,
        ),
      );
    });

    /// One delivered message from A so there is something to edit/delete/clear.
    Future<String> seed(String body) async {
      await mA.sendText(b, body);
      await _settle();
      return (await sA.loadMessages(
        b.hex,
      )).firstWhere((m) => m.body == body).id;
    }

    test('EDIT lost on first attempt is re-driven, applied once, and the ack '
        'retires it', () async {
      final id = await seed('meet at noon');
      tA.online = false; // the lossy first attempt eats the edit
      await mA.editOwnMessage(id, 'meet at ONE');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).single.body,
        'meet at noon',
        reason: 'nothing reached B yet',
      );
      expect((await sA.pendingOutboxFrames()).length, 1);

      tA.online = true;
      clock = clock.add(
        const Duration(seconds: 21),
      ); // past the re-drive backoff
      await flushA();

      final onB = (await sB.loadMessages(a.hex)).single;
      expect(onB.body, 'meet at ONE');
      expect(onB.edited, isTrue);
      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason: "B's ack retired the frame",
      );
    });

    test('a peer that keeps talking does not turn the re-drive ladder off '
        'while its acks go astray', () async {
      final id = await seed('draft');
      tB.online = false; // B receives, but every ack it sends is lost
      var edits = 0;
      final sub = tB.messages().listen((m) {
        try {
          if (WireEnvelope.decode(m.payload).kind == WireKind.edit) edits++;
        } catch (_) {}
      });
      addTearDown(sub.cancel);
      await mA.editOwnMessage(id, 'final text');
      await _settle();
      expect(edits, 1);

      // B is plainly alive: something of its reaches A every 11 seconds, past
      // the flat ten-second grace every time. Before, each one rewound the
      // unacked edit and it went again on every step — eight copies here.
      for (var step = 0; step < 8; step++) {
        clock = clock.add(const Duration(seconds: 11));
        tA.inject(
          b,
          WireEnvelope.callSignal(
            const CallSignal(callId: 'beat', type: CallSignalType.health)
                .encode(),
          ).encode(),
        );
        await _settle();
        await flushA();
      }
      expect(
        edits - 1,
        inInclusiveRange(1, 4),
        reason: 'still re-driven (the durable guarantee), but on a growing '
            'spacing rather than every time the peer speaks',
      );
      expect((await sB.loadMessageHistory(a.hex, id)).length, 2);
    });

    test('a peer that went away gets one probe at a time, and its whole '
        'queue again the moment it is back', () async {
      // B is GONE: A's sends leave but reach nobody, and B says nothing — its
      // own timers would otherwise speak for it, which is exactly the signal
      // that must end a silence.
      tA.peer = null;
      tB.online = false;
      for (var i = 0; i < 30; i++) {
        await mA.sendDurable(b, 'test:gone:$i', WireEnvelope.reconnect('$i'));
      }
      await _settle();

      int queued() =>
          tA.sentFrameIds.where((f) => f.startsWith('test:gone:')).length;
      Future<int> sendsOver(Duration span) async {
        final before = queued();
        final end = clock.add(span);
        while (clock.isBefore(end)) {
          clock = clock.add(const Duration(seconds: 30));
          await flushA();
        }
        return queued() - before;
      }

      // The first ten minutes are the ordinary ladder, untouched.
      final early = await sendsOver(const Duration(minutes: 11));
      expect(early, greaterThan(30), reason: 'vacuity: the ladder ran');

      // Then B has said nothing for ten minutes. Thirty frames at the ladder's
      // ten-minute ceiling would be about ninety sends in half an hour.
      final silent = await sendsOver(const Duration(minutes: 30));
      expect(
        silent,
        inInclusiveRange(10, 18),
        reason: 'one probe per two minutes to a silent peer, not one per '
            'frame per ladder step',
      );
      expect(
        (await sA.pendingOutboxFrames()).length,
        30,
        reason: 'nothing is dropped while the peer is away',
      );

      // B comes back and says anything at all: the whole queue goes at once,
      // is acked, and retires.
      tA.peer = tB;
      tB.online = true;
      tA.inject(
        b,
        WireEnvelope.callSignal(
          const CallSignal(callId: 'back', type: CallSignalType.health).encode(),
        ).encode(),
      );
      await _settle();
      for (var i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 3));
        await flushA();
      }
      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason: 'the first thing heard from the peer ends its silence',
      );
    });

    test('the probe interval grows with the silence', () {
      Duration at(Duration silence) =>
          MessagingService.silentProbeInterval(silence);
      expect(at(const Duration(minutes: 10)), const Duration(minutes: 2));
      expect(at(const Duration(minutes: 59)), const Duration(minutes: 2));
      expect(at(const Duration(hours: 1)), const Duration(minutes: 15));
      expect(at(const Duration(hours: 3)), const Duration(minutes: 30));
      expect(at(const Duration(hours: 23)), const Duration(minutes: 30));
      expect(at(const Duration(days: 1)), const Duration(hours: 2));
      expect(at(const Duration(days: 7)), const Duration(days: 1));
      expect(at(const Duration(days: 29)), const Duration(days: 1));
      expect(at(const Duration(days: 30)), const Duration(days: 7));
      expect(at(const Duration(days: 400)), const Duration(days: 7));
    });

    test('a long silence is probed on the long ladder, and a restart keeps '
        'both the silence and the cadence', () async {
      // B was heard during the handshake, then went away for good.
      tA.peer = null;
      tB.online = false;
      for (var i = 0; i < 5; i++) {
        await mA.sendDurable(b, 'test:far:$i', WireEnvelope.reconnect('$i'));
      }
      await _settle();
      int far() => tA.sentFrameIds.where((f) => f.startsWith('test:far:')).length;
      Future<int> sendsOver(
        MessagingService m,
        Duration span,
        Duration step,
      ) async {
        final before = far();
        final end = clock.add(span);
        while (clock.isBefore(end)) {
          clock = clock.add(step);
          await m.flushOutbox();
          await _settle();
        }
        return far() - before;
      }

      // The first silent minutes: the ordinary ladder, then two-minute probes.
      await sendsOver(mA, const Duration(minutes: 12), const Duration(seconds: 30));

      // Five hours on: the probe that wakes the ladder, then one per 30 min.
      clock = clock.add(const Duration(hours: 5));
      expect(await sendsOver(mA, const Duration(minutes: 1), const Duration(minutes: 1)), 1);
      expect(
        await sendsOver(mA, const Duration(minutes: 29), const Duration(minutes: 1)),
        0,
        reason: 'silent for five hours: the next probe is thirty minutes out',
      );
      expect(await sendsOver(mA, const Duration(minutes: 1), const Duration(minutes: 1)), 1);

      // A restart. The last probe was a minute ago and B was last heard five
      // hours before it; both are stored, so the new process neither starts
      // a fresh ten-minute ladder nor probes at once.
      await mA.dispose();
      final mA2 = MessagingService(tA, sA, now: () => clock)..start();
      addTearDown(mA2.dispose);
      await _settle();
      expect(
        await sendsOver(mA2, const Duration(minutes: 28), const Duration(minutes: 1)),
        0,
        reason: 'the restart must not reset the silence or the cadence',
      );
      expect(await sendsOver(mA2, const Duration(minutes: 2), const Duration(minutes: 1)), 1);

      // Eight days on: one probe a day.
      clock = clock.add(const Duration(days: 8));
      expect(await sendsOver(mA2, const Duration(hours: 1), const Duration(hours: 1)), 1);
      expect(
        await sendsOver(mA2, const Duration(hours: 22), const Duration(hours: 1)),
        0,
        reason: 'silent for over a week: one probe a day',
      );
      expect(await sendsOver(mA2, const Duration(hours: 2), const Duration(hours: 1)), 1);

      // Past a month: one probe a week.
      clock = clock.add(const Duration(days: 30));
      expect(await sendsOver(mA2, const Duration(hours: 1), const Duration(hours: 1)), 1);
      expect(
        await sendsOver(mA2, const Duration(days: 6), const Duration(hours: 6)),
        0,
        reason: 'silent for over a month: one probe a week',
      );
      expect(
        (await sA.pendingOutboxFrames()).length,
        5,
        reason: 'nothing is dropped for being away',
      );
      expect(
        await mA2.silentSince(b),
        isNotNull,
        reason: 'the devices screen reads the same silence',
      );
    });

    test('a device never heard is timed from its oldest waiting frame, so an '
        'upgrade does not start a long silence over', () async {
      final device = _id(0x2F);
      mA.isOwnDevice = (p) async => p == device;
      tA.peer = null;
      for (var i = 0; i < 3; i++) {
        await mA.sendDurable(device, 'test:old:$i', WireEnvelope.reconnect('$i'));
      }
      await _settle();
      // Frames are stamped by the wall clock; forty days later, a fresh
      // process that has nothing stored about this device.
      await mA.dispose();
      clock = DateTime.now().add(const Duration(days: 40));
      final mA2 = MessagingService(tA, sA, now: () => clock)
        ..isOwnDevice = (p) async => p == device;
      mA2.start();
      addTearDown(mA2.dispose);
      await _settle();
      int old() => tA.sentFrameIds.where((f) => f.startsWith('test:old:')).length;
      final before = old();
      for (var i = 0; i < 10; i++) {
        clock = clock.add(const Duration(minutes: 1));
        await mA2.flushOutbox();
        await _settle();
      }
      expect(
        old() - before,
        1,
        reason: 'forty days of silence: one probe, not the ten-minute ladder '
            'over every frame',
      );
      expect(
        suggestUnlinking(silentSince: await mA2.silentSince(device), now: clock),
        isTrue,
        reason: 'and the devices screen offers it for unlinking',
      );
    });

    test('a device its session proved is recorded as seen under its own id',
        () async {
      final device = _id(0x2E);
      expect(await mA.lastSeen(device), isNull);
      tA.injectFromDevice(
        b,
        device,
        WireEnvelope.callSignal(
          const CallSignal(callId: 'hi', type: CallSignalType.health).encode(),
        ).encode(),
      );
      await _settle();
      expect(
        await mA.lastSeen(device),
        clock,
        reason: 'siblings are listed by device id; recorded under the '
            'identity alone, a device that talks daily read as never seen',
      );
    });

    test('a device addressed by its own id ends its silence by speaking '
        'under its identity', () async {
      // One of the identity's devices, reached by device id — how my own
      // siblings are addressed — while its traffic arrives under the identity.
      final device = _id(0x2D);
      mA.isOwnDevice = (p) async => p == device;
      tA.peer = null;
      tB.online = false;
      for (var i = 0; i < 6; i++) {
        await mA.sendDurable(device, 'test:dev:$i', WireEnvelope.reconnect('$i'));
      }
      await _settle();
      int devFrames() =>
          tA.sentFrameIds.where((f) => f.startsWith('test:dev:')).length;
      final end = clock.add(const Duration(minutes: 25));
      while (clock.isBefore(end)) {
        clock = clock.add(const Duration(seconds: 30));
        await flushA();
      }
      final beforeBack = devFrames();

      // It speaks — under the IDENTITY, with its device named by the session.
      tA.injectFromDevice(
        b,
        device,
        WireEnvelope.callSignal(
          const CallSignal(callId: 'back', type: CallSignalType.health).encode(),
        ).encode(),
      );
      // No flush from the test: hearing the device must start one itself.
      await _settle();
      expect(
        devFrames() - beforeBack,
        6,
        reason: 'every frame owed to the device goes at once, not one probe '
            'per two minutes — it was heard, under its identity',
      );
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
      expect(
        (await sB.loadMessageHistory(a.hex, id)).length,
        2,
        reason:
            'original + ONE edit — the re-drive was deduped, not '
            're-applied',
      );

      tB.online = true;
      clock = clock.add(const Duration(seconds: 41)); // past the doubled step
      await flushA();
      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason: 'the healed ack path finally retired the frame',
      );
      expect((await sB.loadMessages(a.hex)).single.body, 'final text');
    });

    test('DELETE-for-everyone lost on first attempt is re-driven and purges '
        'the peer copy', () async {
      final id = await seed('remove me');
      tA.online = false;
      await mA.deleteForEveryone(id);
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).length,
        1,
        reason: 'the unsend never reached B',
      );

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sB.isMessageDeleted(a.hex, id), isTrue);
      expect(await sA.pendingOutboxFrames(), isEmpty);
    });

    test(
      'CLEAR lost on first attempt is re-driven and empties the peer copy',
      () async {
        await seed('history line');
        tA.online = false;
        await mA.clearConversation(b);
        await _settle();
        expect(
          (await sB.loadMessages(a.hex)),
          isNotEmpty,
          reason: 'the clear never reached B',
        );

        tA.online = true;
        clock = clock.add(const Duration(seconds: 21));
        await flushA();

        expect(await sB.loadMessages(a.hex), isEmpty);
        expect(await sA.pendingOutboxFrames(), isEmpty);
      },
    );

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
      // The third party runs the same explicit policy as B — this test is
      // about A's own outbox ids colliding, not about whose clear counts.
      await sC.upsertContact(
        (await sC.getContact(a))!.copyWith(
          clearPolicy: ClearRequestPolicy.anyone,
        ),
      );

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
      final clearIds = pending
          .map((f) => f.frameId)
          .where((x) => x.startsWith('clear:'));
      expect(
        clearIds.length,
        2,
        reason:
            'both clears must be enqueued — a seq-only id would have '
            'collapsed them to one',
      );

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
      expect(
        (await sC.getContact(a))!.status,
        ContactStatus.pendingOutgoing,
        reason: 'the accept never reached C',
      );
      expect(
        (await sA.pendingOutboxFrames()).map((f) => f.frameId),
        contains('accept:${c.hex}'),
      );

      tA.online = true;
      clock = clock.add(const Duration(seconds: 21));
      await flushA();

      expect(
        (await sC.getContact(a))!.status,
        ContactStatus.accepted,
        reason: 'the re-driven accept completed the handshake',
      );
      expect(
        (await sA.pendingOutboxFrames()).map((f) => f.frameId),
        isNot(contains('accept:${c.hex}')),
        reason: "C's ack (sent from the accept arm) retired the frame",
      );
    });

    test(
      'an ACK that beats the durable write does not leave a pending frame',
      () async {
        // `startLiveBeforeEnqueue` sends before persisting on purpose: call
        // control must not queue behind a slow encrypted store. That opens a
        // window — an ACK arriving inside it retires a frame whose row does not
        // exist yet, finds nothing to delete, and then the enqueue creates a row
        // for a frame the peer has already confirmed. Nothing retires it again,
        // so it re-drives every outbox cycle for the life of the session
        // (audit XV-19).
        //
        // Its own service pair, because the whole point is a storage whose write
        // loses the race to the peer's ACK.
        final slowA = _SlowEnqueueStorage(_memOpener());
        await slowA.open(password: 'slow-a', createIfMissing: true);
        final tSlowA = _Link(a);
        final tSlowB = _Link(b);
        tSlowA.peer = tSlowB;
        tSlowB.peer = tSlowA;
        final sSlowB = HiddenVolumeStorage(_memOpener());
        await sSlowB.open(password: 'slow-b', createIfMissing: true);
        final mSlowA = MessagingService(tSlowA, slowA, now: () => clock)
          ..start();
        final mSlowB = MessagingService(tSlowB, sSlowB, now: () => clock)
          ..start();
        addTearDown(mSlowA.dispose);
        addTearDown(mSlowB.dispose);
        await mSlowA.sendRequest(b, '');
        await _settle();
        await mSlowB.acceptContact(a);
        await _settle();

        // From here the enqueue takes long enough for B's ACK to get in first.
        slowA.delayEnqueue = true;
        await mSlowA.sendCallSignal(
          b,
          const CallSignal(callId: 'race', type: CallSignalType.offer),
        );
        await _settle();
        await _settle();

        expect(
          await slowA.pendingOutboxFrames(),
          isEmpty,
          reason:
              'a frame the peer already confirmed must not stay pending — '
              'nothing would ever retire it again',
        );
      },
    );

    /// One signal, two destinations, two obligations.
    ///
    /// The durable outbox keys a row by frame id ALONE —
    /// `enqueueOutboxFrame` returns early on `_outboxById.containsKey(frameId)`
    /// — and the call fan-out built its id from the call and the signal type
    /// with no destination in it. So the first recipient took the only row and
    /// every other one silently got nothing durable, left with a live leg that
    /// is sent `awaitLive: false` and is nothing at all to a peer that is
    /// offline: exactly the peer a durable control frame exists for. The
    /// fan-out addresses sibling DEVICES too, so this is the ordinary
    /// multi-device case, not a large-group one.
    test(
      'a call fan-out owes each destination its own durable frame',
      () async {
        final c = _id(3);
        await sA.upsertContact(
          Contact(nodeId: c, status: ContactStatus.accepted),
        );
        tA.online = false;

        const signal = CallSignal(callId: 'fanout', type: CallSignalType.offer);
        await mA.sendCallSignal(b, signal);
        await mA.sendCallSignal(c, signal);
        await _settle();

        final pending = await sA.pendingOutboxFrames();
        expect(
          pending.length,
          2,
          reason: 'each destination is owed the signal, not just the first',
        );
        expect(
          pending.map((f) => f.peerHex).toSet(),
          {b.hex, c.hex},
          reason: 'and the two rows are for the two different peers',
        );
      },
    );

    /// A restart must not empty the queue in one burst.
    ///
    /// The ladder that spaces re-drives lives in RAM, so after a restart every
    /// queued frame is due at the same instant and the flush dialled all of
    /// them back to back — serial, but serial is not bounded. A backlog of a
    /// few hundred is ordinary for a device that was away, and this is the
    /// shape the outbox was already measured producing: bursts of about 175
    /// sends a second, each one a radio wake and a lookup.
    test('a restart drains the queue over passes, not in one burst', () async {
      tA.online = false;
      for (var i = 0; i < 40; i++) {
        await mA.sendCallSignal(
          b,
          CallSignal(callId: 'burst-$i', type: CallSignalType.offer),
        );
      }
      await _settle();
      expect((await sA.pendingOutboxFrames()).length, 40);

      // The restart: a fresh service over the same storage, so the in-memory
      // ladder is empty and every one of the 40 is due at once.
      await mA.dispose();
      final mA2 = MessagingService(tA, sA, now: () => clock)..start();
      addTearDown(mA2.dispose);
      await _settle();

      tA.online = true;
      tA.sent = 0;
      await mA2.flushOutbox();
      await _settle();

      expect(
        tA.sent,
        greaterThan(0),
        reason: 'a ceiling is not a stall — the pass must make progress',
      );
      // Measured on this very fixture: without the ceiling one pass puts 41
      // frames on the wire — the whole backlog — and leaves the second pass
      // with nothing to do. With it, 17.
      expect(
        tA.sent,
        lessThan(40),
        reason: 'one pass dials a slice, not the whole backlog',
      );

      // And the rest is not stranded: the next pass takes the next slice.
      final afterFirst = (await sA.pendingOutboxFrames()).length;
      expect(afterFirst, lessThan(40), reason: 'the first slice went out');
      clock = clock.add(const Duration(seconds: 21));
      tA.sent = 0;
      await mA2.flushOutbox();
      await _settle();
      expect(tA.sent, greaterThan(0), reason: 'the queue keeps draining');
    });

    test(
      'call health heartbeat is live-only and never enters durable outbox',
      () async {
        tA.online = false;
        await mA.sendCallSignal(
          b,
          const CallSignal(callId: 'call-live', type: CallSignalType.health),
        );
        await _settle();

        expect(
          await sA.pendingOutboxFrames(),
          isEmpty,
          reason:
              'liveness beats are superseded by the next beat and must not '
              'survive as restart/outbox work',
        );
      },
    );

    test(
      'non-contact group-call lifecycle re-drives by membership and dispatches',
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
      },
    );

    test(
      'stale group-call lifecycle retires before a non-contact re-drive',
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
      },
    );

    test(
      'non-contact group content request re-drives by membership then expires',
      () async {
        await sA.removeConversation(b);
        await sB.removeConversation(a);
        final gid = _id(8);
        mA.allowStrangerGroupSync = (peer, groupIdHex) async =>
            peer == b && groupIdHex == gid.hex;
        String? received;
        mB.onGroupContentRequest = (peer, requestJson) {
          if (peer == a) received = requestJson;
        };
        final request = GroupContentRequest(
          groupId: gid,
          contentId: 'c0ffee',
          requester: a,
          nonce: '00112233445566778899aabb',
          tsMs: clock.millisecondsSinceEpoch,
          signature: Uint8List(64),
          authorPubKey: Uint8List(32),
        );
        final json = jsonEncode(request.toJson());

        tA.online = false;
        await mA.sendGroupContentRequest(b, json);
        await _settle();
        expect(received, isNull);
        expect(
          (await sA.pendingOutboxFrames()).single.frameId,
          'gcr:${gid.hex}:c0ffee:00112233445566778899aabb:${b.hex}',
          reason:
              'the destination belongs in the id — the durable outbox is '
              'keyed by frameId, so one id shared across holders meant only the '
              'first holder\'s request was ever persisted (audit XV-02)',
        );

        tA.online = true;
        clock = clock.add(const Duration(seconds: 21));
        await flushA();
        expect(received, json);
        expect(
          await sA.pendingOutboxFrames(),
          hasLength(1),
          reason: 'a non-contact gets no ACK oracle',
        );

        clock = clock.add(
          kGroupContentRequestWindow + const Duration(seconds: 1),
        );
        await flushA();
        expect(await sA.pendingOutboxFrames(), isEmpty);
      },
    );

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

    test(
      'stale durable call offer is retired instead of re-driven forever',
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
          // Destination-bound: one signal fanned out owes each recipient its
          // own row, and the outbox keys rows by frame id alone.
          contains('call:call-stale:offer:${b.hex}'),
        );

        tA.online = true;
        clock = clock.add(const Duration(minutes: 3));
        await flushA();

        expect(
          await sA.pendingOutboxFrames(),
          isEmpty,
          reason: 'a missed real-time call is no longer useful minutes later',
        );
        expect(
          await sB.pendingOutboxFrames(),
          isEmpty,
          reason: 'the stale offer was not delivered to B',
        );
      },
    );

    test('peer inbound within the nudge grace does not duplicate a just-sent '
        'call frame; the backoff re-drive still heals a lost ack', () async {
      tB.online = false; // B receives, but every ack it sends is lost
      var offers = 0;
      final sub = tB.messages().listen((m) {
        try {
          if (WireEnvelope.decode(m.payload).frameId ==
              'call:dup:offer:${b.hex}') {
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
          const CallSignal(callId: 'dup', type: CallSignalType.health).encode(),
        ).encode(),
      );
      await _settle();
      expect(
        offers,
        1,
        reason: 'inbound during the grace must not duplicate the send',
      );

      // The ack really was lost → the fast call ladder and/or the regular
      // backoff re-drive still fire. Both copies carry the same frame id and
      // are deduplicated at the receiver.
      clock = clock.add(const Duration(seconds: 21));
      await flushA();
      expect(
        offers,
        greaterThanOrEqualTo(2),
        reason: 'the durable guarantee is untouched',
      );
    });

    test(
      'RECONNECT to a wiped peer is durable: re-intro survives the lost '
      'first attempt, and accepting heals the conversation end-to-end',
      () async {
        // B wipes A completely (Case-A): A's plain messages now hit B's consent
        // gate and drop.
        await sB.removeConversation(a);
        await mA.sendText(b, 'anyone home?');
        await _settle();
        expect(
          await sB.getContact(a),
          isNull,
          reason: 'message dropped at gate',
        );

        // First reconnect attempt fires past the threshold — but the live path
        // eats it (A offline at that moment).
        tA.online = false;
        clock = clock.add(const Duration(minutes: 3));
        await flushA();
        expect(
          (await sA.pendingOutboxFrames()).map((f) => f.frameId),
          contains('reconnect:${b.hex}'),
        );
        expect(await sB.getContact(a), isNull);

        // The durable pipeline re-drives it once the egress heals — no need to
        // wait out the 15-min reconnect ladder.
        tA.online = true;
        clock = clock.add(const Duration(seconds: 21));
        await flushA();
        expect(
          (await sB.getContact(a))!.status,
          ContactStatus.pendingIncoming,
          reason: 're-driven re-intro surfaced on the wiped peer',
        );

        // B re-accepts → the stuck message flows → everything retires.
        await mB.acceptContact(a);
        await _settle();
        clock = clock.add(const Duration(seconds: 41));
        await flushA();
        await mB.flushOutbox();
        await _settle();
        clock = clock.add(
          const Duration(minutes: 11),
        ); // past any frame backoff
        await flushA();
        await mB.flushOutbox();
        await _settle();

        expect(
          (await sB.loadMessages(a.hex)).map((m) => m.body),
          contains('anyone home?'),
          reason: 'the conversation healed after re-accept',
        );
        expect(
          await sA.pendingOutboxFrames(),
          isEmpty,
          reason: "B now acks A's durable frames — reconnect retired",
        );
        expect(
          await sB.pendingOutboxFrames(),
          isEmpty,
          reason: "A acked B's accept — nothing left pending",
        );
      },
    );

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

      expect(
        (await sA.loadMessages(b.hex)).single.status,
        MessageStatus.failed,
      );
      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason:
            'the reconnect frame did not outlive the messages it '
            'was reviving',
      );
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

      expect(
        (await sB.loadMessages(a.hex)).single.body,
        'edited before restart',
      );
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

      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason: 'moot frame dropped with its conversation',
      );
      expect(
        (await sB.loadMessages(a.hex)).single.body,
        'temp',
        reason: 'nothing was delivered — the frame was retired locally',
      );
    });
  });

  // ── Editing must not pay for a container-wide vacuum (audit report6 XV-06) ──
  //
  // An edit APPENDS a new row; the superseded bodies are retained ON PURPOSE so
  // the edit history reads back, and they are reclaimed only by an explicit
  // clear-history or a panic erase. So there is never an orphaned chunk for a
  // vacuum to find after an edit — measured on a real container: ten edits,
  // zero chunks reclaimed each time; one delete frees exactly one. Running the
  // full sweep (and dropping the warm fold cache with it) on every edit was
  // pure cost, and a peer editing its own message could drive it at will.
  //
  // Deleting is different and KEEPS its scrub: that is where the plaintext must
  // actually leave the container.
  group('an edit does not vacuum the container, a delete still does', () {
    late NodeId a, b;
    late _Link tA, tB;
    late _ScrubCountingStorage sA, sB;
    late MessagingService mA, mB;

    setUp(() async {
      a = _id(1);
      b = _id(2);
      tA = _Link(a);
      tB = _Link(b);
      tA.peer = tB;
      tB.peer = tA;
      sA = _ScrubCountingStorage(_memOpener());
      sB = _ScrubCountingStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      mA = MessagingService(tA, sA)..start();
      mB = MessagingService(tB, sB)..start();
      addTearDown(mA.dispose);
      addTearDown(mB.dispose);
      await sA.upsertContact(
        Contact(
          nodeId: b,
          status: ContactStatus.accepted,
          clearPolicy: ClearRequestPolicy.anyone,
        ),
      );
      await sB.upsertContact(
        // About the re-drive, not the policy — see the note above.
        Contact(
          nodeId: a,
          status: ContactStatus.accepted,
          clearPolicy: ClearRequestPolicy.anyone,
        ),
      );
    });

    test(
      "an accepted peer's edits cost B no vacuum at all, its unsend does",
      () async {
        tB.inject(
          a,
          WireEnvelope.message(
            'original',
            id: 'm1',
            sentAtMs: 1000,
            seq: 1,
          ).encode(),
        );
        await _settle();
        sB.scrubs = 0;

        for (var i = 2; i < 12; i++) {
          tB.inject(a, WireEnvelope.edit('m1', 'edit $i', seq: i).encode());
          await _settle();
        }
        expect(
          (await sB.loadMessages(a.hex)).single.body,
          'edit 11',
          reason: 'the edits really landed — this is not a no-op path',
        );
        expect(
          sB.scrubs,
          0,
          reason:
              'ten remote edits, ten sweeps of the whole container, and '
              'nothing to reclaim in any of them',
        );

        // Control: the destructive twin still scrubs, on the very same storage.
        tB.inject(a, const WireEnvelope.del('m1').encode());
        await _settle();
        expect(await sB.loadMessages(a.hex), isEmpty);
        expect(
          sB.scrubs,
          greaterThan(0),
          reason: 'an unsend must still reclaim the plaintext',
        );
      },
    );

    test('editing OUR OWN message costs no vacuum, deleting it does', () async {
      await mA.sendText(b, 'first draft');
      await _settle();
      final id = (await sA.loadMessages(b.hex)).single.id;
      sA.scrubs = 0;

      await mA.editOwnMessage(id, 'second draft');
      await mA.editOwnMessage(id, 'third draft');
      await _settle();
      expect((await sA.loadMessages(b.hex)).single.body, 'third draft');
      expect(sA.scrubs, 0);

      // Control: the local delete on the same message does scrub.
      await mA.deleteMessageLocally(id);
      await _settle();
      expect(sA.scrubs, greaterThan(0));
    });

    test('the retained edit history still reads back — dropping the vacuum '
        'reclaimed nothing, so it hid nothing either', () async {
      tB.inject(
        a,
        WireEnvelope.message(
          'original',
          id: 'm1',
          sentAtMs: 1000,
          seq: 1,
        ).encode(),
      );
      await _settle();
      tB.inject(a, WireEnvelope.edit('m1', 'once', seq: 2).encode());
      await _settle();
      tB.inject(a, WireEnvelope.edit('m1', 'twice', seq: 3).encode());
      await _settle();

      final history = await sB.loadMessageHistory(a.hex, 'm1');
      expect(
        history.map((v) => v.body).toList(),
        ['original', 'once', 'twice'],
        reason:
            'every superseded body is still there — exactly as it was '
            'when the edit path scrubbed, since the scrub never freed one',
      );

      // And the explicit destructive path still takes them away.
      tB.inject(a, const WireEnvelope.del('m1').encode());
      await _settle();
      expect(await sB.loadMessageHistory(a.hex, 'm1'), isEmpty);
    });
  });
}

/// Counts how many container-wide vacuums a flow pays for.
class _ScrubCountingStorage extends HiddenVolumeStorage {
  _ScrubCountingStorage(super.opener);

  int scrubs = 0;

  @override
  Future<void> scrubDeleted() {
    scrubs++;
    return super.scrubDeleted();
  }
}

/// Makes the durable write lose the race to the peer's ACK.
///
/// The XV-19 window is real but narrow — an encrypted store that happens to be
/// slower than a round trip. Widening it deliberately is the only way to test
/// the ordering rather than the machine it runs on.
class _SlowEnqueueStorage extends HiddenVolumeStorage {
  _SlowEnqueueStorage(super.opener);

  bool delayEnqueue = false;

  @override
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) async {
    if (delayEnqueue) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return super.enqueueOutboxFrame(frameId, peerHex, wire);
  }
}
