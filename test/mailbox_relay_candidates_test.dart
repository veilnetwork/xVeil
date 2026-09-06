import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart' show BootstrapPeerCfg;
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/messaging.dart';

void main() {
  test('mailbox relays deduplicate alternate transports for one seed', () {
    final publicKey = base64.encode(List<int>.generate(32, (i) => i));
    final relays = mailboxRelayCandidates([
      BootstrapPeerCfg(
        transport: 'obfs4-tcp://seed.example:5556',
        publicKey: publicKey,
        nonce: 'nonce',
      ),
      BootstrapPeerCfg(
        transport: 'quic://seed.example:39998',
        publicKey: publicKey,
        nonce: 'nonce',
      ),
      const BootstrapPeerCfg(
        transport: 'quic://bad.example:39998',
        publicKey: 'not-base64!',
        nonce: 'nonce',
      ),
    ]);

    expect(relays, hasLength(1));
  });

  // The production network ships NO seed list — not in the app's asset and not
  // in the native. Peers arrive through discovery instead, so a candidate list
  // built from the configured peers alone is empty on every stock install, the
  // mailbox is never built, and a contact request (the one send with no retry)
  // cannot be delivered while the node sits there reporting itself connected.
  group('a stock install has no configured peers, only discovered ones', () {
    NodeId id(int seed) => NodeId(Uint8List.fromList(
          List<int>.generate(32, (i) => (seed + i) & 0xff),
        ));

    PeerInfo peer(NodeId node, {bool active = true}) => PeerInfo(
          nodeId: node,
          state: active ? PeerState.active : PeerState.connecting,
          direction: PeerDirection.outbound,
          transport: 'quic://peer.example:9000',
        );

    test('a discovered peer can carry when nothing was configured', () {
      final found = id(1);
      expect(
        mergeMailboxRelayCandidates(const <NodeId>[], [peer(found)]),
        [found],
        reason: 'with no candidate the mailbox is never built and every '
            'deposit fails, so first contact is impossible',
      );
    });

    test('a configured node is preferred over a discovered one', () {
      final mine = id(1);
      final found = id(2);
      expect(
        mergeMailboxRelayCandidates([mine], [peer(found)]),
        [mine, found],
        reason: 'an operator runs their own node deliberately and keeps it up; '
            'a discovered peer is the fallback, not the first choice',
      );
    });

    test('a peer that is not active is not offered as a carrier', () {
      expect(
        mergeMailboxRelayCandidates(const <NodeId>[], [
          peer(id(1), active: false),
        ]),
        isEmpty,
      );
    });

    test('the same node from both sources is offered once', () {
      final both = id(7);
      expect(mergeMailboxRelayCandidates([both], [peer(both)]), [both]);
    });
  });

  // The lookup, not just the merge: a stock install's whole answer comes from
  // asking the node, so what happens when that ask fails is part of the
  // behaviour and not an implementation detail.
  group('asking the node for carriers', () {
    NodeId id(int seed) => NodeId(Uint8List.fromList(
          List<int>.generate(32, (i) => (seed + i) & 0xff),
        ));

    test('a discovered peer becomes a carrier when nothing is configured',
        () async {
      final found = id(3);
      final relays = await liveMailboxRelayCandidates(
        peers: () async => [
          PeerInfo(
            nodeId: found,
            state: PeerState.active,
            direction: PeerDirection.outbound,
            transport: 'quic://peer.example:9000',
          ),
        ],
        configured: const <NodeId>[],
      );
      expect(relays, [found]);
    });

    test('a transport that cannot answer keeps the configured relays',
        () async {
      final mine = id(4);
      final relays = await liveMailboxRelayCandidates(
        peers: () async => throw StateError('node is down'),
        configured: [mine],
      );
      expect(
        relays,
        [mine],
        reason: 'a failed lookup must not cost an operator the relays they '
            'configured by hand',
      );
    });
  });
}
