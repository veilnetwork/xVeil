import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/home/network_reach_banner.dart';

/// Four silences, and telling them apart is the whole feature.
///
/// "Connected 0 nodes" was shown nowhere outside the Network screen, so the
/// ordinary experience of an app that cannot reach anybody was an app that
/// simply did nothing. A strip that says so is easy; a strip that says the
/// RIGHT thing is not, because the same zero means four different things and
/// three of them must not be dressed as a fault.
void main() {
  NetworkReach reach({
    NodePhase phase = NodePhase.connected,
    int peers = 0,
    bool useBundledSeeds = true,
    int ownNodeCount = 0,
    int configuredPeerCount = 0,
  }) => networkReach(
    phase: phase,
    peers: peers,
    useBundledSeeds: useBundledSeeds,
    ownNodeCount: ownNodeCount,
    configuredPeerCount: configuredPeerCount,
  );

  test('a peer is a peer, whatever else is true', () {
    expect(reach(peers: 1), NetworkReach.reachable);
    // Even while the node reports a phase that would otherwise be alarming:
    // something is connected, and that is the answer to "can I talk".
    expect(
      reach(peers: 3, phase: NodePhase.error),
      NetworkReach.reachable,
    );
  });

  test('a node still coming up has not failed to find anyone', () {
    // Every launch reports zero for its first seconds. A strip that appears
    // there and vanishes again teaches the eye to skip it.
    expect(reach(phase: NodePhase.starting), NetworkReach.reachable);
  });

  test('a node that is not running says so, and not "not found"', () {
    for (final phase in [
      NodePhase.stopped,
      NodePhase.offline,
      NodePhase.error,
    ]) {
      expect(reach(phase: phase), NetworkReach.down, reason: '$phase');
    }
  });

  test('a switched-off way in is a choice, not a fault', () {
    // Shared entry nodes declined, no node of their own, no configured peer:
    // nothing is broken and "network not found" would be a lie dressed as an
    // error. The person is the only one who can undo it.
    expect(
      reach(useBundledSeeds: false),
      NetworkReach.noRoute,
    );
    // ...and one route of their own is enough to stop saying it.
    expect(
      reach(useBundledSeeds: false, ownNodeCount: 1),
      NetworkReach.searching,
    );
    expect(
      reach(useBundledSeeds: false, configuredPeerCount: 1),
      NetworkReach.searching,
    );
  });

  test('a node that is up, has a way in, and has found nobody is offline', () {
    expect(reach(), NetworkReach.searching);
  });

  test('the settle window is long enough to outlast a reconnect', () {
    // A peer count dips to zero on a route change or an identity switch and
    // comes back within a second or two.
    expect(kNetworkReachSettle.inSeconds, greaterThanOrEqualTo(5));
  });
}
