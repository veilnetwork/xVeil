import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_update_plan.dart';

/// One offer for the whole fleet, built only from what the machines just said.
///
/// The two things it must not do: invent an offer for a node nobody could
/// reach, and quietly leave such a node out of the picture. The first would
/// fail the moment somebody accepted it; the second is how a fleet drifts apart
/// without anyone deciding to.
void main() {
  ManagedNode node(String id, String label) =>
      ManagedNode(id: id, label: label, sshHost: '$id.example', sshUser: 'root');

  final a = node('a', 'exit-host');
  final b = node('b', 'vdsina2');
  final c = node('c', 'old-box');

  test('nodes that answered and are behind are the offer', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.7.0', 'b': '0.8.0'},
      latestTag: 'v0.8.1',
    );

    expect(plan.upgradable, hasLength(2));
    expect(plan.upgradable.first.node.label, 'exit-host');
    // From and to, per node: "update everything" without saying what changes
    // is not a decision anybody can make.
    expect(plan.upgradable.first.from, '0.7.0');
    expect(plan.upgradable.first.to, 'v0.8.1');
    expect(plan.isWorthShowing, isTrue);
  });

  test('a node that did not answer is named, not skipped', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.7.0', 'b': null},
      latestTag: 'v0.8.1',
    );

    expect(plan.upgradable.map((s) => s.node.id), ['a']);
    expect(plan.unreachable.map((n) => n.id), ['b']);
  });

  test('a node nobody asked about counts as unreachable, not as fine', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.7.0'},
      latestTag: 'v0.8.1',
    );

    expect(plan.unreachable.map((n) => n.id), ['b']);
    expect(plan.current, isEmpty);
  });

  test('nothing to offer means nothing to show, even with nodes offline', () {
    // "There may be an update, we could not check" is a message nobody can act
    // on, and repeating it every launch is exactly the spam to avoid.
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.8.1', 'b': null},
      latestTag: 'v0.8.1',
    );

    expect(plan.upgradable, isEmpty);
    expect(plan.isWorthShowing, isFalse);
    expect(plan.unreachable.map((n) => n.id), ['b']);
  });

  test('a node already at the release is current, not offered', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.8.1', 'b': '0.7.0'},
      latestTag: 'v0.8.1',
    );

    expect(plan.current.map((n) => n.id), ['a']);
    expect(plan.upgradable.map((s) => s.node.id), ['b']);
  });

  test('a node AHEAD of the release is current, never offered a downgrade', () {
    final plan = planNodeUpdates(
      nodes: [a],
      reported: {'a': '0.9.0'},
      latestTag: 'v0.8.1',
    );

    expect(plan.current.map((n) => n.id), ['a']);
    expect(plan.upgradable, isEmpty);
  });

  test('a version nobody can order is unreachable, not "fine"', () {
    // `(unavailable)` is what the inventory prints when the node could not
    // answer. Counting it as up to date would report a broken box as healthy.
    final plan = planNodeUpdates(
      nodes: [a, b, c],
      reported: {'a': '(unavailable)', 'b': 'unknown', 'c': '0.7.0'},
      latestTag: 'v0.8.1',
    );

    expect(plan.unreachable.map((n) => n.id), ['a', 'b']);
    expect(plan.current, isEmpty);
    expect(plan.upgradable.map((s) => s.node.id), ['c']);
  });

  test('no release feed means no offer at all', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': '0.7.0', 'b': '0.7.0'},
      latestTag: null,
    );

    expect(plan.upgradable, isEmpty);
    expect(plan.isWorthShowing, isFalse);
    // And they are not reported as current either: nobody compared anything.
    expect(plan.current, isEmpty);
    expect(plan.unreachable, isEmpty);
  });

  test('an empty fleet is quiet', () {
    final plan = planNodeUpdates(
      nodes: const [],
      reported: const {},
      latestTag: 'v0.8.1',
    );

    expect(plan.isWorthShowing, isFalse);
  });
}
