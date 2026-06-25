import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A transport whose live send goes NOWHERE — models two NAT'd nodes that
/// cannot reach each other directly, so the ONLY delivery path is the mailbox.
class _BlackholeTransport implements VeilTransport {
  _BlackholeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();

  /// Push an inbound frame as if it arrived over the wire (the live path goes
  /// nowhere, so this is how a test simulates receiving from a NAT'd peer).
  void inject(InboundMessage m) => _inbound.add(m);

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
      {bool anonymous = false}) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// Records every stash so we can assert the offline-deposit path fired.
class _RecordingSink implements MailboxSink {
  final stashed = <(NodeId, Uint8List)>[];
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async {
    stashed.add((recipient, payload));
  }
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  late NodeId a, b;
  late HiddenVolumeStorage sA;
  late MessagingService mA;
  late _BlackholeTransport tA;
  late _RecordingSink sink;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    tA = _BlackholeTransport(a);
    mA = MessagingService(tA, sA)..start();
    sink = _RecordingSink();
    mA.attachMailbox(sink);
  });

  test('a connection request is deposited at the recipient mailbox', () async {
    await mA.sendRequest(b, 'hi, it is me');
    expect(sink.stashed.length, 1);
    final (recipient, payload) = sink.stashed.single;
    expect(recipient, b);
    final env = WireEnvelope.decode(payload);
    expect(env.kind, WireKind.request);
    expect(env.body, 'hi, it is me');
  });

  test('an accept is deposited at the requester mailbox', () async {
    // Simulate an inbound request from b so a has a pendingIncoming contact.
    await mA.acceptContact(b);
    expect(sink.stashed.any((s) {
      final env = WireEnvelope.decode(s.$2);
      return s.$1 == b && env.kind == WireKind.accept;
    }), isTrue);
  });

  test('a free message to an accepted contact is deposited immediately',
      () async {
    await mA.acceptContact(b); // marks b accepted on a's side
    sink.stashed.clear();
    await mA.sendText(b, 'first real message');
    expect(sink.stashed.any((s) {
      final env = WireEnvelope.decode(s.$2);
      return s.$1 == b &&
          env.kind == WireKind.message &&
          env.body == 'first real message';
    }), isTrue);
  });

  test('a durable ACK is deposited at the sender mailbox so a NAT-d sender '
      'stops re-sending', () async {
    await mA.acceptContact(b); // b accepted on a's side
    sink.stashed.clear();
    // b's message arrives with no live reply path (replyId 0) — exactly the
    // NAT'd case where a live-send ack can't get back. a must ACK durably AND
    // deposit it at b's mailbox so the ack reaches b over the rendezvous push,
    // flipping b's message to delivered and ending the re-send storm.
    final wire = WireEnvelope.message('ping',
            id: 'm1', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: wire));
    await pumpEventQueue();
    expect(
      sink.stashed.any((s) {
        final env = WireEnvelope.decode(s.$2);
        return s.$1 == b && env.kind == WireKind.ack && env.id == 'm1';
      }),
      isTrue,
      reason: 'durable ack for m1 should be deposited at b\'s mailbox',
    );
  });

  test('a fast-path (reply-circuit) ACK is NOT deposited — no needless traffic',
      () async {
    await mA.acceptContact(b);
    sink.stashed.clear();
    // A first receipt that carries a live reply path (replyId != 0) acks over
    // that circuit; depositing would be wasted relay traffic. Only the durable
    // path (re-receipt / no reply path) deposits.
    final wire = WireEnvelope.message('ping',
            id: 'm2', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: wire, replyId: 42));
    await pumpEventQueue();
    expect(
      sink.stashed.any((s) => WireEnvelope.decode(s.$2).kind == WireKind.ack),
      isFalse,
      reason: 'an ack sent over a live reply circuit must not also be stashed',
    );
  });

  test('concurrent pre-consent intros cannot race past the cap', () async {
    // A hostile peer mints a FRESH id per request and fires many AT ONCE. The
    // inbound handler is async and the stream does not await it, so without
    // serialization the per-request capPreConsentIntros (read count -> evict ->
    // store) interleaves: every concurrent frame reads the count below the cap
    // and stores, busting kMaxPreConsentIntros. Fire 40 without awaiting between
    // them, then drain — the stored intros from this unaccepted peer must never
    // exceed the cap.
    const burst = 40;
    final futures = <Future<void>>[];
    for (var i = 0; i < burst; i++) {
      final wire = WireEnvelope.request('greeting #$i', id: 'req-$i').encode();
      futures.add(mA.deliverInbound(InboundMessage(src: b, payload: wire)));
    }
    await Future.wait(futures);
    await pumpEventQueue();

    final stored = await sA.loadMessages(b.hex);
    expect(stored.length, lessThanOrEqualTo(kMaxPreConsentIntros),
        reason: 'serialized handling must hold the pre-consent cap under a '
            'concurrent burst (got ${stored.length})');
  });
}
