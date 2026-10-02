import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/peer_inventory.dart';

PeerInfo _peer(int id) => PeerInfo(
  nodeId: NodeId(Uint8List.fromList(List.filled(32, id))),
  state: PeerState.active,
  direction: PeerDirection.outbound,
  transport: '',
);

void main() {
  test(
    'count change refreshes a stale list after one native read stalls',
    () async {
      final counts = StreamController<int>();
      final stalled = Completer<List<PeerInfo>>();
      final first = Completer<void>();
      final six = Completer<void>();
      final lengths = <int>[];
      var reads = 0;
      final subscription =
          peerInventory(
            fetch: () async {
              reads++;
              if (reads == 1) return [_peer(1)];
              if (reads == 2) return stalled.future;
              return [for (var i = 1; i <= 6; i++) _peer(i)];
            },
            sessionCounts: counts.stream,
            pollInterval: const Duration(hours: 1),
            fetchTimeout: const Duration(milliseconds: 30),
          ).listen((peers) {
            lengths.add(peers.where((p) => p.isActive).length);
            if (lengths.last == 1 && !first.isCompleted) first.complete();
            if (lengths.last == 6 && !six.isCompleted) six.complete();
          });
      addTearDown(() async {
        await subscription.cancel();
        await counts.close();
      });

      await first.future.timeout(const Duration(seconds: 1));
      counts.add(2);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      counts.add(6);
      await six.future.timeout(const Duration(seconds: 1));
      expect(lengths, [1, 6], reason: 'a failed read must not erase the list');
    },
  );

  test('polling catches a state change with no count event', () async {
    final counts = StreamController<int>();
    final updated = Completer<void>();
    var reads = 0;
    final subscription =
        peerInventory(
          fetch: () async {
            reads++;
            return reads == 1 ? [_peer(1)] : [_peer(1), _peer(2)];
          },
          sessionCounts: counts.stream,
          pollInterval: const Duration(milliseconds: 20),
        ).listen((peers) {
          if (peers.length == 2 && !updated.isCompleted) updated.complete();
        });
    addTearDown(() async {
      await subscription.cancel();
      await counts.close();
    });

    await updated.future.timeout(const Duration(seconds: 1));
    expect(reads, greaterThanOrEqualTo(2));
  });

  test('a disappeared peer stays in the list as inactive', () async {
    final counts = StreamController<int>();
    final first = Completer<void>();
    final closed = Completer<PeerInfo>();
    var reads = 0;
    final subscription =
        peerInventory(
          fetch: () async => ++reads == 1 ? [_peer(1)] : const [],
          sessionCounts: counts.stream,
          pollInterval: const Duration(hours: 1),
        ).listen((peers) {
          if (peers.length == 1 &&
              peers.single.isActive &&
              !first.isCompleted) {
            first.complete();
          }
          if (peers.length == 1 &&
              !peers.single.isActive &&
              !closed.isCompleted) {
            closed.complete(peers.single);
          }
        });
    addTearDown(() async {
      await subscription.cancel();
      await counts.close();
    });

    await first.future.timeout(const Duration(seconds: 1));
    counts.add(0);
    expect(
      (await closed.future.timeout(const Duration(seconds: 1))).lastSeen,
      isNotNull,
    );
  });
}
