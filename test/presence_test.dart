import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'dart:convert';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Capture implements VeilTransport {
  _Capture(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  final sent = <(NodeId, WireKind, String)>[];

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    final env = WireEnvelope.decode(payload);
    sent.add((dst, env.kind, env.body));
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

Future<MessagingService> _service(
  _Capture t, [
  HiddenVolumeStorage? into,
  DateTime Function()? now,
]) async {
  final store = FakeKvLogStore();
  final storage = into ??
      HiddenVolumeStorage(({required password, required bool create}) => store);
  if (into == null) await storage.open(password: 'pw', createIfMissing: true);
  return MessagingService(t, storage, now: now)..start();
}

Future<HiddenVolumeStorage> _storage() async {
  final store = FakeKvLogStore();
  final s = HiddenVolumeStorage(
    ({required password, required bool create}) => store,
  );
  await s.open(password: 'pw', createIfMissing: true);
  return s;
}

Future<void> _hold(
  HiddenVolumeStorage s,
  NodeId peer,
  String id, {
  DateTime? at,
}) async {
  await s.upsertContact(Contact(nodeId: peer, status: ContactStatus.accepted));
  await s.appendMessage(
    Message(
      id: id,
      conversationId: peer.hex,
      direction: MessageDirection.incoming,
      body: 'text of $id',
      timestamp: at ?? DateTime.now(),
      status: MessageStatus.delivered,
    ),
  );
}

void main() {
  // A device away for over a day no longer gets new frames dialled live; the
  // owner's decision (2026-09-27) is that a device coming online says so to
  // its siblings, and they react — so it is not left waiting for a probe.
  final identity = _id(0x90);
  final sibling = _id(0x92);

  test('a device that comes online tells my other devices', () async {
    final t = _Capture(_id(0x91));
    final m = await _service(t);
    addTearDown(m.dispose);
    m.myOtherDevices = () async => [sibling];

    await m.reconcileOnConnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      t.sent.where((e) => e.$2 == WireKind.presence).map((e) => e.$1),
      [sibling],
    );
  });

  test('a sibling that hears it answers once, at the device, not forever',
      () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => p == identity || p == _id(0x91);
    final device = _id(0x91);
    m.myOtherDevices = () async => [device];

    await m.deliverInbound(
      InboundMessage(
        src: identity,
        srcDevice: device,
        payload: WireEnvelope.presence(device.hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await m.deliverInbound(
      InboundMessage(
        src: identity,
        srcDevice: device,
        payload: WireEnvelope.presence(device.hex, reply: true).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final answers = [
      for (final e in t.sent)
        if (e.$2 == WireKind.presence) e,
    ];
    expect(answers, hasLength(1), reason: 'an answer was answered again');
    expect(answers.single.$1, device);
    expect(answers.single.$3, '${sibling.hex}|r');
  });

  test('a stranger saying it is online gets no answer', () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => false;
    await m.deliverInbound(
      InboundMessage(
        src: _id(0x55),
        srcDevice: _id(0x56),
        payload: WireEnvelope.presence(_id(0x56).hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(t.sent.where((e) => e.$2 == WireKind.presence), isEmpty);
  });

  test('named only in the body (a relayed frame), the device is still '
      'answered', () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    final device = _id(0x91);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => p == identity || p == device;
    m.myOtherDevices = () async => [device];
    await m.deliverInbound(
      InboundMessage(
        src: identity,
        payload: WireEnvelope.presence(device.hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      [for (final e in t.sent) if (e.$2 == WireKind.presence) e.$1],
      [device],
      reason: 'a relayed presence was not traced to its device',
    );
  });

  group('erasures are compared between my devices', () {
    // An erase reaches my other devices as a device-log event, and one lost
    // there left the message deleted on one device and shown on the other
    // for good. Owner's decision (2026-09-27): reconcile between OWN devices,
    // never on the counterpart's word.
    final peer = _id(0x44);
    final me = _id(0x91);

    test('each pass checks the newest page and advances through old pages', () {
      expect(erasureComparisonPages(round: 1, pages: 1), [0]);
      expect(
        [
          for (var round = 1; round <= 4; round++)
            erasureComparisonPages(round: round, pages: 4),
        ],
        [
          [0, 1],
          [0, 2],
          [0, 3],
          [0, 1],
        ],
      );
    });

    test('a sibling answers with what it erased of what I still show, and I '
        'erase it too', () async {
      // The sibling: erased 'gone', still holds 'kept'.
      final sibStore = await _storage();
      await _hold(sibStore, peer, 'gone');
      await _hold(sibStore, peer, 'kept');
      await sibStore.deleteMessage(peer.hex, 'gone');
      final sibT = _Capture(sibling);
      final sib = await _service(sibT, sibStore);
      addTearDown(sib.dispose);
      sib.selfIdentityHex = () async => identity.hex;
      sib.isOwnDevice = (p) async => p == identity || p == me;
      sib.myOtherDevices = () async => [me];

      // This device: holds both.
      final myStore = await _storage();
      await _hold(myStore, peer, 'gone');
      await _hold(myStore, peer, 'kept');
      final myT = _Capture(me);
      final mine = await _service(myT, myStore);
      addTearDown(mine.dispose);
      mine.selfIdentityHex = () async => identity.hex;
      mine.isOwnDevice = (p) async => p == identity || p == sibling;
      mine.myOtherDevices = () async => [sibling];

      Future<void> carry(_Capture from, MessagingService to, NodeId dev) async {
        final frames = [
          for (final e in from.sent)
            if (e.$2 == WireKind.deviceGone) e.$3,
        ];
        from.sent.clear();
        for (final body in frames) {
          await to.deliverInbound(
            InboundMessage(
              src: identity,
              srcDevice: dev,
              payload: WireEnvelope.deviceGone(body).encode(),
              provenance: SenderProvenance.signed,
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // The sibling says it is online; this device answers and compares.
      await mine.deliverInbound(
        InboundMessage(
          src: identity,
          srcDevice: sibling,
          payload: WireEnvelope.presence(sibling.hex).encode(),
          provenance: SenderProvenance.signed,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(myT.sent.where((e) => e.$2 == WireKind.deviceGone), isNotEmpty,
          reason: 'premise: the comparison was asked for');
      await carry(myT, sib, me);
      await carry(sibT, mine, sibling);

      expect(await myStore.loadMessageById(peer.hex, 'gone'), isNull,
          reason: 'erased on the sibling, still shown here');
      expect(await myStore.loadMessageById(peer.hex, 'kept'), isNotNull,
          reason: 'what the sibling kept must stay');
    });

    test('an erase older than the newest page is caught up too', () async {
      // The measured cases on the stand sat deep enough that a new session's
      // first comparison could not reach them.
      var clock = DateTime.now();
      final base = clock.subtract(const Duration(days: 1));
      final sibStore = await _storage();
      await _hold(sibStore, peer, 'm0', at: base);
      await sibStore.deleteMessage(peer.hex, 'm0');
      final sibT = _Capture(sibling);
      final sib = await _service(sibT, sibStore);
      addTearDown(sib.dispose);
      sib.selfIdentityHex = () async => identity.hex;
      sib.isOwnDevice = (p) async => p == identity || p == me;
      sib.myOtherDevices = () async => [me];

      final myStore = await _storage();
      for (var i = 0; i < 401; i++) {
        await _hold(myStore, peer, 'm$i', at: base.add(Duration(seconds: i)));
      }
      final myT = _Capture(me);
      var mine = await _service(myT, myStore, () => clock);
      addTearDown(() => mine.dispose());
      mine.selfIdentityHex = () async => identity.hex;
      mine.isOwnDevice = (p) async => p == identity || p == sibling;
      mine.myOtherDevices = () async => [sibling];

      Future<void> carry(_Capture from, MessagingService to, NodeId dev) async {
        final frames = [
          for (final e in from.sent)
            if (e.$2 == WireKind.deviceGone) e.$3,
        ];
        from.sent.clear();
        for (final body in frames) {
          await to.deliverInbound(
            InboundMessage(
              src: identity,
              srcDevice: dev,
              payload: WireEnvelope.deviceGone(body).encode(),
              provenance: SenderProvenance.signed,
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      for (var round = 1; round <= 2; round++) {
        if (round == 2) {
          await mine.dispose();
          mine = await _service(myT, myStore, () => clock);
          mine.selfIdentityHex = () async => identity.hex;
          mine.isOwnDevice = (p) async => p == identity || p == sibling;
          mine.myOtherDevices = () async => [sibling];
        }
        clock = clock.add(const Duration(minutes: 11));
        await mine.deliverInbound(
          InboundMessage(
            src: identity,
            srcDevice: sibling,
            payload: WireEnvelope.presence(sibling.hex, reply: true).encode(),
            provenance: SenderProvenance.signed,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await carry(myT, sib, me);
        await carry(sibT, mine, sibling);
        if (round == 1) {
          expect(
            await myStore.loadMessageById(peer.hex, 'm0'),
            isNotNull,
            reason: 'the first older page does not reach this message',
          );
        }
      }
      expect(
        await myStore.loadMessageById(peer.hex, 'm0'),
        isNull,
        reason: 'an erase below the newest page was never compared',
      );
    });

    test('an answer nobody asked for erases nothing', () async {
      final myStore = await _storage();
      await _hold(myStore, peer, 'mine');
      final myT = _Capture(me);
      final mine = await _service(myT, myStore);
      addTearDown(mine.dispose);
      mine.selfIdentityHex = () async => identity.hex;
      mine.isOwnDevice = (p) async => p == identity || p == sibling;
      mine.myOtherDevices = () async => [sibling];
      await mine.deliverInbound(
        InboundMessage(
          src: identity,
          srcDevice: sibling,
          payload: WireEnvelope.deviceGone(
            jsonEncode({'d': sibling.hex, 'a': peer.hex, 'ids': ['mine']}),
          ).encode(),
          provenance: SenderProvenance.signed,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await myStore.loadMessageById(peer.hex, 'mine'), isNotNull);
    });
  });
}
