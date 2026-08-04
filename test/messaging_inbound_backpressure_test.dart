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
import 'package:xveil/state/messaging_core.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

  /// When set, [send] parks here — a handler stuck mid-flight.
  Completer<void>? sendGate;

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
    final gate = sendGate;
    if (gate != null) await gate.future;
    peer?._inbound.add(
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
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;
  late Completer<void> stall;

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
    stall = Completer<void>();

    // Become accepted contacts, so a plain message from A is one B stores —
    // otherwise the consent gate, not the queue bound, explains every miss.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    expect((await sB.getContact(a))!.status, ContactStatus.accepted);
  });

  tearDown(() async {
    if (!stall.isCompleted) stall.complete();
    await mA.dispose();
    await mB.dispose();
  });

  test('a saturated inbound lane DROPS frames instead of queueing them', () async {
    // Fill B's lane with frames whose handling never finishes — the shape the
    // un-awaited listener could reach, and could not survive, before XV-05.
    // Distinct sources so the per-peer ceiling is not what stops us.
    var parked = 0;
    for (var peer = 10; peer < 60; peer++) {
      final held = mB.inboundAdmission.admit(
        InboundMessage(
          src: _id(peer),
          payload: Uint8List(256 << 10),
          provenance: SenderProvenance.sessionPeer,
        ),
        known: true,
        handle: (_) => stall.future,
      );
      if (held != null) parked++;
    }
    expect(parked, 32, reason: '8 MiB of lane at 256 KiB a frame');
    expect(
      mB.inboundAdmission.queuedBytes,
      lessThanOrEqualTo(8 << 20),
      reason: 'the lane holds its budget and not a byte more',
    );
    final droppedFilling = mB.inboundAdmission.droppedFrames;
    expect(droppedFilling, 18);

    // With the lane full, a real message arrives from an accepted contact.
    await mA.sendText(b, 'while the queue is full');
    await _pump();

    expect(
      mB.inboundAdmission.droppedFrames,
      droppedFilling + 1,
      reason: 'the frame is refused at the door, not stacked behind 32 others',
    );
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      isNot(contains('while the queue is full')),
    );

    // Draining the lane restores service — a drop is back-pressure, not a wedge.
    stall.complete();
    await _pump();
    expect(mB.inboundAdmission.queuedBytes, 0);
    await mA.sendText(b, 'after the queue drained');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('after the queue drained'),
    );
  });

  test('a stranger cannot fill the lane the consent gate has not seen yet', () async {
    // The consent gate runs INSIDE handling, i.e. after the hand-off, so an
    // unknown sender used to occupy the queue for free. Admission asks the one
    // question it can answer synchronously and gives a claimed name far less.
    var parked = 0;
    for (var peer = 100; peer < 200; peer++) {
      final held = mB.inboundAdmission.admit(
        InboundMessage(
          src: _id(peer % 256),
          payload: Uint8List(64 << 10),
          provenance: SenderProvenance.claimed,
        ),
        known: false,
        handle: (_) => stall.future,
      );
      if (held != null) parked++;
    }
    expect(parked, 16, reason: '1 MiB shared stranger ceiling / 64 KiB');
    expect(mB.inboundAdmission.queuedBytes, 1 << 20);

    // An accepted contact still gets through: the strangers' ceiling is theirs.
    await mA.sendText(b, 'still delivered');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('still delivered'),
    );
  });

  test('nothing already queued is written after dispose', () async {
    final before = (await sB.loadMessages(a.hex)).length;

    // Chain a frame WITHOUT awaiting it — exactly what the stream listener
    // does — and tear the service down in the same turn. dispose() sets the
    // flag synchronously, so the chained handler must find it set.
    final queued = mB.deliverInbound(
      InboundMessage(
        src: a,
        payload: WireEnvelope.message('after the lights went out', id: 'oops1').encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    final teardown = mB.dispose();
    await Future.wait([queued, teardown]);
    await _pump();

    final after = await sB.loadMessages(a.hex);
    expect(after, hasLength(before));
    expect(
      after.map((m) => m.body),
      isNot(contains('after the lights went out')),
      reason: 'the container is closed right after dispose returns',
    );
  });

  test('dispose WAITS for the frame already past the guard', () async {
    // The early return covers frames that have not started. The one that HAS
    // started is the dangerous one: it is holding the store open, and
    // MultiIdentitySession closes the container as soon as dispose returns.
    // Park a frame mid-handling and prove the teardown does not walk away.
    final gate = Completer<void>();
    tB.sendGate = gate; // the inbound handler blocks on its ack
    final started = mB.deliverInbound(
      InboundMessage(
        src: a,
        payload: WireEnvelope.message('in flight', id: 'flight1').encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await _pump(); // past the guard, now parked inside send()

    var teardownDone = false;
    final teardown = mB.dispose().whenComplete(() => teardownDone = true);
    await _pump(80);
    expect(
      teardownDone,
      isFalse,
      reason: 'dispose returned while a frame was still writing to the store',
    );

    gate.complete();
    tB.sendGate = null;
    await teardown;
    await started;
    expect(teardownDone, isTrue);
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('in flight'),
    );
  });

  test('the realtime lane is bounded too, and more tightly', () {
    expect(mB.inboundAdmission.isClosed, isFalse);
    var parked = 0;
    for (var peer = 10; peer < 40; peer++) {
      final held = mB.realtimeAdmissionForTest.admit(
        InboundMessage(
          src: _id(peer),
          payload: Uint8List(256 << 10),
          provenance: SenderProvenance.sessionPeer,
        ),
        known: true,
        handle: (_) => stall.future,
      );
      if (held != null) parked++;
    }
    expect(parked, 4, reason: 'a 1 MiB latency lane, 256 KiB a frame');
    expect(mB.realtimeAdmissionForTest.droppedFrames, 26);
  });
}
