import 'managed_node.dart';
import 'node_auto_update.dart' show nodeUpdateOffer;

/// One node that can move, and where from and to.
class NodeUpdateStep {
  const NodeUpdateStep({
    required this.node,
    required this.from,
    required this.to,
  });

  final ManagedNode node;

  /// What the node said it was running, just now.
  final String from;

  /// The release tag it would move to.
  final String to;
}

/// What a round of node updates would do.
class NodeUpdatePlan {
  const NodeUpdatePlan({
    required this.upgradable,
    required this.unreachable,
    required this.current,
  });

  /// Nodes that answered and are behind. Empty means there is nothing to
  /// offer — and nothing to say.
  final List<NodeUpdateStep> upgradable;

  /// Nodes that were asked and did not answer, or answered something
  /// unreadable. Named rather than skipped: "update all" that quietly left two
  /// machines behind is how a fleet drifts apart without anyone deciding to.
  final List<ManagedNode> unreachable;

  /// Nodes that answered and are already at the release (or ahead of it).
  final List<ManagedNode> current;

  /// Whether there is anything worth putting in front of a person.
  ///
  /// Unreachable nodes ALONE are not: "there may be an update, we could not
  /// check" is a message nobody can act on, and repeating it every launch is
  /// the spam this exists to avoid. They are shown beside a real offer, as the
  /// part of the fleet the offer does not cover.
  bool get isWorthShowing => upgradable.isNotEmpty;
}

/// Work out what to offer for a whole fleet at once.
///
/// [reported] maps a node's id to the version it JUST gave — from an inventory
/// that succeeded — or null when it was asked and did not answer. A node
/// missing from the map was not asked at all and is treated the same as one
/// that did not answer: in both cases nobody knows what it runs, and an offer
/// built on a guess names a version the machine may not have.
NodeUpdatePlan planNodeUpdates({
  required List<ManagedNode> nodes,
  required Map<String, String?> reported,
  required String? latestTag,
}) {
  final upgradable = <NodeUpdateStep>[];
  final unreachable = <ManagedNode>[];
  final current = <ManagedNode>[];

  // No release to compare against: nobody has been asked anything, so there is
  // nothing to offer AND nothing to claim. Reporting the fleet as "current"
  // here would be a statement no comparison was made to support.
  if (nodeUpdateOffer(reportedVersion: '0.0.0', latestTag: latestTag) == null) {
    return NodeUpdatePlan(
      upgradable: upgradable,
      unreachable: unreachable,
      current: current,
    );
  }

  for (final node in nodes) {
    final said = reported[node.id];
    if (said == null || said.trim().isEmpty) {
      unreachable.add(node);
      continue;
    }
    final to = nodeUpdateOffer(reportedVersion: said, latestTag: latestTag);
    if (to == null) {
      // Either it is current, or what it said cannot be ordered. The second is
      // not "up to date" — nobody knows — so it counts as unreachable rather
      // than being reported as fine.
      if (nodeUpdateOffer(reportedVersion: said, latestTag: 'v99999.0.0') ==
          null) {
        unreachable.add(node);
      } else {
        current.add(node);
      }
      continue;
    }
    upgradable.add(NodeUpdateStep(node: node, from: said, to: to));
  }

  return NodeUpdatePlan(
    upgradable: upgradable,
    unreachable: unreachable,
    current: current,
  );
}
