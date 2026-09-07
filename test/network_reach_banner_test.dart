import 'dart:io';

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
    bool canBeReachedFirst = true,
    // Long enough that the "still looking" grace is not in the way of the
    // cases below, which are about WHAT the silence is rather than when.
    Duration? connectedFor = const Duration(minutes: 5),
  }) => networkReach(
    phase: phase,
    peers: peers,
    useBundledSeeds: useBundledSeeds,
    ownNodeCount: ownNodeCount,
    configuredPeerCount: configuredPeerCount,
    canBeReachedFirst: canBeReachedFirst,
    connectedFor: connectedFor,
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

  // The fifth silence, and the only one that does not look like silence at all:
  // connected, working in every direction the person tries, and unable to
  // receive a first word from anybody. That is what a mailbox nobody hosts
  // means, and it cost a real user a contact request that vanished with
  // nothing to see at either end.
  group('connected is not the same as reachable', () {
    test('says so when no relay hosts this mailbox', () {
      expect(
        reach(peers: 2, canBeReachedFirst: false),
        NetworkReach.unreachableFirst,
      );
    });

    test('stays quiet once a relay does', () {
      expect(reach(peers: 2, canBeReachedFirst: true), NetworkReach.reachable);
    });

    test('does not outrank the silences that are about having no peers', () {
      // With nobody connected there is nothing to say about being reachable
      // BY them, and the older reasons are the ones a person can act on.
      expect(
        reach(peers: 0, phase: NodePhase.stopped, canBeReachedFirst: false),
        NetworkReach.down,
      );
      expect(
        reach(peers: 0, phase: NodePhase.starting, canBeReachedFirst: false),
        NetworkReach.reachable,
      );
    });

    test('waits far longer than a flicker before it is shown', () {
      // Registration is a job with a backoff, not a blip: the honest answer
      // for the first half-minute of a launch is "not yet", and a strip that
      // appears there would be crying fault at ordinary startup.
      expect(
        kNetworkUnreachableSettle,
        greaterThan(kNetworkReachSettle * 5),
      );
    });
  });

  // The widget's half. The verdict function is pure and covered above; what
  // no unit test here can reach is whether the strip actually ASKS. A constant
  // in that argument reads correct and reports "reachable" forever — the same
  // shape as an all-online boot that resolved a LAN policy and then did not
  // pass it on.
  test('the strip measures how long it has been connected, not a constant', () {
    // A literal here reads correct and freezes the verdict forever: an hour
    // never announces an outage, a zero announces one at every launch.
    final source =
        File('lib/features/home/network_reach_banner.dart').readAsStringSync();
    final at = source.lastIndexOf('connectedFor:');
    expect(at, isNot(-1), reason: 'the strip no longer passes the answer');
    final value =
        source.substring(at + 'connectedFor:'.length, source.indexOf(',', at));
    expect(
      value,
      contains('_connectedAt'),
      reason:
          'the strip hands networkReach `$value` rather than the time since '
          'the node connected, so the grace can never expire or never apply',
    );
  });

  test('the strip asks the messaging service instead of assuming', () {
    final source =
        File('lib/features/home/network_reach_banner.dart').readAsStringSync();
    final at = source.lastIndexOf('canBeReachedFirst:');
    expect(at, isNot(-1), reason: 'the strip no longer passes the answer');
    final value = source
        .substring(at + 'canBeReachedFirst:'.length, source.indexOf(',', at))
        .trim();
    expect(
      value,
      isNot(anyOf('true', 'false')),
      reason:
          'the strip hands networkReach the constant `$value`, so it can never '
          'report the one silence it was added for',
    );
  });

  // "Connected" means the node is UP, not that it has found anybody — the same
  // misreading that cost the mailbox its carriers, biting the strip this time.
  // Reported from a laptop: "offline, no other nodes found" over a node that
  // was finding them, taken back a moment later.
  group('a node that has only just connected is still looking', () {
    test('says nothing while the first peer may still be arriving', () {
      expect(
        reach(peers: 0, connectedFor: const Duration(seconds: 5)),
        NetworkReach.reachable,
      );
    });

    test('says so once the grace is past', () {
      expect(
        reach(peers: 0, connectedFor: const Duration(seconds: 50)),
        NetworkReach.searching,
      );
    });

    test('the grace covers a desktop starting discovery from nothing', () {
      // Measured on the Windows stand: the strip fired inside the gap between
      // "connected" and the first peer, so a settle of a few seconds is not
      // enough — the gap is the better part of a minute.
      expect(kNetworkFirstPeerGrace, greaterThanOrEqualTo(
        const Duration(seconds: 30),
      ));
    });

    test('but a node with no way in at all is not made to wait', () {
      // That is a settled fact about configuration, not a race: nothing about
      // waiting will find a peer for a node that was told to look nowhere.
      expect(
        reach(
          peers: 0,
          connectedFor: const Duration(seconds: 1),
          useBundledSeeds: false,
        ),
        NetworkReach.noRoute,
      );
    });

    test('and neither is a node that is not running', () {
      expect(
        reach(
          peers: 0,
          phase: NodePhase.stopped,
          connectedFor: const Duration(seconds: 1),
        ),
        NetworkReach.down,
      );
    });
  });
}
