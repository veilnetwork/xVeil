import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final blocked = <String, Completer<void>>{};
  final sent = <({NodeId peer, String id})>[];
  final activeByPeer = <String, int>{};
  final peakByPeer = <String, int>{};
  int active = 0, peak = 0;

  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final id = WireEnvelope.decode(payload).frameId!;
    sent.add((peer: dst, id: id));
    active++;
    if (active > peak) peak = active;
    final count = (activeByPeer[dst.hex] ?? 0) + 1;
    activeByPeer[dst.hex] = count;
    if (count > (peakByPeer[dst.hex] ?? 0)) peakByPeer[dst.hex] = count;
    try {
      await blocked[id]?.future;
    } finally {
      active--;
      activeByPeer[dst.hex] = activeByPeer[dst.hex]! - 1;
    }
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

Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 250; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('independent recipient did not progress');
}

void main() {
  late HiddenVolumeStorage storage;
  late _Transport transport;
  late MessagingService service;
  late List<Future<void>> runs;
  setUp(() async {
    final memory = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required create}) => memory,
    );
    await storage.open(password: 'test', createIfMissing: true);
    transport = _Transport();
    service = MessagingService(transport, storage);
    runs = [];
  });
  tearDown(() async {
    for (final gate in transport.blocked.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(runs);
    await _until(() => transport.active == 0);
    await service.dispose();
    await storage.close();
  });
  Future<void> queue(NodeId peer, String id) async {
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    await storage.enqueueOutboxFrame(
      id,
      peer.hex,
      WireEnvelope.edit('message', id, seq: 1).withFrameId(id).encode(),
    );
  }

  void flush() => runs.add(service.debugFlushOutboxFrames());

  test(
    'a stalled recipient cannot hold a healthy recipient behind it',
    () async {
      await queue(_id(2), 'edit:slow');
      await queue(_id(3), 'edit:healthy');
      transport.blocked['edit:slow'] = Completer<void>();
      flush();
      await _until(() => transport.sent.any((f) => f.id == 'edit:slow'));
      await _until(() => transport.sent.any((f) => f.id == 'edit:healthy'));
      expect(transport.blocked['edit:slow']!.isCompleted, isFalse);
      expect(transport.peak, 2);
    },
  );

  test(
    'a long first-peer backlog cannot consume every slot in a pass',
    () async {
      for (var i = 0; i < 24; i++) {
        await queue(_id(2), 'edit:slow-$i');
      }
      await queue(_id(3), 'edit:healthy');
      transport.blocked['edit:slow-0'] = Completer<void>();
      flush();
      await _until(() => transport.sent.any((f) => f.id == 'edit:healthy'));
      expect(transport.blocked['edit:slow-0']!.isCompleted, isFalse);
      transport.blocked['edit:slow-0']!.complete();
      await Future.wait(runs);
      expect(transport.sent, hasLength(16));
      expect(transport.sent.where((f) => f.peer == _id(2)), hasLength(15));
      expect(await storage.pendingOutboxFrames(), hasLength(25));
    },
  );

  test('only four recipient lanes may be active at once', () async {
    for (var i = 0; i < 6; i++) {
      final id = 'edit:peer-$i';
      await queue(_id(i + 2), id);
      transport.blocked[id] = Completer<void>();
    }
    flush();
    await _until(() => transport.active == 4);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(transport.sent, hasLength(4));
    transport.blocked[transport.sent.first.id]!.complete();
    await _until(() => transport.sent.length == 5);
    expect(transport.peak, 4);
  });

  test(
    'each recipient keeps serial order while other recipients progress',
    () async {
      for (var i = 0; i < 4; i++) {
        await queue(_id(2), 'edit:A-$i');
      }
      for (var i = 0; i < 4; i++) {
        await queue(_id(3), 'edit:B-$i');
      }
      transport.blocked['edit:A-0'] = Completer<void>();
      transport.blocked['edit:B-0'] = Completer<void>();
      flush();
      await _until(() => transport.sent.length == 2);
      expect(
        transport.sent.map((f) => f.id),
        containsAll(['edit:A-0', 'edit:B-0']),
      );
      transport.blocked['edit:B-0']!.complete();
      await _until(
        () => transport.sent.where((f) => f.peer == _id(3)).length == 4,
      );
      expect(transport.sent.where((f) => f.peer == _id(2)), hasLength(1));
      transport.blocked['edit:A-0']!.complete();
      await Future.wait(runs);
      for (final row in [(_id(2), 'A'), (_id(3), 'B')]) {
        expect(transport.sent.where((f) => f.peer == row.$1).map((f) => f.id), [
          for (var i = 0; i < 4; i++) 'edit:${row.$2}-$i',
        ]);
      }
      expect(transport.peakByPeer.values, everyElement(1));
    },
  );

  test(
    'the existing deadline lets the pass finish without cancelling transport',
    () async {
      await queue(_id(2), 'edit:slow');
      await queue(_id(3), 'edit:healthy');
      transport.blocked['edit:slow'] = Completer<void>();
      service.liveLegDeadline = const Duration(milliseconds: 20);
      flush();
      await Future.wait(runs).timeout(const Duration(seconds: 1));
      expect(transport.blocked['edit:slow']!.isCompleted, isFalse);
      expect(
        transport.sent.map((f) => f.id),
        containsAll(['edit:slow', 'edit:healthy']),
      );
      expect(await storage.pendingOutboxFrames(), hasLength(2));
    },
  );

  test(
    'a timed-out recipient defers its unsent tail in the same pass',
    () async {
      for (var i = 0; i < 4; i++) {
        final id = 'edit:slow-$i';
        await queue(_id(2), id);
        transport.blocked[id] = Completer<void>();
      }
      await queue(_id(3), 'edit:healthy');
      service.liveLegDeadline = const Duration(milliseconds: 20);
      flush();
      await Future.wait(runs).timeout(const Duration(seconds: 1));
      expect(transport.sent.where((f) => f.peer == _id(2)), hasLength(1));
      expect(transport.sent.any((f) => f.id == 'edit:healthy'), isTrue);
      expect(await storage.pendingOutboxFrames(), hasLength(5));
    },
  );

  for (final failsLate in [false, true]) {
    test(
      'a late ${failsLate ? 'failure' : 'completion'} gates retries only for its own recipient',
      () async {
        var clock = DateTime.now();
        service = MessagingService(transport, storage, now: () => clock);
        await queue(_id(2), 'edit:slow');
        await queue(_id(3), 'edit:healthy');
        final gate = Completer<void>();
        transport.blocked['edit:slow'] = gate;
        service.liveLegDeadline = const Duration(milliseconds: 20);
        flush();
        await Future.wait(runs).timeout(const Duration(seconds: 1));
        clock = clock.add(const Duration(seconds: 31));
        flush();
        await Future.wait(runs).timeout(const Duration(seconds: 1));
        expect(transport.sent.where((f) => f.peer == _id(2)), hasLength(1));
        expect(transport.sent.where((f) => f.peer == _id(3)), hasLength(2));
        transport.blocked.remove('edit:slow');
        if (failsLate) {
          gate.completeError(StateError('late source failure'));
        } else {
          gate.complete();
        }
        await _until(() => transport.active == 0);
        await Future<void>.delayed(Duration.zero);
        flush();
        await Future.wait(runs).timeout(const Duration(seconds: 1));
        expect(transport.sent.where((f) => f.peer == _id(2)), hasLength(2));
        expect(await storage.pendingOutboxFrames(), hasLength(2));
      },
    );
  }

  test('an ACK cancels a fifth recipient before its lane starts', () async {
    for (var i = 0; i < 5; i++) {
      final id = 'edit:peer-$i';
      await queue(_id(i + 2), id);
      transport.blocked[id] = Completer<void>();
    }
    flush();
    await _until(() => transport.active == 4);
    service.debugRetireOutboxFrame(_id(6).hex, 'edit:peer-4');
    for (var i = 0; i < 100; i++) {
      if ((await storage.pendingOutboxFrames()).length == 4) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(await storage.pendingOutboxFrames(), hasLength(4));
    for (final gate in transport.blocked.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(runs);
    expect(transport.sent.any((f) => f.id == 'edit:peer-4'), isFalse);
  });
}
