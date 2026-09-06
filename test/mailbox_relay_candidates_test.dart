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

  // Asking once is asking too early, and that is the ordinary order of events
  // rather than a race: a node reports CONNECTED when it is up, and its peers
  // arrive after. Measured on a fresh daemon — three sessions established a
  // second after the mailbox had already been handed an empty list.
  group('waiting for somebody to carry', () {
    NodeId id(int seed) => NodeId(Uint8List.fromList(
          List<int>.generate(32, (i) => (seed + i) & 0xff),
        ));

    test('keeps asking until a carrier appears, then registers', () async {
      var asked = 0;
      var registered = false;
      final started = <List<NodeId>>[];
      await startMailboxWhenCarriersExist(
        // Empty twice, exactly like a node that is up before it has peers.
        candidates: () async => ++asked < 3 ? const <NodeId>[] : [id(1)],
        start: (relays) async {
          started.add(relays);
          registered = true;
        },
        registered: () => registered,
        cancelled: () => false,
        interval: Duration.zero,
      );
      expect(asked, 3, reason: 'it gave up while the node was still finding');
      expect(started, [
        [id(1)],
      ]);
    });

    test('does not start on an empty list', () async {
      var started = 0;
      await startMailboxWhenCarriersExist(
        candidates: () async => const <NodeId>[],
        start: (_) async => started++,
        registered: () => false,
        cancelled: () => false,
        interval: Duration.zero,
        attempts: 3,
      );
      expect(started, 0);
    });

    test('keeps trying when a start did not register', () async {
      var asked = 0;
      await startMailboxWhenCarriersExist(
        candidates: () async {
          asked++;
          return [id(2)];
        },
        start: (_) async {},
        // The relay resolved nothing, so registration did not stick.
        registered: () => false,
        cancelled: () => false,
        interval: Duration.zero,
        attempts: 4,
      );
      expect(asked, 4);
    });

    test('asks nobody once the stack it belongs to is gone', () async {
      // The check has to come BEFORE the question, not after the answer: a
      // disposed stack's transport is a dead handle, and asking it is the
      // "handle already closed" spam this provider is careful about elsewhere.
      var asked = 0;
      await startMailboxWhenCarriersExist(
        candidates: () async {
          asked++;
          return [id(3)];
        },
        start: (_) async {},
        registered: () => false,
        cancelled: () => true,
        interval: Duration.zero,
        attempts: 50,
      );
      expect(asked, 0, reason: 'it questioned a stack that was already gone');
    });
  });
}
