import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Sink extends LoopbackTransport {
  _Sink() : super(localNodeId: _id(1));
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
}

class _Observed extends MessagingService {
  _Observed(super.transport, super.storage, {super.now});
  Future<int>? automaticTrim;
  @override
  Future<int> dropReplicationBacklogFor(NodeId peer) =>
      automaticTrim = super.dropReplicationBacklogFor(peer);
}

void main() {
  late HiddenVolumeStorage storage;
  late _Sink link;
  late _Observed messaging;
  final peer = _id(2), other = _id(3);
  setUp(() async {
    final raw = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required create}) => raw,
    );
    await storage.open(password: 'fixture');
    for (final p in [peer, other]) {
      await storage.upsertContact(
        Contact(nodeId: p, status: ContactStatus.accepted),
      );
    }
    link = _Sink();
    messaging = _Observed(link, storage);
    await Future.wait([
      for (var i = 0; i < 256; i++)
        storage.enqueueOutboxFrame(
          'grp:held-$i',
          peer.hex,
          WireEnvelope.groupEntry('held-$i').encode(),
        ),
    ]);
  });
  tearDown(() async {
    if (messaging.automaticTrim != null) await messaging.automaticTrim;
    await messaging.dispose();
    await storage.close();
    await link.dispose();
  });

  Future<List<String>> ids([NodeId? p]) async =>
      (await storage.pendingOutboxFrames())
          .where((f) => p == null || f.peerHex == p.hex)
          .map((f) => f.frameId)
          .toList();
  Future<void> pressure() async {
    await messaging.sendGroupSnapshot(peer, 'ab' * 32, 'declined-new-copy');
    // Observe the policy's background work, not merely the immediate queue
    // length before asynchronous retirements have had a chance to commit.
    if (messaging.automaticTrim != null) await messaging.automaticTrim;
    await storage.pendingOutboxFrames();
  }

  test('cap refuses admission without deleting fresh durable state', () async {
    final before = await ids(peer);
    await pressure();
    expect(await ids(peer), unorderedEquals(before));
    expect(messaging.automaticTrim, isNull);
    await messaging.dispose();
    await storage.close();
    expect(await storage.open(password: 'fixture'), isTrue);
    expect(await ids(peer), unorderedEquals(before));
  });

  test(
    'one full peer does not discard its frames or stop another peer',
    () async {
      final before = await ids(peer);
      await storage.enqueueOutboxFrame(
        'event',
        other.hex,
        Uint8List.fromList([1]),
      );
      await pressure();
      await messaging.sendGroupSnapshot(other, 'ab' * 32, 'accepted-new-copy');
      expect(await ids(peer), unorderedEquals(before));
      expect(await ids(other), hasLength(2));
      expect(await ids(other), contains('event'));
    },
  );

  test('real ACK retirement reopens admission below the same cap', () async {
    await pressure();
    expect(await ids(peer), hasLength(256));
    for (final id in (await ids(peer)).take(20)) {
      messaging.debugRetireOutboxFrame(peer.hex, id);
    }
    await pumpEventQueue();
    expect(await ids(peer), hasLength(236));
    await messaging.sendGroupSnapshot(peer, 'ab' * 32, 'after-drain');
    expect(await ids(peer), hasLength(237));
  });
  test(
    'existing six-hour state expiry still leaves ordinary events intact',
    () async {
      await storage.enqueueOutboxFrame(
        'ordinary-event',
        peer.hex,
        Uint8List.fromList([1, 2, 3]),
      );
      await messaging.dispose();
      final clock = DateTime.now().add(const Duration(hours: 7));
      messaging = _Observed(link, storage, now: () => clock);
      await messaging.debugFlushOutboxFrames();
      await pumpEventQueue();
      expect(await ids(peer), ['ordinary-event']);
    },
  );
}
