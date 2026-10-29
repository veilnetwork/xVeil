import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

NodeId id(int value) => NodeId(Uint8List.fromList(List.filled(32, value)));

Set<NodeId> reached(NodeId start, Map<NodeId, List<NodeId>> edges) {
  final seen = <NodeId>{start};
  final queue = [start];
  for (var cursor = 0; cursor < queue.length; cursor++) {
    for (final next in edges[queue[cursor]] ?? const <NodeId>[]) {
      if (seen.add(next)) queue.add(next);
    }
  }
  return seen;
}

void expectStronglyConnected(Map<NodeId, List<NodeId>> edges) {
  // Reachability in both directions proves a directed graph is strongly
  // connected; undirected connectivity would miss one-way dissemination.
  final reverse = {for (final node in edges.keys) node: <NodeId>[]};
  for (final entry in edges.entries) {
    for (final peer in entry.value) {
      if (reverse.containsKey(peer)) reverse[peer]!.add(entry.key);
    }
  }
  expect(reached(edges.keys.first, edges), containsAll(edges.keys));
  expect(reached(edges.keys.first, reverse), containsAll(edges.keys));
}

void main() {
  test('the 6/6 split is disconnected by XOR but connected by the overlay', () {
    final members = [
      for (var i = 0; i < 6; i++) id(i),
      for (var i = 128; i < 134; i++) id(i),
    ];
    final xor = {
      for (final self in members)
        self: nearestGroupNodesByXor(self, members.where((p) => p != self)),
    };
    expect(reached(members.first, xor), hasLength(6));
    expectStronglyConnected({
      for (final self in members)
        self: groupOverlayPeers(
          self,
          members,
          reachable: members.map((p) => p.hex).toSet(),
        ),
    });
  });

  test(
    'seven members can be weakly connected and still lose one recipient',
    () {
      final members = [for (var i = 0; i < 6; i++) id(i), id(128)];
      final xor = {
        for (final self in members)
          self: nearestGroupNodesByXor(self, members.where((p) => p != self)),
      };
      expect(reached(members.first, xor), hasLength(6));
      expect(reached(members.last, xor), hasLength(7));
      expectStronglyConnected({
        for (final self in members) self: groupOverlayPeers(self, members),
      });
    },
  );

  test(
    '1000 rosters retain directed connectivity with differing local views',
    () {
      final random = Random(2901);
      for (var trial = 0; trial < 1000; trial++) {
        final members = <NodeId>{};
        final count = 6 + random.nextInt(59);
        while (members.length < count) {
          members.add(
            NodeId(
              Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
            ),
          );
        }
        final graph = <NodeId, List<NodeId>>{};
        for (final self in members) {
          final k = 1 + random.nextInt(20);
          final live = {
            for (final peer in members)
              if (random.nextBool()) peer.hex,
          };
          final input = [...members, members.first]..shuffle(random);
          final chosen = groupOverlayPeers(self, input, k: k, reachable: live);
          expect(chosen.length, min(k, members.length - 1));
          expect(chosen.toSet(), hasLength(chosen.length));
          expect(chosen, isNot(contains(self)));
          expect(chosen.every(members.contains), isTrue);
          expect(
            groupOverlayPeers(self, input.reversed, k: k, reachable: live),
            chosen,
          );
          graph[self] = chosen;
        }
        expectStronglyConnected(graph);
      }
    },
  );

  test(
    'a shared live view bypasses offline ring members within the budget',
    () {
      final members = [for (var i = 0; i < 64; i++) id(i)];
      final online = [for (var i = 0; i < 64; i += 5) members[i]];
      final live = online.map((peer) => peer.hex).toSet();
      final graph = <NodeId, List<NodeId>>{};
      for (final self in online) {
        final chosen = groupOverlayPeers(self, members, k: 2, reachable: live);
        expect(chosen, hasLength(2));
        graph[self] = chosen.where(online.contains).toList();
      }
      expectStronglyConnected(graph);
    },
  );

  test('a conflicting live view cannot replace the canonical ring edge', () {
    final members = [for (var i = 0; i < 12; i++) id(i)];
    for (var i = 0; i < members.length; i++) {
      final chosen = groupOverlayPeers(
        members[i],
        members,
        k: 1,
        reachable: {members[(i + 6) % members.length].hex},
      );
      expect(chosen, [members[(i + 1) % members.length]]);
    }
  });

  test('empty, singleton, duplicate, and disabled selections are bounded', () {
    final self = id(1);
    expect(groupOverlayPeers(self, const []), isEmpty);
    expect(groupOverlayPeers(self, [self, self]), isEmpty);
    expect(groupOverlayPeers(self, [id(2), id(2), self]), [id(2)]);
    expect(groupOverlayPeers(self, [id(2)], k: 0), isEmpty);
    expect(groupOverlayPeers(self, [id(2)], k: -1), isEmpty);
    expect(groupOverlayPeers(self, [id(2)], reachable: {id(99).hex}), [id(2)]);
  });
}
