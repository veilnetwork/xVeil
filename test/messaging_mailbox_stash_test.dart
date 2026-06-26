import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart' show MessageStatus;
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

  test('a new incoming message emits on the incoming stream (notifications)',
      () async {
    await mA.acceptContact(b);
    final got = <IncomingNotice>[];
    final sub = mA.incoming.listen(got.add);
    final wire = WireEnvelope.message('hey there',
            id: 'n1', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: wire));
    await pumpEventQueue();
    await sub.cancel();
    expect(got.length, 1);
    expect(got.single.from, b);
    expect(got.single.preview, 'hey there');
    expect(got.single.isFile, isFalse);
  });

  test('a re-delivered (deduped) message does NOT re-emit', () async {
    await mA.acceptContact(b);
    final wire = WireEnvelope.message('once',
            id: 'n2', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: wire));
    await pumpEventQueue();
    // Now subscribe and re-inject the SAME id — dedup must suppress the emit.
    final got = <IncomingNotice>[];
    final sub = mA.incoming.listen(got.add);
    tA.inject(InboundMessage(src: b, payload: wire));
    await pumpEventQueue();
    await sub.cancel();
    expect(got, isEmpty, reason: 'a re-delivery must not re-notify');
  });

  test('an ACK from a non-accepted peer cannot flip our message status', () async {
    await mA.acceptContact(b);
    await mA.sendText(b, 'hello');
    await pumpEventQueue();
    final sent = (await sA.loadMessages(b.hex)).firstWhere((m) => m.body == 'hello');
    expect(sent.status, isNot(MessageStatus.delivered));

    // A stranger c (no contact, not accepted) acks our message id. The consent
    // gate must drop it — otherwise any peer could forge a delivered mark.
    final c = _id(9);
    final ack = WireEnvelope.ack(sent.id).encode();
    tA.inject(InboundMessage(src: c, payload: ack));
    await pumpEventQueue();
    expect(
        (await sA.loadMessages(b.hex)).firstWhere((m) => m.id == sent.id).status,
        isNot(MessageStatus.delivered),
        reason: 'an unaccepted peer must not flip our delivery state');

    // The real (accepted) peer b CAN ack it.
    tA.inject(InboundMessage(src: b, payload: ack));
    await pumpEventQueue();
    expect(
        (await sA.loadMessages(b.hex)).firstWhere((m) => m.id == sent.id).status,
        MessageStatus.delivered);
  });

  test('an edit that drains BEFORE its message still applies (out-of-order)',
      () async {
    await mA.acceptContact(b);
    // The peer sent a message then edited it while we were offline. On reconnect
    // the mailbox blobs drain in arbitrary order — here the EDIT arrives first.
    // Without buffering, the edit would be dropped (its target isn't stored yet)
    // and the offline edit would silently never land.
    final edit = WireEnvelope.edit('x1', 'corrected text').encode();
    tA.inject(InboundMessage(src: b, payload: edit));
    await pumpEventQueue();
    // Nothing to edit yet — the op is buffered, not applied, and no ghost shows.
    expect((await sA.loadMessages(b.hex)).where((m) => m.id == 'x1'), isEmpty);

    // Now the original message arrives — the buffered edit must apply.
    final msg = WireEnvelope.message('original text',
            id: 'x1', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: msg));
    await pumpEventQueue();
    final stored = (await sA.loadMessages(b.hex)).firstWhere((m) => m.id == 'x1');
    expect(stored.body, 'corrected text',
        reason: 'the buffered edit must apply once its target message arrives');
  });

  test('a delete that drains BEFORE its message tombstones it (no resurrect)',
      () async {
    await mA.acceptContact(b);
    // The peer unsent a message while we were offline; its DEL blob drains
    // first. The message must end up unsent — order-independent deniable erase.
    final del = WireEnvelope.del('x2').encode();
    tA.inject(InboundMessage(src: b, payload: del));
    await pumpEventQueue();

    // The original arrives after the unsend — it must NOT surface.
    final msg = WireEnvelope.message('secret',
            id: 'x2', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: msg));
    await pumpEventQueue();
    expect(await sA.isMessageDeleted(b.hex, 'x2'), isTrue,
        reason: 'a pre-message delete must leave a durable tombstone');
    expect((await sA.loadMessages(b.hex)).where((m) => m.body == 'secret'),
        isEmpty,
        reason: 'the unsent message must not surface even arriving after del');

    // A re-delivery must stay refused (deleted stays deleted).
    tA.inject(InboundMessage(src: b, payload: msg));
    await pumpEventQueue();
    expect((await sA.loadMessages(b.hex)).where((m) => m.body == 'secret'),
        isEmpty,
        reason: 're-delivery must not resurrect an unsent message');
  });

  test('a delete buffered before an edit wins (unsend is terminal)', () async {
    await mA.acceptContact(b);
    // Both a delete and a later edit drain before the message. The delete is
    // terminal: the message must stay unsent, not reappear with the edited text.
    tA.inject(InboundMessage(src: b, payload: WireEnvelope.del('x3').encode()));
    tA.inject(
        InboundMessage(src: b, payload: WireEnvelope.edit('x3', 'revived?').encode()));
    await pumpEventQueue();
    final msg = WireEnvelope.message('original',
            id: 'x3', sentAtMs: DateTime.now().millisecondsSinceEpoch)
        .encode();
    tA.inject(InboundMessage(src: b, payload: msg));
    await pumpEventQueue();
    expect(await sA.isMessageDeleted(b.hex, 'x3'), isTrue);
    expect((await sA.loadMessages(b.hex)).where((m) => m.id == 'x3' && m.body.isNotEmpty),
        isEmpty,
        reason: 'a buffered delete must win over a later buffered edit');
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
