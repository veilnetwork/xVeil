import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _HeldStore extends HiddenVolumeStorage {
  _HeldStore()
    : super(({required password, required create}) => FakeKvLogStore());
  final entered = Completer<void>(), released = Completer<void>();
  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async {
    if (!entered.isCompleted) entered.complete();
    await released.future;
    await super.enqueueOutboxFrame(id, peer, wire);
  }
}

class _Transport
    implements
        VeilTransport,
        RealtimeTransport,
        RelayRealtimeTransport,
        DeviceRealtimeTransport,
        RealtimeInboundTransport {
  _Transport(this.me);
  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  final rt = StreamController<InboundMessage>.broadcast();
  final receipts = <WireEnvelope>[];
  _Transport? other;
  bool blockOrdinaryAck = false;
  final ackEntered = Completer<void>(), ackReleased = Completer<void>();
  NodeId? receiptDevice;
  @override
  Future<NodeId> nodeId() async => me;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List wire, {
    bool anonymous = false,
  }) async {
    if (WireEnvelope.decode(wire).kind == WireKind.ack && blockOrdinaryAck) {
      if (!ackEntered.isCompleted) ackEntered.complete();
      await ackReleased.future;
    }
    // Ordinary delivery is deliberately unavailable.
  }

  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List wire, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(wire);
    if (env.kind == WireKind.ack) receipts.add(env);
    other?.rt.add(
      InboundMessage(
        src: me,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Future<void> sendRealtimeToDevice(
    NodeId identity,
    NodeId device,
    Uint8List wire,
  ) async {
    receiptDevice = device;
    await sendRealtime(identity, wire);
  }

  @override
  Future<void> sendRelayRealtime(NodeId dst, Uint8List wire) =>
      sendRealtime(dst, wire);
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List wire) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List wire) async {}
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Stream<InboundMessage> realtimeMessages() => rt.stream;
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => [];
  @override
  Future<void> dispose() async {
    if (!ackReleased.isCompleted) ackReleased.complete();
    await inbound.close();
    await rt.close();
  }
}

void main() {
  late HiddenVolumeStorage aStore, bStore;
  late _Transport a, b;
  late MessagingService sender, receiver;
  final me = _id(1), peer = _id(2);
  setUp(() async {
    HiddenVolumeStorage make() => HiddenVolumeStorage(
      ({required password, required create}) => FakeKvLogStore(),
    );
    aStore = make();
    bStore = make();
    await aStore.open(password: 'fixture');
    await bStore.open(password: 'fixture');
    await aStore.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    await bStore.upsertContact(
      Contact(nodeId: me, status: ContactStatus.accepted),
    );
    a = _Transport(me);
    b = _Transport(peer);
    sender = MessagingService(a, aStore)..start();
    receiver = MessagingService(b, bStore)..start();
    receiver.onCallSignal = (_, _) {};
  });
  tearDown(() async {
    for (final t in [a, b]) {
      if (!t.ackReleased.isCompleted) t.ackReleased.complete();
    }
    await sender.dispose();
    await receiver.dispose();
    await a.dispose();
    await b.dispose();
    await aStore.close();
    await bStore.close();
  });
  test(
    'received call is ACKed and retired while ordinary ACK is blocked',
    () async {
      a.other = b;
      b.other = a;
      b.blockOrdinaryAck = true;
      var calls = 0;
      receiver.onCallSignal = (_, _) => calls++;
      await sender.sendCallSignal(
        peer,
        const CallSignal(callId: 'receipt', type: CallSignalType.answer),
      );
      await b.ackEntered.future;
      await pumpEventQueue();
      expect(calls, 1);
      expect(b.receipts, isNotEmpty);
      expect(await aStore.pendingOutboxFrames(), isEmpty);
      expect(b.ackReleased.isCompleted, isFalse);
    },
  );
  test('authenticated realtime ACK retires a restored call row', () async {
    const fid = 'call:restored:answer:recipient';
    final wire = WireEnvelope.callSignal(
      const CallSignal(
        callId: 'restored',
        type: CallSignalType.answer,
      ).encode(),
    ).withFrameId(fid).encode();
    await aStore.enqueueOutboxFrame(fid, peer.hex, wire);
    await sender.debugFlushOutboxFrames();
    a.rt.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.ack(fid).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await pumpEventQueue();
    expect(await aStore.pendingOutboxFrames(), isEmpty);
  });

  for (final invalid in [
    'claimed',
    'stranger',
    'another-contact',
    'body',
    'seq',
    'frame-id',
  ]) {
    test('$invalid receipt cannot retire an authored call frame', () async {
      await sender.sendCallSignal(
        peer,
        const CallSignal(callId: 'guarded', type: CallSignalType.answer),
      );
      final held = (await aStore.pendingOutboxFrames()).single;
      final outsider = _id(3);
      if (invalid == 'another-contact') {
        await aStore.upsertContact(
          Contact(nodeId: outsider, status: ContactStatus.accepted),
        );
      }
      a.rt.add(
        InboundMessage(
          src: const {'stranger', 'another-contact'}.contains(invalid)
              ? outsider
              : peer,
          payload: WireEnvelope(
            WireKind.ack,
            invalid == 'body' ? 'unexpected' : '',
            id: held.frameId,
            seq: invalid == 'seq' ? 4 : null,
            frameId: invalid == 'frame-id' ? 'nested' : null,
          ).encode(),
          provenance: invalid == 'claimed'
              ? SenderProvenance.claimed
              : SenderProvenance.signed,
        ),
      );
      await pumpEventQueue();
      expect((await aStore.pendingOutboxFrames()).map((f) => f.frameId), [
        held.frameId,
      ]);
      a.rt.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.ack(held.frameId).encode(),
          provenance: SenderProvenance.signed,
        ),
      );
      await pumpEventQueue();
      expect(await aStore.pendingOutboxFrames(), isEmpty);
    });
  }

  test(
    'call prefix cannot authorize realtime ACK of another wire kind',
    () async {
      const fid = 'call:looks-like-a-call:answer:recipient';
      await sender.sendDurable(
        peer,
        fid,
        const WireEnvelope.message('must stay durable'),
      );
      a.rt.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.ack(fid).encode(),
          provenance: SenderProvenance.signed,
        ),
      );
      await pumpEventQueue();
      expect((await aStore.pendingOutboxFrames()).map((f) => f.frameId), [fid]);
    },
  );

  test(
    'fast receipt before enqueue is not resurrected by the later write',
    () async {
      await sender.dispose();
      await aStore.close();
      final held = _HeldStore();
      aStore = held;
      await held.open(password: 'fixture');
      await held.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      sender = MessagingService(a, held)..start();
      a.other = b;
      b.other = a;
      addTearDown(() {
        if (!held.released.isCompleted) held.released.complete();
      });
      final send = sender.sendCallSignal(
        peer,
        const CallSignal(callId: 'early', type: CallSignalType.answer),
      );
      await held.entered.future;
      await pumpEventQueue();
      expect(b.receipts, isNotEmpty);
      expect(await held.pendingOutboxFrames(), isEmpty);
      held.released.complete();
      await send;
      await pumpEventQueue();
      expect(await held.pendingOutboxFrames(), isEmpty);
    },
  );

  for (final skip in ['anonymous', 'claimed', 'reply-block']) {
    test('$skip delivery retains its ordinary receipt posture', () async {
      if (skip == 'anonymous') {
        await sender.dispose();
        sender = MessagingService(a, aStore, anonymous: true)..start();
      }
      sender.onCallSignal = (_, _) {};
      a.blockOrdinaryAck = true;
      final fid = 'call:posture:answer:${me.hex}';
      a.rt.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'posture',
              type: CallSignalType.answer,
            ).encode(),
          ).withFrameId(fid).encode(),
          provenance: skip == 'claimed'
              ? SenderProvenance.claimed
              : SenderProvenance.signed,
          replyId: skip == 'reply-block' ? 11 : 0,
        ),
      );
      await pumpEventQueue();
      expect(a.receipts, isEmpty);
    });
  }

  test(
    'fast receipt targets the proven sending device at its identity endpoint',
    () async {
      sender.onCallSignal = (_, _) {};
      final device = _id(4), fid = 'call:device:answer:${me.hex}';
      a.rt.add(
        InboundMessage(
          src: peer,
          srcDevice: device,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'device',
              type: CallSignalType.answer,
            ).encode(),
          ).withFrameId(fid).encode(),
          provenance: SenderProvenance.signed,
        ),
      );
      await pumpEventQueue();
      expect(a.receiptDevice, device);
      expect(a.receipts.map((r) => r.id), everyElement(fid));
    },
  );
}
