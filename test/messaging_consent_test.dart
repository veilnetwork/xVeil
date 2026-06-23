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

/// Direct 1:1 fake link: send() delivers to the peer's inbound, tagged with
/// our node id as the source.
class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

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

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
  });

  test('request -> accept -> message; gating blocks pre-accept and strangers',
      () async {
    // A requests B with a greeting.
    await mA.sendRequest(b, 'hi, can we connect?');
    await _pump();
    expect((await sA.getContact(b))!.status, ContactStatus.pendingOutgoing);
    expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming);
    expect((await sB.loadMessages(a.hex)).single.body, 'hi, can we connect?');

    // A cannot free-message before B accepts.
    await mA.sendText(b, 'let me in');
    await _pump();
    expect((await sB.loadMessages(a.hex)).length, 1); // greeting only

    // B accepts -> both accepted.
    await mB.acceptContact(a);
    await _pump();
    expect((await sB.getContact(a))!.status, ContactStatus.accepted);
    expect((await sA.getContact(b))!.status, ContactStatus.accepted);

    // Now free messaging works both ways.
    await mA.sendText(b, 'hello');
    await _pump();
    expect((await sB.loadMessages(a.hex)).map((m) => m.body), contains('hello'));
  });

  test('a plain message from a stranger is dropped (no auto-add)', () async {
    // B never requested/accepted A; A sends a raw message.
    await mA.sendText(b, 'spam'); // gated on A's side anyway (no contact)
    // Force a bare message even without a contact:
    await tA.send(b, const WireEnvelopeMessage('hi stranger').bytes);
    await _pump();
    expect(await sB.getContact(a), isNull);
    expect(await sB.loadMessages(a.hex), isEmpty);
  });

  test('blocking drops subsequent messages', () async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    await mB.blockContact(a);
    await mA.sendText(b, 'after block');
    await _pump();
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'after block'),
        isFalse);
  });

  test('pre-consent intro spam is capped, keeping the most recent', () async {
    // A hostile peer mints a FRESH id per request so the dedup-by-id path does
    // not collapse them. Without the cap these pile up unbounded before B ever
    // accepts; with it, B holds at most kMaxPreConsentIntros (the most recent).
    const total = kMaxPreConsentIntros + 4;
    for (var i = 0; i < total; i++) {
      // distinct ids => not an overwrite; the _pump spaces timestamps by ms so
      // eviction order (oldest-first) is deterministic.
      await tA.send(b, WireEnvelope.request('intro $i', id: 'req-$i').encode());
      await _pump();
    }

    final msgs = await sB.loadMessages(a.hex);
    expect(msgs.length, kMaxPreConsentIntros,
        reason: 'pre-consent intros must be bounded to the cap');
    final bodies = msgs.map((m) => m.body).toSet();
    for (var i = 0; i < total; i++) {
      final survived = i >= total - kMaxPreConsentIntros; // most recent N kept
      expect(bodies.contains('intro $i'), survived,
          reason: 'intro $i ${survived ? "must survive" : "must be evicted"}');
    }
    // The peer is still pending — the cap is anti-spam, not a consent change.
    expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming);
  });

  test('a same-id re-request overwrites in place and does not consume the cap',
      () async {
    // Re-sending the SAME request id (e.g. an outbox retry) must overwrite, not
    // accumulate, and must never evict — so a legit single intro is preserved.
    for (var i = 0; i < 3; i++) {
      await tA.send(b, WireEnvelope.request('intro v$i', id: 'same').encode());
      await _pump();
    }
    final msgs = await sB.loadMessages(a.hex);
    expect(msgs.length, 1, reason: 'same id => one stored copy');
    expect(msgs.single.body, 'intro v2', reason: 'last write wins');
  });

  test('a re-request never evicts an accepted peer\'s real conversation',
      () async {
    // Guard: the cap counts incoming messages, which for an accepted peer
    // includes real chat. A later re-request must NOT evict that history.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    for (var i = 0; i < kMaxPreConsentIntros + 3; i++) {
      await mA.sendText(b, 'msg $i');
      await _pump();
    }
    final before = (await sB.loadMessages(a.hex)).length;
    expect(before, greaterThan(kMaxPreConsentIntros));

    // A reconnects and re-sends a request (some clients do on resume).
    await tA.send(b, WireEnvelope.request('re-hi', id: 'rereq').encode());
    await _pump();

    final after = await sB.loadMessages(a.hex);
    expect(after.length, greaterThanOrEqualTo(before),
        reason: 'an accepted peer\'s history is never evicted by a re-request');
    expect(after.any((m) => m.body == 'msg 0'), isTrue,
        reason: 'the oldest real message must survive');
  });
}

/// Tiny helper to craft a raw message payload in the stranger test.
class WireEnvelopeMessage {
  const WireEnvelopeMessage(this.text);
  final String text;
  Uint8List get bytes =>
      Uint8List.fromList('{"t":2,"b":"$text"}'.codeUnits);
}
