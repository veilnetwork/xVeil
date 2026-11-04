import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Sink extends LoopbackTransport {
  _Sink() : super(localNodeId: _id(1));
  final sent = <Uint8List>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(Uint8List.fromList(payload));
  }
}

void main() {
  late HiddenVolumeStorage storage;
  late MessagingService messaging;
  late _Sink sink;
  final peer = _id(2);
  final gid = 'ab' * 32;
  const clean = '{"g":[],"keep":"live"}';
  setUp(() async {
    final raw = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required create}) => raw,
    );
    await storage.open(password: 'fixture');
    sink = _Sink();
    messaging = MessagingService(sink, storage);
    // These guards exercise pre-existing queues at an explicit sweep. New
    // admissions with live bindings are covered by the admission-expiry test.
    messaging.deviceSnapshotExpiryGroup = () async => gid;
    messaging.onDeviceSnapshotExpiry = (_, _) async => clean;
  });
  tearDown(() async {
    await messaging.dispose();
    await storage.close();
    await sink.dispose();
  });
  Future<void> queue(String body, {String? scope}) => messaging
      .sendGroupSnapshot(peer, scope ?? gid, body, awaitInitialSend: false);
  Future<List<String>> ids() async =>
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toList();
  Future<void> runSweep() async {
    messaging.groupBindingsOwner ??= Object();
    await messaging.sweepAllDisappearing();
  }

  test('only the active device group is decoded and filtered', () async {
    var calls = 0;
    messaging.onDeviceSnapshotExpiry = (scope, _) async {
      calls++;
      expect(scope, gid);
      return clean;
    };
    await queue('unrelated' * 1000, scope: 'cd' * 32);
    final other = await ids();
    await queue('{"g":[],"old":"expired"}');
    await runSweep();
    expect(
      calls,
      2,
      reason: 'original and post-write replacement are both checked',
    );
    expect(await ids(), containsAll(other));
  });

  test(
    'a partial transfer is kept without filtering or acknowledging it',
    () async {
      var calls = 0;
      messaging.onDeviceSnapshotExpiry = (_, _) async {
        calls++;
        return clean;
      };
      await queue('fragmented' * 2000);
      final all = await storage.pendingOutboxFrames();
      expect(all.length, greaterThan(1));
      await storage.ackOutboxFrame(all.first.frameId, fromPeerHex: peer.hex);
      final partial = await ids();
      await runSweep();
      expect(calls, 0);
      expect(await ids(), unorderedEquals(partial));
    },
  );

  test(
    'digest mismatch cannot authorize replacement of queued bytes',
    () async {
      var calls = 0;
      messaging.onDeviceSnapshotExpiry = (_, _) async {
        calls++;
        return clean;
      };
      await queue('{"g":[],"old":"original"}');
      final original = (await storage.pendingOutboxFrames()).single;
      await storage.ackOutboxFrame(original.frameId, fromPeerHex: peer.hex);
      final altered = WireEnvelope.groupEntry(
        '{"g":[],"old":"tampered"}',
      ).withFrameId(original.frameId).encode();
      await storage.enqueueOutboxFrame(original.frameId, peer.hex, altered);
      await runSweep();
      expect(calls, 0);
      expect((await storage.pendingOutboxFrames()).single.wire, altered);
    },
  );

  test(
    'rebinding during a suspended filter does not mutate the old transfer',
    () async {
      await queue('{"g":[],"old":"expired"}');
      final before = await ids();
      final entered = Completer<void>(), release = Completer<void>();
      messaging.onDeviceSnapshotExpiry = (_, _) async {
        entered.complete();
        await release.future;
        return clean;
      };
      final sweep = messaging.sweepAllDisappearing();
      await entered.future;
      messaging.groupBindingsOwner = Object();
      release.complete();
      await sweep;
      expect(await ids(), unorderedEquals(before));
      messaging.onDeviceSnapshotExpiry = (_, _) async => clean;
      await runSweep();
      expect(await ids(), isNot(unorderedEquals(before)));
    },
  );

  test(
    'one malformed candidate does not park another valid transfer',
    () async {
      await queue('malformed');
      final bad = await ids();
      await queue('{"g":[],"old":"expired"}');
      messaging.onDeviceSnapshotExpiry = (_, body) async {
        if (body == 'malformed') throw const FormatException('fixture');
        return clean;
      };
      await runSweep();
      expect(await ids(), containsAll(bad));
      final rest = (await storage.pendingOutboxFrames()).where(
        (f) => !bad.contains(f.frameId),
      );
      expect(rest, hasLength(1));
      expect(WireEnvelope.decode(rest.single.wire).body, clean);
    },
  );

  test(
    'replacement reaches the normal initial-send lane after publication',
    () async {
      await queue('{"g":[],"old":"expired"}');
      await pumpEventQueue();
      sink.sent.clear();
      await runSweep();
      await pumpEventQueue();
      final durable = (await storage.pendingOutboxFrames()).single;
      expect(
        sink.sent
            .map(WireEnvelope.decode)
            .where((e) => e.frameId == durable.frameId && e.body == clean),
        isNotEmpty,
      );
    },
  );
}
