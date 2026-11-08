import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int value) => NodeId(Uint8List.fromList(List.filled(32, value)));

class _Backing extends SyncWrappedAsyncKvLogStore {
  _Backing() : super(FakeKvLogStore());
  String? failure;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final retiring = ops.whereType<DeleteOp>().any(
      (op) => op.namespace == Ns.outboxIndex,
    );
    final mode = retiring ? failure : null;
    if (retiring) failure = null;
    if (mode == 'before') throw StateError('injected refusal');
    final result = await super.commit(ops);
    if (mode == 'after') throw StateError('injected lost commit reply');
    return result;
  }
}

class _Storage extends HiddenVolumeStorage {
  _Storage(_Backing backing)
    : super.async(({required password, required create}) async => backing);
  bool hold = false;
  int guardedCalls = 0;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<bool> retireOutboxFramesIfCurrent({
    required List<OutboxFrame> obsolete,
    required OutboxFrame retained,
  }) async {
    guardedCalls++;
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.retireOutboxFramesIfCurrent(
      obsolete: obsolete,
      retained: retained,
    );
  }
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId dst,
    Uint8List wire, {
    bool anonymous = false,
  }) async => sent.add(WireEnvelope.decode(wire));
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List wire) => send(dst, wire);
  @override
  Future<void> sendReply(int replyId, Uint8List wire) async {}
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}

void main() {
  late _Storage storage;
  late _Backing backing;
  late _Transport transport;
  late MessagingService service;
  late int now;
  final peer = _id(2), other = _id(3);

  setUp(() async {
    backing = _Backing();
    storage = _Storage(backing);
    await storage.open(password: 'fixture');
    for (final p in [peer, other]) {
      await storage.upsertContact(
        Contact(nodeId: p, status: ContactStatus.accepted),
      );
    }
    transport = _Transport();
    now = DateTime.now().millisecondsSinceEpoch;
    service = MessagingService(transport, storage);
  });
  tearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await storage.close();
    await transport.dispose();
  });

  Future<OutboxFrame> queue(
    int stamp, {
    String call = 'active',
    NodeId? destination,
    CallTransportKind route = CallTransportKind.relay,
    bool? upgrade,
    CallMedia? capture,
  }) async {
    final to = destination ?? peer;
    final signal = CallSignal(
      callId: call,
      type: CallSignalType.transportInfo,
      sentAtMs: stamp,
      transport: CallTransportProposal(route),
      p2pUpgradeAllowed: upgrade,
      capture: capture,
    );
    final id = 'call:$call:transportInfo:$stamp:${route.index}:${to.hex}';
    final wire = WireEnvelope.callSignal(
      signal.encode(),
    ).withFrameId(id).encode();
    await storage.enqueueOutboxFrame(id, to.hex, wire);
    return (await storage.pendingOutboxFrames()).singleWhere(
      (frame) => frame.frameId == id,
    );
  }

  test(
    'restored call route queue retries only its newest durable state',
    () async {
      final old = await queue(now - 3000);
      final middle = await queue(now - 2000);
      final latest = await queue(now - 1000, route: CallTransportKind.p2p);
      await service.debugFlushOutboxFrames();
      expect((await storage.pendingOutboxFrames()).map((f) => f.frameId), [
        latest.frameId,
      ]);
      expect(transport.sent, isNotEmpty);
      expect(
        transport.sent.map((f) => f.frameId),
        isNot(anyOf(contains(old.frameId), contains(middle.frameId))),
      );
    },
  );

  test(
    'equal timestamps and another call or recipient remain durable',
    () async {
      final old = await queue(now - 3000);
      final relay = await queue(now - 1000);
      final direct = await queue(now - 1000, route: CallTransportKind.p2p);
      final otherCall = await queue(now - 3000, call: 'another');
      final otherPeer = await queue(now - 3000, destination: other);
      await service.debugFlushOutboxFrames();
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        unorderedEquals([
          relay.frameId,
          direct.frameId,
          otherCall.frameId,
          otherPeer.frameId,
        ]),
      );
      expect(
        transport.sent.map((f) => f.frameId),
        isNot(contains(old.frameId)),
      );
    },
  );

  for (final mode in ['before', 'after']) {
    test(
      'uncertain retirement ($mode commit) never retries captured old state',
      () async {
        final old = await queue(now - 3000);
        final latest = await queue(now - 1000);
        backing.failure = mode;
        await service.debugFlushOutboxFrames();
        expect(
          transport.sent.map((f) => f.frameId),
          isNot(contains(old.frameId)),
        );
        expect(
          (await storage.pendingOutboxFrames()).map((f) => f.frameId),
          unorderedEquals([if (mode == 'before') old.frameId, latest.frameId]),
        );
        await service.debugFlushOutboxFrames();
        expect((await storage.pendingOutboxFrames()).map((f) => f.frameId), [
          latest.frameId,
        ]);
      },
    );
  }

  test(
    'ACK of successor during cleanup cannot resurrect it or send old image',
    () async {
      final old = await queue(now - 3000);
      final latest = await queue(now - 1000);
      storage.hold = true;
      final flush = service.debugFlushOutboxFrames();
      await storage.entered.future;
      service.debugRetireOutboxFrame(peer.hex, latest.frameId);
      // The serialized read is behind the durable ACK, not just its scheduling.
      expect((await storage.pendingOutboxFrames()).map((f) => f.frameId), [
        old.frameId,
      ]);
      storage.release.complete();
      await flush;
      expect((await storage.pendingOutboxFrames()).map((f) => f.frameId), [
        old.frameId,
      ]);
      expect(transport.sent, isEmpty);
    },
  );

  test(
    'capture changes and explicit P2P withdrawal are independent obligations',
    () async {
      final capture = await queue(
        now - 4000,
        capture: const CallMedia(audio: true),
      );
      final withdrawal = await queue(now - 3000, upgrade: false);
      final latest = await queue(
        now - 1000,
        route: CallTransportKind.p2p,
        upgrade: true,
      );
      await service.debugFlushOutboxFrames();
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        unorderedEquals([capture.frameId, withdrawal.frameId, latest.frameId]),
      );
      final newerWithdrawal = await queue(now, upgrade: false);
      await service.debugFlushOutboxFrames();
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        unorderedEquals([capture.frameId, newerWithdrawal.frameId]),
      );
    },
  );

  test('cleanup is bounded to four call cohorts per flush', () async {
    for (var i = 0; i < 8; i++) {
      await queue(now - 3000, call: 'call-$i');
      await queue(now - 1000, call: 'call-$i');
    }
    await service.debugFlushOutboxFrames();
    expect(storage.guardedCalls, 4);
    expect(await storage.pendingOutboxFrames(), hasLength(12));
    await service.debugFlushOutboxFrames();
    expect(storage.guardedCalls, 8);
    expect(await storage.pendingOutboxFrames(), hasLength(8));
  });

  for (final variant in [
    'future-field',
    'ordered',
    'noncanonical',
    'foreign-kind',
  ]) {
    test('$variant is never interpreted as supersedable route state', () async {
      final old = await queue(now - 3000);
      final decoded = WireEnvelope.decode(old.wire);
      final body = jsonDecode(decoded.body) as Map<String, dynamic>;
      if (variant == 'future-field') body['futureControl'] = true;
      final id = variant == 'noncanonical'
          ? '${old.frameId}:extra'
          : old.frameId;
      await storage.ackOutboxFrame(old.frameId, fromPeerHex: peer.hex);
      final wire = WireEnvelope(
        variant == 'foreign-kind' ? WireKind.message : decoded.kind,
        jsonEncode(body),
        frameId: id,
        seq: variant == 'ordered' ? 17 : null,
      ).encode();
      await storage.enqueueOutboxFrame(id, peer.hex, wire);
      final latest = await queue(now - 1000);
      await service.debugFlushOutboxFrames();
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        unorderedEquals([id, latest.frameId]),
      );
      expect(storage.guardedCalls, 0);
    });
  }

  test('storage guard requires the exact durable peer and bytes', () async {
    final old = await queue(now - 3000);
    final latest = await queue(now - 1000);
    final changed = OutboxFrame(
      frameId: latest.frameId,
      peerHex: latest.peerHex,
      wire: Uint8List.fromList([...latest.wire, 0]),
    );
    expect(
      await storage.retireOutboxFramesIfCurrent(
        obsolete: [old],
        retained: changed,
      ),
      isFalse,
    );
    final wrongPeer = OutboxFrame(
      frameId: latest.frameId,
      peerHex: other.hex,
      wire: latest.wire,
    );
    expect(
      () => storage.retireOutboxFramesIfCurrent(
        obsolete: [old],
        retained: wrongPeer,
      ),
      throwsArgumentError,
    );
    expect(await storage.pendingOutboxFrames(), hasLength(2));
    expect(
      await storage.retireOutboxFramesIfCurrent(
        obsolete: [old],
        retained: latest,
      ),
      isTrue,
    );
    service.debugRetireOutboxFrame(peer.hex, old.frameId);
    expect((await storage.pendingOutboxFrames()).map((f) => f.frameId), [
      latest.frameId,
    ]);
  });
}
