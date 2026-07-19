import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _RealtimeProbe
    implements VeilTransport, RealtimeTransport, RealtimeInboundTransport {
  _RealtimeProbe(this.me);

  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  final realtimeInbound = StreamController<InboundMessage>.broadcast();
  final realtimeGate = Completer<void>();
  bool blockRealtime = false;
  int normalSends = 0;
  int realtimeSends = 0;
  bool? lastRealtimeAnonymous;

  @override
  Future<NodeId> nodeId() async => me;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    normalSends++;
  }

  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    realtimeSends++;
    lastRealtimeAnonymous = anonymous;
    if (blockRealtime) await realtimeGate.future;
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}

  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}

  @override
  Stream<InboundMessage> messages() => inbound.stream;

  @override
  Stream<InboundMessage> realtimeMessages() => realtimeInbound.stream;

  @override
  Stream<int> sessionCount() => Stream.value(0);

  @override
  Future<List<PeerInfo>> peers() async => const [];

  @override
  Future<void> dispose() async {
    await inbound.close();
    await realtimeInbound.close();
  }
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

class _BlockingOutboxStorage extends HiddenVolumeStorage {
  _BlockingOutboxStorage() : super(_memOpener());

  final enqueueEntered = Completer<void>();
  final releaseEnqueue = Completer<void>();

  @override
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) async {
    if (!enqueueEntered.isCompleted) enqueueEntered.complete();
    await releaseEnqueue.future;
    await super.enqueueOutboxFrame(frameId, peerHex, wire);
  }
}

class _BlockingContactStorage extends HiddenVolumeStorage {
  _BlockingContactStorage() : super(_memOpener());

  final readEntered = Completer<void>();
  final releaseRead = Completer<void>();
  bool blockReads = false;

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    if (blockReads) {
      if (!readEntered.isCompleted) readEntered.complete();
      await releaseRead.future;
    }
    return super.getContact(nodeId);
  }
}

class _ThrowOnceContactStorage extends HiddenVolumeStorage {
  _ThrowOnceContactStorage() : super(_memOpener());

  bool throwNextRead = false;

  @override
  Future<Contact?> getContact(NodeId nodeId) {
    if (throwNextRead) {
      throwNextRead = false;
      throw StateError('injected contact read failure');
    }
    return super.getContact(nodeId);
  }
}

void main() {
  late NodeId me;
  late NodeId peer;
  late _RealtimeProbe transport;
  late HiddenVolumeStorage storage;

  setUp(() async {
    me = _id(1);
    peer = _id(2);
    transport = _RealtimeProbe(me);
    storage = HiddenVolumeStorage(_memOpener());
    await storage.open(password: 'pw', createIfMissing: true);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    addTearDown(transport.dispose);
    addTearDown(storage.close);
  });

  test(
    'durable call control races contact and realtime without awaiting either',
    () async {
      transport.blockRealtime = true;
      final messaging = MessagingService(transport, storage);
      addTearDown(messaging.dispose);

      await messaging
          .sendCallSignal(
            peer,
            const CallSignal(
              callId: 'fast-answer',
              type: CallSignalType.answer,
            ),
          )
          .timeout(const Duration(milliseconds: 500));

      expect(transport.realtimeSends, 1);
      expect(
        transport.normalSends,
        1,
        reason: 'a cold call has no direct session yet, so contact must race',
      );
      expect(transport.lastRealtimeAnonymous, isFalse);
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        contains('call:fast-answer:answer'),
      );
      transport.realtimeGate.complete();
    },
  );

  test('realtime call leg starts before a blocked durable enqueue', () async {
    final blockedStorage = _BlockingOutboxStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    addTearDown(blockedStorage.close);
    final messaging = MessagingService(transport, blockedStorage);
    addTearDown(messaging.dispose);

    final send = messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'storage-hol', type: CallSignalType.offer),
    );
    await blockedStorage.enqueueEntered.future.timeout(
      const Duration(milliseconds: 500),
    );

    expect(transport.realtimeSends, 1);
    expect(
      transport.normalSends,
      1,
      reason: 'the routable cold-start leg must precede durable storage',
    );
    blockedStorage.releaseEnqueue.complete();
    await send;
  });

  test(
    'realtime P2P endpoint leg starts before a blocked durable enqueue',
    () async {
      final blockedStorage = _BlockingOutboxStorage();
      await blockedStorage.open(password: 'pw', createIfMissing: true);
      await blockedStorage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      addTearDown(() async {
        if (!blockedStorage.releaseEnqueue.isCompleted) {
          blockedStorage.releaseEnqueue.complete();
        }
        await blockedStorage.close();
      });
      final messaging = MessagingService(transport, blockedStorage);
      addTearDown(messaging.dispose);

      final send = messaging.sendP2PEndpoints(
        peer,
        '{"v":1,"ts":123,"e":["veil:bootstrap?test"]}',
        sentAtMs: 123,
      );
      await blockedStorage.enqueueEntered.future.timeout(
        const Duration(milliseconds: 500),
      );

      expect(transport.realtimeSends, 1);
      expect(
        transport.normalSends,
        1,
        reason: 'cold bootstrap also races the routable contact lane',
      );
      blockedStorage.releaseEnqueue.complete();
      await send;
      expect(
        (await blockedStorage.pendingOutboxFrames()).map((f) => f.frameId),
        contains('p2p:ep:123'),
      );
    },
  );

  test(
    'anonymous realtime signaling never downgrades to clear direct send',
    () async {
      final messaging = MessagingService(transport, storage, anonymous: true);
      addTearDown(messaging.dispose);

      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'anon-health', type: CallSignalType.health),
      );

      expect(transport.realtimeSends, 1);
      expect(transport.lastRealtimeAnonymous, isTrue);
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
    },
  );

  test('relay route transition is realtime and durably re-driven', () async {
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(
        callId: 'relay-transition',
        type: CallSignalType.transportInfo,
        transport: CallTransportProposal(CallTransportKind.relay),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.realtimeSends, 1);
    expect(transport.normalSends, 1);
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId),
      contains('call:relay-transition:transportInfo'),
    );
  });

  test('dedicated realtime inbound stream reaches call signaling', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (source, signal) {
      expect(source, peer);
      if (!received.isCompleted) received.complete(signal);
    };
    const answer = CallSignal(
      callId: 'direct-control-inbound',
      type: CallSignalType.answer,
    );

    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(answer.encode()).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, answer.callId);
    expect(actual.type, answer.type);
  });

  test(
    'dedicated realtime inbound stream reaches P2P endpoint handler once',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      const body = '{"v":1,"ts":456,"e":["veil:bootstrap?accepted-peer"]}';
      final received = Completer<String>();
      var calls = 0;
      messaging.onP2PEndpoints = (source, actualBody) {
        expect(source, peer);
        calls++;
        if (!received.isCompleted) received.complete(actualBody);
      };
      final wire = WireEnvelope.p2pEndpoints(
        body,
      ).withFrameId('p2p:ep:456').encode();

      transport.realtimeInbound.add(InboundMessage(src: peer, payload: wire));

      expect(
        await received.future.timeout(const Duration(milliseconds: 500)),
        body,
      );
      transport.realtimeInbound.add(InboundMessage(src: peer, payload: wire));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'a realtime re-drive must be deduplicated');
    },
  );

  test('realtime P2P endpoints stay behind accepted-contact consent', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    var calls = 0;
    messaging.onP2PEndpoints = (_, _) => calls++;

    transport.realtimeInbound.add(
      InboundMessage(
        src: _id(3),
        payload: WireEnvelope.p2pEndpoints(
          '{"v":1,"ts":789,"e":["veil:bootstrap?stranger"]}',
        ).withFrameId('p2p:ep:789').encode(),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 0);
    expect(transport.realtimeSends, 0, reason: 'a stranger is not ACKed');
    expect(transport.normalSends, 0, reason: 'a stranger is not ACKed');
  });

  test(
    'one failed realtime contact read does not poison later frames',
    () async {
      final flakyStorage = _ThrowOnceContactStorage();
      await flakyStorage.open(password: 'pw', createIfMissing: true);
      await flakyStorage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final messaging = MessagingService(transport, flakyStorage)..start();
      addTearDown(messaging.dispose);
      addTearDown(flakyStorage.close);
      final received = Completer<String>();
      messaging.onP2PEndpoints = (_, body) {
        if (!received.isCompleted) received.complete(body);
      };
      flakyStorage.throwNextRead = true;

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.p2pEndpoints(
            '{"v":1,"ts":900,"e":["veil:bootstrap?first"]}',
          ).withFrameId('p2p:ep:900').encode(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      const secondBody = '{"v":1,"ts":901,"e":["veil:bootstrap?second"]}';
      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.p2pEndpoints(
            secondBody,
          ).withFrameId('p2p:ep:901').encode(),
        ),
      );

      expect(
        await received.future.timeout(const Duration(milliseconds: 500)),
        secondBody,
      );
    },
  );

  test('realtime call lane bypasses a blocked ordinary inbound', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage);
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    // The outgoing consent check warms the bounded in-session call cache.
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'warm-consent', type: CallSignalType.health),
    );
    messaging.start();
    blockedStorage.blockReads = true;
    transport.inbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'ordinary-backlog',
            type: CallSignalType.offer,
          ).encode(),
        ).encode(),
      ),
    );
    await blockedStorage.readEntered.future.timeout(
      const Duration(milliseconds: 500),
    );

    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'priority-answer',
            type: CallSignalType.answer,
          ).encode(),
        ).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'priority-answer');
    expect(actual.type, CallSignalType.answer);
    blockedStorage.releaseRead.complete();
  });

  test('realtime answer never waits for an unwarmed contact read', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage)..start();
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    blockedStorage.blockReads = true;
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'cold-cache-answer',
            type: CallSignalType.answer,
          ).encode(),
        ).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'cold-cache-answer');
    expect(actual.type, CallSignalType.answer);
    expect(blockedStorage.readEntered.isCompleted, isFalse);
  });

  test('realtime offer remains behind the durable consent gate', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage)..start();
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    blockedStorage.blockReads = true;
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'gated-offer',
            type: CallSignalType.offer,
          ).encode(),
        ).encode(),
      ),
    );

    await blockedStorage.readEntered.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(received.isCompleted, isFalse);

    blockedStorage.releaseRead.complete();
    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'gated-offer');
    expect(actual.type, CallSignalType.offer);
  });
}
