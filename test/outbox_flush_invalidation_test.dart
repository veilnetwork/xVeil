import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());

  Completer<void>? snapshotRead;
  Completer<void>? releaseSnapshot;
  String? datedSnapshotFrame;
  bool failReadOnce = false;

  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() async {
    if (failReadOnce) {
      failReadOnce = false;
      throw StateError('outbox read failed');
    }
    var rows = await super.pendingOutboxFrames();
    final dated = datedSnapshotFrame;
    datedSnapshotFrame = null;
    if (dated != null) {
      rows = [
        for (final row in rows)
          if (row.frameId == dated)
            OutboxFrame(
              frameId: row.frameId,
              peerHex: row.peerHex,
              wire: row.wire,
              enqueuedAtMs: DateTime(2000).millisecondsSinceEpoch,
            )
          else
            row,
      ];
    }
    final entered = snapshotRead;
    if (entered != null) {
      snapshotRead = null;
      entered.complete();
      await releaseSnapshot!.future;
    }
    return rows;
  }
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  final blocked = <String, Completer<void>>{};
  Completer<void>? enteredSend;
  Completer<void>? releaseSend;
  Completer<void>? enteredNode;
  Completer<void>? releaseNode;

  @override
  Future<NodeId> nodeId() async {
    final entered = enteredNode;
    if (entered != null) {
      enteredNode = null;
      entered.complete();
      await releaseNode!.future;
    }
    return _id(1);
  }

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    sent.add(frame);
    final entered = enteredSend;
    if (entered != null && frame.frameId == 'edit:first') {
      enteredSend = null;
      entered.complete();
      await releaseSend!.future;
    }
    await blocked[frame.frameId]?.future;
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
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

Future<void> _until(Future<bool> Function() check) async {
  for (var i = 0; i < 200; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('expected durable outbox state was not reached');
}

void main() {
  late _Storage storage;
  late _Transport transport;
  late MessagingService service;
  late DateTime clock;
  final peer = _id(2);

  setUp(() async {
    storage = _Storage();
    await storage.open(password: 'test', createIfMissing: true);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    transport = _Transport();
    clock = DateTime.now();
    service = MessagingService(transport, storage, now: () => clock);
  });

  tearDown(() async {
    for (final gate in [
      transport.releaseSend,
      transport.releaseNode,
      storage.releaseSnapshot,
      ...transport.blocked.values,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await service.dispose();
    await storage.close();
  });

  Future<void> queue(String id, String body) => storage.enqueueOutboxFrame(
    id,
    peer.hex,
    WireEnvelope.edit('message', body, seq: 1).withFrameId(id).encode(),
  );

  Future<void> retire(String id) async {
    service.debugRetireOutboxFrame(peer.hex, id);
    await _until(
      () async =>
          !(await storage.pendingOutboxFrames()).any((f) => f.frameId == id),
    );
  }

  test(
    'a confirmed frame selected behind a slow send never leaves the outbox',
    () async {
      await queue('edit:first', 'first');
      await queue('edit:later', 'already received');
      transport.enteredSend = Completer<void>();
      transport.releaseSend = Completer<void>();
      final flushed = service.debugFlushOutboxFrames();
      await transport.enteredSend!.future;
      await retire('edit:later');
      transport.releaseSend!.complete();
      await flushed;
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
    },
  );

  test(
    'a retirement during authorization cancels the captured candidate',
    () async {
      await queue('edit:first', 'first');
      await queue('edit:later', 'already received');
      transport.enteredNode = Completer<void>();
      transport.releaseNode = Completer<void>();
      final flushed = service.debugFlushOutboxFrames();
      await transport.enteredNode!.future;
      await retire('edit:later');
      transport.releaseNode!.complete();
      await flushed;
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
    },
  );

  test(
    'a snapshot overtaken by an ACK is retried from current storage',
    () async {
      await queue('edit:first', 'first');
      await queue('edit:later', 'already received');
      storage.snapshotRead = Completer<void>();
      storage.releaseSnapshot = Completer<void>();
      final entered = storage.snapshotRead!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      await retire('edit:later');
      storage.releaseSnapshot!.complete();
      await flushed;
      await service.debugFlushOutboxFrames();
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
    },
  );

  test('a requeued ID cannot publish its older captured payload', () async {
    await queue('edit:first', 'first');
    await queue('edit:later', 'old');
    transport.enteredSend = Completer<void>();
    transport.releaseSend = Completer<void>();
    final entered = transport.enteredSend!;
    final flushed = service.debugFlushOutboxFrames();
    await entered.future;
    await retire('edit:later');
    await service.sendDurable(
      peer,
      'edit:later',
      WireEnvelope.edit('message', 'new', seq: 2),
    );
    transport.releaseSend!.complete();
    await flushed;
    expect(transport.sent.map((f) => f.body), ['first', 'new']);
    final retained = (await storage.pendingOutboxFrames()).singleWhere(
      (f) => f.frameId == 'edit:later',
    );
    expect(WireEnvelope.decode(retained.wire).body, 'new');
  });

  for (final forged in [false, true]) {
    test(
      'a ${forged ? 'foreign' : 'valid'} transfer ACK while a pass waits preserves destination authority',
      () async {
        // Isolate the ACK race from the independently checked startup defer.
        service.start();
        await pumpEventQueue();
        await queue('edit:first', 'first');
        final tid = 'grp:${_id(3).hex}:${'a' * 64}:${peer.hex}';
        for (var i = 0; i < 3; i++) {
          final id = 'grpc:$tid:$i';
          await storage.enqueueOutboxFrame(
            id,
            peer.hex,
            groupEntryChunkEnvelope(
              transferId: tid,
              index: i,
              count: 3,
              data: Uint8List.fromList([i + 1]),
              transferAck: true,
            ).withFrameId(id).encode(),
          );
        }
        final source = forged ? _id(4) : peer;
        if (forged) {
          await storage.upsertContact(
            Contact(nodeId: source, status: ContactStatus.accepted),
          );
        }
        transport.enteredSend = Completer<void>();
        transport.releaseSend = Completer<void>();
        final entered = transport.enteredSend!;
        final flushed = service.debugFlushOutboxFrames();
        await entered.future;
        transport.inbound.add(
          InboundMessage(
            src: source,
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.ack('grpa:$tid').encode(),
          ),
        );
        if (!forged) {
          await _until(
            () async => (await storage.pendingOutboxFrames()).length == 1,
          );
        } else {
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(await storage.pendingOutboxFrames(), hasLength(4));
        }
        transport.releaseSend!.complete();
        await flushed;
        expect(
          transport.sent.where((f) => f.frameId?.startsWith('grpc:') ?? false),
          hasLength(forged ? 3 : 0),
        );
      },
    );
  }

  test(
    'unrelated retirement during a snapshot read leaves its rows due',
    () async {
      await queue('edit:first', 'first');
      storage.snapshotRead = Completer<void>();
      storage.releaseSnapshot = Completer<void>();
      final entered = storage.snapshotRead!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      service.debugRetireOutboxFrame(_id(4).hex, 'edit:first');
      await storage.pendingOutboxFrames();
      storage.releaseSnapshot!.complete();
      await flushed;
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    },
  );

  test(
    'many snapshot-read invalidations defer work without losing rows',
    () async {
      await queue('edit:first', 'first');
      storage.snapshotRead = Completer<void>();
      storage.releaseSnapshot = Completer<void>();
      final entered = storage.snapshotRead!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      for (var i = 0; i < 1000; i++) {
        service.debugRetireOutboxFrame(peer.hex, 'edit:unknown-$i');
      }
      await storage.pendingOutboxFrames();
      storage.releaseSnapshot!.complete();
      await flushed;
      await service.debugFlushOutboxFrames();
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    },
  );

  test(
    'waiting candidates start their retry delay at their actual attempt',
    () async {
      await queue('edit:first', 'first');
      await queue('edit:later', 'later');
      transport.enteredSend = Completer<void>();
      transport.releaseSend = Completer<void>();
      final entered = transport.enteredSend!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      clock = clock.add(const Duration(seconds: 30));
      transport.releaseSend!.complete();
      await flushed;
      clock = clock.add(const Duration(seconds: 1));
      await service.debugFlushOutboxFrames();
      expect(
        transport.sent.where((f) => f.frameId == 'edit:later'),
        hasLength(1),
      );
      expect(
        transport.sent.where((f) => f.frameId == 'edit:first'),
        hasLength(2),
      );
    },
  );

  test(
    'a cancelled silent probe remains available for the current row',
    () async {
      final ghost = _id(5);
      await storage.upsertContact(
        Contact(nodeId: ghost, status: ContactStatus.accepted),
      );
      await storage.putSetting(
        'peer_seen:${ghost.hex}',
        '${clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch}',
      );
      await queue('edit:first', 'first');
      // Keep all four recipient workers occupied so the silent peer's
      // selected probe has genuinely not started when it is cancelled.
      for (final seed in [3, 4, 6]) {
        final busy = _id(seed);
        final fid = 'edit:busy-$seed';
        await storage.upsertContact(
          Contact(nodeId: busy, status: ContactStatus.accepted),
        );
        await storage.enqueueOutboxFrame(
          fid,
          busy.hex,
          WireEnvelope.edit(
            'message',
            'busy',
            seq: 1,
          ).withFrameId(fid).encode(),
        );
        transport.blocked[fid] = Completer<void>();
      }
      const id = 'edit:ghost';
      await storage.enqueueOutboxFrame(
        id,
        ghost.hex,
        WireEnvelope.edit('message', 'old', seq: 1).withFrameId(id).encode(),
      );
      transport.enteredSend = Completer<void>();
      transport.releaseSend = Completer<void>();
      final entered = transport.enteredSend!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      service.debugRetireOutboxFrame(ghost.hex, id);
      await _until(
        () async =>
            !(await storage.pendingOutboxFrames()).any((f) => f.frameId == id),
      );
      await service.sendDurable(
        ghost,
        id,
        WireEnvelope.edit('message', 'new', seq: 2),
      );
      transport.releaseSend!.complete();
      for (final gate in transport.blocked.values) {
        gate.complete();
      }
      await flushed;
      clock = clock.add(const Duration(seconds: 21));
      await service.debugFlushOutboxFrames();
      expect(transport.sent.where((f) => f.frameId == id).map((f) => f.body), [
        'new',
      ]);
    },
  );

  test('a failed snapshot read does not lock subsequent passes', () async {
    await queue('edit:first', 'first');
    storage.failReadOnce = true;
    await service.debugFlushOutboxFrames();
    expect(transport.sent, isEmpty);
    await service.debugFlushOutboxFrames();
    expect(transport.sent.map((f) => f.frameId), ['edit:first']);
  });

  test('an obsolete age cannot retire a freshly requeued snapshot', () async {
    const id = 'grp:dated';
    await storage.enqueueOutboxFrame(
      id,
      peer.hex,
      WireEnvelope.groupEntry('old').withFrameId(id).encode(),
    );
    storage.datedSnapshotFrame = id;
    storage.snapshotRead = Completer<void>();
    storage.releaseSnapshot = Completer<void>();
    final entered = storage.snapshotRead!;
    final flushed = service.debugFlushOutboxFrames();
    await entered.future;
    await retire(id);
    await service.sendDurable(peer, id, WireEnvelope.groupEntry('new'));
    storage.releaseSnapshot!.complete();
    await flushed;
    final pending = await storage.pendingOutboxFrames();
    expect(pending, hasLength(1));
    expect(WireEnvelope.decode(pending.single.wire).body, 'new');
    expect(transport.sent.map((f) => f.body), ['new']);
  });

  test(
    'disposing the service cancels sends not yet started by a flush',
    () async {
      await queue('edit:first', 'first');
      await queue('edit:later', 'later');
      transport.enteredSend = Completer<void>();
      transport.releaseSend = Completer<void>();
      final entered = transport.enteredSend!;
      final flushed = service.debugFlushOutboxFrames();
      await entered.future;
      await service.dispose();
      transport.releaseSend!.complete();
      await flushed;
      expect(transport.sent.map((f) => f.frameId), ['edit:first']);
      expect(await storage.pendingOutboxFrames(), hasLength(2));
    },
  );
}
