import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_update_plan.dart';
import 'package:xveil/data/node/veil_github_release.dart';

/// One offer for the whole fleet, built only from what the machines just said.
///
/// The two things it must not do: invent an offer for a node nobody could
/// reach, and quietly leave such a node out of the picture. The first would
/// fail the moment somebody accepted it; the second is how a fleet drifts apart
/// without anyone deciding to.
void main() {
  ManagedNode node(String id, String label) => ManagedNode(
    id: id,
    label: label,
    sshHost: '$id.example',
    sshUser: 'root',
  );

  /// A node that answered with a version and a machine we recognise.
  NodeReading said(
    String version, [
    VeilLinuxReleaseTarget target = VeilLinuxReleaseTarget.x86_64Musl,
  ]) => NodeReading(version: version, target: target);

  final a = node('a', 'exit-host');
  final b = node('b', 'vdsina2');
  final c = node('c', 'old-box');

  test('nodes that answered and are behind are the offer', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': said('0.7.0'), 'b': said('0.8.0')},
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
      reported: {'a': said('0.7.0'), 'b': null},
      latestTag: 'v0.8.1',
    );

    expect(plan.upgradable.map((s) => s.node.id), ['a']);
    expect(plan.unreachable.map((n) => n.id), ['b']);
  });

  test('a node nobody asked about counts as unreachable, not as fine', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': said('0.7.0')},
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
      reported: {'a': said('0.8.1'), 'b': null},
      latestTag: 'v0.8.1',
    );

    expect(plan.upgradable, isEmpty);
    expect(plan.isWorthShowing, isFalse);
    expect(plan.unreachable.map((n) => n.id), ['b']);
  });

  test('a node already at the release is current, not offered', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': said('0.8.1'), 'b': said('0.7.0')},
      latestTag: 'v0.8.1',
    );

    expect(plan.current.map((n) => n.id), ['a']);
    expect(plan.upgradable.map((s) => s.node.id), ['b']);
  });

  test('a node AHEAD of the release is current, never offered a downgrade', () {
    final plan = planNodeUpdates(
      nodes: [a],
      reported: {'a': said('0.9.0')},
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
      reported: {
        'a': said('(unavailable)'),
        'b': said('unknown'),
        'c': said('0.7.0'),
      },
      latestTag: 'v0.8.1',
    );

    expect(plan.unreachable.map((n) => n.id), ['a', 'b']);
    expect(plan.current, isEmpty);
    expect(plan.upgradable.map((s) => s.node.id), ['c']);
  });

  test('no release feed means no offer at all', () {
    final plan = planNodeUpdates(
      nodes: [a, b],
      reported: {'a': said('0.7.0'), 'b': said('0.7.0')},
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

  group('which build each node gets', () {
    test('an arm64 node is offered the arm64 build, not the fleet default', () {
      // The bug this replaced: the screen resolved one artifact for everybody
      // and it was x86_64. On an arm64 server that file passes every check
      // downstream — the digest is the release's own — installs as root over
      // the working binary, and the service never comes back.
      final plan = planNodeUpdates(
        nodes: [a, b],
        reported: {
          'a': said('0.7.0', VeilLinuxReleaseTarget.aarch64Musl),
          'b': said('0.7.0'),
        },
        latestTag: 'v0.8.1',
      );

      expect(plan.upgradable, hasLength(2));
      expect(
        plan.upgradable.firstWhere((s) => s.node.id == 'a').target,
        VeilLinuxReleaseTarget.aarch64Musl,
      );
      expect(
        plan.upgradable.firstWhere((s) => s.node.id == 'b').target,
        VeilLinuxReleaseTarget.x86_64Musl,
      );
    });

    test('a machine nobody recognises is listed, never guessed at', () {
      // `uname -m` said something this build does not map — riscv64, a stripped
      // container, an inventory too old to print it. Guessing is the one
      // outcome that breaks a working server, so it joins the nodes that could
      // not be reached instead.
      final plan = planNodeUpdates(
        nodes: [a],
        reported: {'a': const NodeReading(version: '0.7.0', target: null)},
        latestTag: 'v0.8.1',
      );

      expect(plan.upgradable, isEmpty);
      expect(plan.unreachable.map((n) => n.id), ['a']);
      expect(plan.current, isEmpty);
      expect(plan.isWorthShowing, isFalse);
    });
  });

  /// A version the parser accepts must not be filed as unreachable.
  ///
  /// Validity was probed by re-running the offer against `v99999.0.0` and
  /// reading "no offer" as "cannot be ordered". The parser takes a six-digit
  /// major, so a node genuinely running 99999.0.0 — or anything above it —
  /// produced no offer for the honest reason and was reported as a node nobody
  /// could reach (report15 X15-L5).
  test(
    'a version at or above the old sentinel is current, not unreachable',
    () {
      for (final version in ['99999.0.0', '123456.0.0', '99999.9.9']) {
        final plan = planNodeUpdates(
          nodes: [a],
          reported: {'a': said(version)},
          latestTag: 'v0.8.1',
        );

        expect(
          plan.current.map((n) => n.id),
          ['a'],
          reason: '$version was not recognised as a version at all',
        );
        expect(plan.unreachable, isEmpty, reason: version);
        expect(plan.upgradable, isEmpty, reason: version);
      }
    },
  );

  /// Vacuity guard: something that is NOT a version still counts as unknown.
  /// Filing everything as current would satisfy the test above and is the
  /// error it replaced, in the other direction.
  test('and a version nobody can order is still unreachable', () {
    for (final said_ in ['not-a-version', '', '  ', '8', '0.8']) {
      final plan = planNodeUpdates(
        nodes: [a],
        reported: {
          'a': NodeReading(
            version: said_,
            target: VeilLinuxReleaseTarget.x86_64Musl,
          ),
        },
        latestTag: 'v0.8.1',
      );
      expect(
        plan.unreachable.map((n) => n.id),
        ['a'],
        reason: '"$said_" was reported as a node that is fine',
      );
      expect(plan.current, isEmpty, reason: said_);
    }
  });

  /// And a fleet asked with no usable release still claims nothing.
  test('no release to compare against offers and claims nothing', () {
    for (final tag in <String?>[null, '', '  ', 'not-a-tag']) {
      final plan = planNodeUpdates(
        nodes: [a, b],
        reported: {'a': said('0.8.0'), 'b': said('0.8.1')},
        latestTag: tag,
      );
      expect(plan.upgradable, isEmpty, reason: '$tag');
      expect(plan.current, isEmpty, reason: '$tag');
      expect(plan.unreachable, isEmpty, reason: '$tag');
    }
  });
}
