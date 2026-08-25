import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

/// A neighbour that is down gives up its slot to the next reachable member.
///
/// The overlay picks the k XOR-nearest members and knew nothing about who was
/// up, so a member that went away kept its slot: the sparse fan-out kept
/// addressing it and this device's own gap-fill waited for it to come back.
/// Sends are durable, so nothing was lost, but a member that never returns
/// held a slot for good — and the design was always meant to move on.
///
/// It is a PREFERENCE, not a filter: the list is still filled to k from the
/// nearest of the rest, so a stale or empty view can only reorder the result.
void main() {
  NodeId id(int byte) => NodeId(Uint8List.fromList(List<int>.filled(32, byte)));

  final self = id(0x00);
  // Sorted by XOR distance from `self`, these are ascending by byte.
  final members = [for (var b = 1; b <= 8; b++) id(b)];

  test('with no liveness view the choice is exactly the nearest k', () {
    final chosen = nearestGroupNodesByXor(self, members, k: 3);
    expect(
      chosen.map((n) => n.hex).toList(),
      [members[0].hex, members[1].hex, members[2].hex],
      reason: 'this is the behaviour every deployment has today',
    );

    // An EMPTY view is "I know of nobody", not "nobody is up".
    expect(
      nearestGroupNodesByXor(self, members, k: 3, reachable: const <String>{})
          .map((n) => n.hex)
          .toList(),
      [members[0].hex, members[1].hex, members[2].hex],
    );
  });

  test('a down neighbour loses its slot to the next reachable member', () {
    // The two nearest are down; everything past them is up.
    final reachable = {for (final m in members.skip(2)) m.hex};

    final chosen = nearestGroupNodesByXor(
      self,
      members,
      k: 3,
      reachable: reachable,
    );
    final chosenHex = chosen.map((n) => n.hex).toList();

    expect(
      chosenHex.take(3),
      [members[2].hex, members[3].hex, members[4].hex],
      reason:
          'the reachable members nearest to self must come first, or a '
          'neighbour that is down keeps addressing traffic nobody reads',
    );
    expect(
      chosenHex.contains(members[0].hex),
      isFalse,
      reason: 'the nearest member is down and must not hold a slot',
    );
  });

  test('the list is still filled to k when too few are reachable', () {
    // Only ONE member is up, but k is 3.
    final reachable = {members[5].hex};

    final chosen = nearestGroupNodesByXor(
      self,
      members,
      k: 3,
      reachable: reachable,
    );

    expect(chosen.length, 3, reason: 'a preference must never shrink the set');
    expect(
      chosen.first.hex,
      members[5].hex,
      reason: 'the one reachable member leads',
    );
    // The rest is topped up from the nearest of the others, in XOR order.
    expect(
      chosen.skip(1).map((n) => n.hex).toList(),
      [members[0].hex, members[1].hex],
    );
  });

  test('fewer members than k returns them all, view or no view', () {
    final few = members.take(2).toList();
    expect(nearestGroupNodesByXor(self, few, k: 5).length, 2);
    expect(
      nearestGroupNodesByXor(self, few, k: 5, reachable: {few[1].hex}).length,
      2,
    );
  });
}
