import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _RealtimeProbe implements VeilTransport, RealtimeTransport {
  _RealtimeProbe(this.me);

  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
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
  Stream<int> sessionCount() => Stream.value(0);

  @override
  Future<List<PeerInfo>> peers() async => const [];

  @override
  Future<void> dispose() => inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
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
    'durable call control returns after enqueue while realtime send runs',
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
      expect(transport.normalSends, 0);
      expect(transport.lastRealtimeAnonymous, isFalse);
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        contains('call:fast-answer:answer'),
      );
      transport.realtimeGate.complete();
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
    expect(transport.normalSends, 0);
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId),
      contains('call:relay-transition:transportInfo'),
    );
  });
}
