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
    implements
        VeilTransport,
        RealtimeTransport,
        RelayRealtimeTransport,
        RealtimeInboundTransport {
  _RealtimeProbe(this.me);

  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  final realtimeInbound = StreamController<InboundMessage>.broadcast();
  final realtimeGate = Completer<void>();
  bool blockRealtime = false;
  int normalSends = 0;
  int realtimeSends = 0;
  int relayRealtimeSends = 0;
  bool? lastRealtimeAnonymous;
  NodeId? lastNormalDestination;
  NodeId? lastRealtimeDestination;
  NodeId? lastRelayRealtimeDestination;
  Uint8List? lastRealtimePayload;
  void Function(NodeId dst, Uint8List payload)? onNormalSend;
  void Function(NodeId dst, Uint8List payload)? onRealtimeSend;

  @override
  Future<NodeId> nodeId() async => me;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    normalSends++;
    lastNormalDestination = dst;
    onNormalSend?.call(dst, payload);
  }

  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    realtimeSends++;
    lastRealtimeDestination = dst;
    lastRealtimeAnonymous = anonymous;
    lastRealtimePayload = Uint8List.fromList(payload);
    if (blockRealtime) await realtimeGate.future;
    onRealtimeSend?.call(dst, payload);
  }

  @override
  Future<void> sendRelayRealtime(NodeId dst, Uint8List payload) async {
    relayRealtimeSends++;
    lastRelayRealtimeDestination = dst;
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
    'restored answer retries realtime and retires only after recipient ACK',
    () async {
      final sender = MessagingService(transport, storage);
      await sender.sendCallSignal(
        peer,
        const CallSignal(
          callId: 'restored-answer',
          type: CallSignalType.answer,
        ),
      );
      await sender.dispose(); // Drops the in-memory fast retry callbacks.
      final saved = (await storage.pendingOutboxFrames()).single;

      final receiverStorage = HiddenVolumeStorage(_memOpener());
      await receiverStorage.open(password: 'pw', createIfMissing: true);
      await receiverStorage.upsertContact(
        Contact(nodeId: me, status: ContactStatus.accepted),
      );
      final receiverTransport = _RealtimeProbe(peer);
      final receiver = MessagingService(receiverTransport, receiverStorage)
        ..start();
      final restored = MessagingService(transport, storage)..start();
      addTearDown(() async {
        await restored.dispose();
        await receiver.dispose();
        await receiverTransport.dispose();
        await receiverStorage.close();
      });
      final received = Completer<CallSignal>();
      var deliveries = 0;
      receiver.onCallSignal = (_, signal) {
        deliveries++;
        if (!received.isCompleted) received.complete(signal);
      };
      transport.onRealtimeSend = (dst, wire) {
        expect(dst, peer);
        expect(WireEnvelope.decode(wire).frameId, saved.frameId);
        receiverTransport.realtimeInbound.add(
          InboundMessage(
            src: me,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
      };
      final realtimeBefore = transport.realtimeSends;
      final relayBefore = transport.relayRealtimeSends;
      await restored.flushOutbox(); // Ordinary sends continue to be lost.
      expect(
        (await received.future.timeout(const Duration(seconds: 1))).type,
        CallSignalType.answer,
      );
      expect(transport.realtimeSends, greaterThan(realtimeBefore));
      expect(transport.relayRealtimeSends, greaterThan(relayBefore));
      expect(await storage.pendingOutboxFrames(), hasLength(1));

      // A duplicate live copy is ACKed, but enters the call FSM only once.
      final ack = Completer<void>();
      receiverTransport.onNormalSend = (dst, wire) {
        if (WireEnvelope.decode(wire).kind != WireKind.ack) return;
        expect(dst, me);
        transport.inbound.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        if (!ack.isCompleted) ack.complete();
      };
      receiverTransport.realtimeInbound.add(
        InboundMessage(
          src: me,
          payload: saved.wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await ack.future.timeout(const Duration(seconds: 1));
      for (var i = 0; i < 50; i++) {
        if ((await storage.pendingOutboxFrames()).isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(deliveries, 1);
    },
  );

  for (final kind in [WireKind.p2pEndpoints, WireKind.groupCallSignal]) {
    test('restored ${kind.name} retains both realtime paths', () async {
      final envelope = kind == WireKind.p2pEndpoints
          ? const WireEnvelope.p2pEndpoints('{}')
          : WireEnvelope.groupCallSignal(
              '{}',
              sentAtMs: DateTime.now().millisecondsSinceEpoch,
            );
      await storage.enqueueOutboxFrame(
        'opaque-legacy-id',
        peer.hex,
        envelope.withFrameId('opaque-legacy-id').encode(),
      );
      final restored = MessagingService(transport, storage);
      addTearDown(restored.dispose);
      await restored.flushOutbox();
      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);
      expect(WireEnvelope.decode(transport.lastRealtimePayload!).kind, kind);
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    });
  }

  test('a call frame-id cannot move chat content into realtime', () async {
    final envelope = const WireEnvelope.reconnect('ordinary');
    await storage.enqueueOutboxFrame(
      'call:misleading:answer',
      peer.hex,
      envelope.withFrameId('call:misleading:answer').encode(),
    );
    final restored = MessagingService(transport, storage);
    addTearDown(restored.dispose);
    await restored.flushOutbox();
    expect(transport.normalSends, 1);
    expect(transport.realtimeSends, 0);
    expect(transport.relayRealtimeSends, 0);
  });

  test('blocked contact cannot re-drive call control on realtime', () async {
    final sender = MessagingService(transport, storage);
    await sender.sendCallSignal(
      peer,
      const CallSignal(callId: 'blocked-retry', type: CallSignalType.answer),
    );
    await sender.dispose();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.blocked),
    );
    final restarted = MessagingService(transport, storage);
    addTearDown(restarted.dispose);
    final before = (
      transport.normalSends,
      transport.realtimeSends,
      transport.relayRealtimeSends,
    );
    await restarted.flushOutbox();
    expect((
      transport.normalSends,
      transport.realtimeSends,
      transport.relayRealtimeSends,
    ), before);
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
      expect(transport.relayRealtimeSends, 1);
      expect(
        transport.normalSends,
        1,
        reason: 'a cold call has no direct session yet, so contact must race',
      );
      expect(transport.lastRealtimeAnonymous, isFalse);
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        // Destination-bound: a fan-out owes each recipient its own row.
        contains('call:fast-answer:answer:${peer.hex}'),
      );
      transport.realtimeGate.complete();
    },
  );

  test('cold call answer keeps identity for all certificate lanes', () async {
    final device = _id(3);
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);
    messaging.pinCallReplyDevice('reply-device', peer, device);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.answer),
    );

    expect(transport.lastNormalDestination, peer);
    expect(transport.lastRealtimeDestination, peer);
    expect(transport.lastRelayRealtimeDestination, peer);
    expect((await storage.pendingOutboxFrames()).single.peerHex, peer.hex);

    // A cached direct route to a different device cannot receive the
    // caller's answer; the identity route remains the only valid fallback.
    messaging.routeFor = (_) => _id(4);
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.end),
    );
    expect(transport.lastNormalDestination, peer);

    messaging.routeFor = (_) => device;
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.cancel),
    );
    expect(transport.lastNormalDestination, peer);
  });

  test('cold offer does not seal to a cached physical route', () async {
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);
    messaging.routeFor = (_) => _id(3);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'cold-offer', type: CallSignalType.offer),
    );

    expect(transport.lastNormalDestination, peer);
    expect(transport.lastRealtimeDestination, peer);
    expect(transport.lastRelayRealtimeDestination, peer);
  });

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
    expect(transport.relayRealtimeSends, 1);
    expect(
      transport.normalSends,
      1,
      reason: 'the routable cold-start leg must precede durable storage',
    );
    blockedStorage.releaseEnqueue.complete();
    await send;
  });

  test(
    'lost call control is re-driven before the periodic outbox tick',
    () async {
      final messaging = MessagingService(transport, storage);
      addTearDown(messaging.dispose);

      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'fast-redrive', type: CallSignalType.offer),
      );
      expect(transport.normalSends, 1);
      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);

      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(transport.normalSends, 2);
      expect(transport.realtimeSends, 2);
      expect(transport.relayRealtimeSends, 2);
    },
  );

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
      expect(transport.relayRealtimeSends, 1);
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
      expect(
        transport.relayRealtimeSends,
        0,
        reason: 'anonymous signaling must never use the non-onion relay path',
      );
      expect(transport.lastRealtimeAnonymous, isTrue);
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
    },
  );

  for (final anonymous in [false, true]) {
    test('audio playout health uses realtime paths without durable work '
        '(anonymous=$anonymous)', () async {
      final messaging = MessagingService(
        transport,
        storage,
        anonymous: anonymous,
      );
      addTearDown(messaging.dispose);
      await messaging.sendCallSignal(
        peer,
        const CallSignal(
          callId: 'playout-wire',
          type: CallSignalType.health,
          audioPlayout: CallAudioPlayoutFeedback(sequence: 77, delayMs: 540),
        ),
      );
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(transport.relayRealtimeSends, anonymous ? 0 : 1);
      expect(transport.lastRealtimeAnonymous, anonymous);
      final envelope = WireEnvelope.decode(transport.lastRealtimePayload!);
      final delivered = CallSignal.tryDecode(envelope.body)!;
      expect(delivered.sentAtMs, isNotNull);
      expect(delivered.audioPlayout!.sequence, 77);
      expect(delivered.audioPlayout!.delayMs, 540);
    });
  }

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
    expect(transport.relayRealtimeSends, 1);
    expect(transport.normalSends, 1);
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId),
      contains(startsWith('call:relay-transition:transportInfo:')),
    );
  });

  test(
    'relay fallback and later direct readiness have distinct durable ids',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = <CallTransportKind?>[];
      messaging.onCallSignal = (_, signal) =>
          received.add(signal.transport?.kind);
      final wires = <Uint8List>[];
      // Even with equal millisecond timestamps, opposite transitions differ.
      for (final kind in [CallTransportKind.relay, CallTransportKind.p2p]) {
        await messaging.sendCallSignal(
          peer,
          CallSignal(
            callId: 'late-admission',
            type: CallSignalType.transportInfo,
            transport: CallTransportProposal(kind),
            sentAtMs: 1000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        wires.add(transport.lastRealtimePayload!);
      }
      final ids = wires
          .map((wire) => WireEnvelope.decode(wire).frameId)
          .toList();
      expect(ids.toSet().length, 2);
      for (final wire in [...wires, wires.first]) {
        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
      }
      await pumpEventQueue();
      expect(
        received,
        [CallTransportKind.relay, CallTransportKind.p2p],
        reason:
            'a new readiness must pass dedup, while a replay stays suppressed',
      );
    },
  );

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
      // An honest delivery: the node checked the claimed sender against the
      // authenticated peer of the session that carried the frame.
      InboundMessage honest() => InboundMessage(
        src: peer,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      );

      transport.realtimeInbound.add(honest());

      expect(
        await received.future.timeout(const Duration(milliseconds: 500)),
        body,
      );
      transport.realtimeInbound.add(honest());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'a realtime re-drive must be deduplicated');
    },
  );

  group('a name is not an identity (X/V-01)', () {
    // veil hands the app whatever sender a frame named; since 2e5471cc it also
    // hands over how much it KNOWS about that name. Before, a frame naming an
    // accepted contact WAS that contact — any node on the network could ring
    // this phone as one, or hand it bootstrap URIs to dial.

    test(
      'an unauthenticated frame wearing a contact name does not ring',
      () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        var rings = 0;
        messaging.onCallSignal = (_, _) => rings++;

        // `peer` IS an accepted contact — that is the whole point. The only
        // thing wrong with this frame is that nothing verified who sent it.
        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.callSignal(
              const CallSignal(
                callId: 'spoofed-offer',
                type: CallSignalType.offer,
              ).encode(),
            ).encode(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          rings,
          0,
          reason: 'a stranger rang the phone as one of the user\'s contacts',
        );
      },
    );

    test(
      'an unauthenticated frame wearing a contact name is not dialled',
      () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        var calls = 0;
        messaging.onP2PEndpoints = (_, _) => calls++;

        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.p2pEndpoints(
              '{"v":1,"ts":111,"e":["veil:bootstrap?attacker"]}',
            ).withFrameId('p2p:ep:111').encode(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          calls,
          0,
          reason: 'the app would have dialled an address the attacker chose',
        );
      },
    );

    test('the session cache cannot be used to answer for the claim', () async {
      // The accepted-peer cache is primed by anything that ever looked like
      // this contact, so a check placed AFTER it would let the suspect claim
      // vouch for itself. Prime it the way production does, then spoof.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'warm', type: CallSignalType.health),
      );
      var rings = 0;
      messaging.onCallSignal = (_, _) => rings++;

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'cached-spoof',
              type: CallSignalType.offer,
            ).encode(),
          ).encode(),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rings, 0, reason: 'the warm cache answered for the attacker');
    });

    test('an honest delivery from the same contact still rings', () async {
      // The control. Same contact, same frame — the only difference is that
      // this one arrived over a session whose peer the node authenticated.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = Completer<CallSignal>();
      messaging.onCallSignal = (source, signal) {
        expect(source, peer);
        if (!received.isCompleted) received.complete(signal);
      };

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'honest-offer',
              type: CallSignalType.offer,
            ).encode(),
          ).encode(),
          provenance: SenderProvenance.sessionPeer,
        ),
      );

      final actual = await received.future.timeout(
        const Duration(milliseconds: 500),
      );
      expect(actual.callId, 'honest-offer');
    });

    test('the anonymous path is not what was closed', () async {
      // Anonymous meta-E2E is `claimed` BY DESIGN — ML-KEM proves
      // confidentiality and never origin — and veil pins that with a test so a
      // future "fix" cannot quietly shut it. It must not be shut here either:
      // call follow-ups are matched by CallService against the exact live
      // (peer, callId) it is already in, so they never needed a contact check
      // and still do not have one.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = Completer<CallSignal>();
      messaging.onCallSignal = (_, signal) {
        if (!received.isCompleted) received.complete(signal);
      };

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'anonymous-answer',
              type: CallSignalType.answer,
            ).encode(),
          ).encode(),
        ),
      );

      final actual = await received.future.timeout(
        const Duration(milliseconds: 500),
      );
      expect(
        actual.callId,
        'anonymous-answer',
        reason: 'an unauthenticated lane was closed wholesale, not the spoof',
      );
    });

    test('the mailbox drain is verified, so it speaks for the contact', () {
      // The one attribution this app proves for itself: the drained sender is
      // the orchestrator's crypto-verified one, not the relay's wire hint.
      expect(SenderProvenance.signed.isAuthenticated, isTrue);
      expect(SenderProvenance.sessionPeer.isAuthenticated, isTrue);
      expect(SenderProvenance.localIpc.isAuthenticated, isTrue);
      expect(SenderProvenance.claimed.isAuthenticated, isFalse);
    });

    test('an unknown wire byte reads as a claim, never as proof', () {
      expect(SenderProvenance.fromWire(0), SenderProvenance.claimed);
      expect(SenderProvenance.fromWire(1), SenderProvenance.localIpc);
      expect(SenderProvenance.fromWire(2), SenderProvenance.sessionPeer);
      expect(SenderProvenance.fromWire(3), SenderProvenance.signed);
      for (final byte in [4, 9, 0x7F, 0xFF, -1]) {
        expect(
          SenderProvenance.fromWire(byte),
          SenderProvenance.claimed,
          reason: 'byte $byte must fail CLOSED, down to a claim and never up',
        );
      }
    });
  });

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
          provenance: SenderProvenance.sessionPeer,
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
          provenance: SenderProvenance.sessionPeer,
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
        provenance: SenderProvenance.sessionPeer,
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
