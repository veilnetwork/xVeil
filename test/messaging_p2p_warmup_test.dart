import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/state/messaging.dart';

/// A conversation asking for a direct route.
///
/// The P2P ladder — endpoint exchange, host/LAN dial, hole punch, relay — was
/// reachable from ONE place in the product: placing a call. Messaging never
/// called it, so no chat ever had a direct session, every message fell to
/// `NO_ROUTE`, and every message went through the mailbox. That is the whole of
/// why a message took seconds while a call connected.
///
/// Two halves here: the egress point must ASK for a route, and the rule about
/// whom it may ask for must stay strict.
NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Transport implements VeilTransport {
  _Transport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _Transport? peer;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    peer?._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('sending a message asks for a direct route to that peer', () async {
    final a = _id(1);
    final b = _id(2);
    final tA = _Transport(a);
    final tB = _Transport(b);
    tA.peer = tB;
    tB.peer = tA;
    final sA = HiddenVolumeStorage(_memOpener());
    final sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    final mB = MessagingService(tB, sB)..start();
    final mA = MessagingService(tA, sA)..start();

    final asked = <NodeId>[];
    mA.prepareDirectRoute = asked.add;

    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();

    // Forget the handshake. It goes to the same peer, so leaving it in would
    // let this pass on the strength of a contact request while the message
    // path — the one that matters — asked for nothing. (It did: the first
    // version of this test asserted over the whole run and survived a probe
    // that skipped exactly the chat frames.)
    asked.clear();

    await mA.sendText(b, 'meet at noon');
    await _pump();

    expect(
      asked.map((p) => p.hex),
      contains(b.hex),
      reason: 'sending a MESSAGE must ask for a direct route — without this the '
          'ladder is reachable only from a call, and a conversation has no '
          'route to use at all',
    );
  });

  test('a service with no wiring sends exactly as before', () async {
    final a = _id(3);
    final b = _id(4);
    final tA = _Transport(a);
    final tB = _Transport(b);
    tA.peer = tB;
    tB.peer = tA;
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    final mA = MessagingService(tA, sA)..start();
    // prepareDirectRoute deliberately left null — the loopback and dev stacks
    // run this way, and a send must not care.
    await mA.sendRequest(b, 'hi');
    await _pump();
  });

  test('a fresh endpoint share retires the one it supersedes', () async {
    final a = _id(5);
    final b = _id(6);
    final tA = _Transport(a);
    final tB = _Transport(b);
    tA.peer = tB;
    tB.peer = tA;
    final sA = HiddenVolumeStorage(_memOpener());
    final sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    final mB = MessagingService(tB, sB)..start();
    final mA = MessagingService(tA, sA)..start();
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();

    // Cut delivery so nothing acks: this is about what the SENDER keeps, and
    // an ack would retire the frames for a different reason.
    tA.peer = null;

    await mA.sendP2PEndpoints(b, '{"v":1,"ts":1000,"e":[]}', sentAtMs: 1000);
    await _pump();
    await mA.sendP2PEndpoints(b, '{"v":1,"ts":2000,"e":[]}', sentAtMs: 2000);
    await _pump();

    final endpointFrames = [
      for (final f in await sA.pendingOutboxFrames())
        if (f.frameId.startsWith('p2p:ep:')) f.frameId,
    ];
    expect(
      endpointFrames,
      ['p2p:ep:2000'],
      reason: 'a superseded address list is re-driven every few seconds and '
          'rejected on arrival as stale — the outbox must keep only the newest '
          'share per peer, or every run of the ladder adds one more forever',
    );
  });

  group('who a conversation may ask for a direct route', () {
    const known = true;

    test('the default follows the global policy, in both directions', () {
      // The option is called "follow the global policy" and until 2026-09-20
      // it followed nothing: it read as a flat no, so a person who had set the
      // policy to "all" still got `messaging ladder not allowed` on every
      // conversation with no screen saying why.
      for (final (global, accepted, expected) in <(P2PGlobalPolicy, bool, bool)>[
        (P2PGlobalPolicy.allowAll, true, true),
        (P2PGlobalPolicy.contacts, true, true),
        (P2PGlobalPolicy.contacts, false, false),
        (P2PGlobalPolicy.selected, true, false),
        (P2PGlobalPolicy.denied, true, false),
      ]) {
        expect(
          p2pMessagingAllows(
            global: global,
            override: kDefaultContactP2POverride,
            contactKnown: known,
            contactAccepted: accepted,
            contactBlocked: false,
            localAnonymous: false,
          ),
          expected,
          reason: 'global=${global.name} accepted=$accepted',
        );
      }
    });

    test('a per-contact deny overrides the most permissive global policy', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.deny,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: false,
        ),
        isFalse,
        reason: 'the narrower answer is the one the person gave about THIS '
            'contact; a global default must never widen past it',
      );
    });

    test('a per-contact allow stands even when the global policy denies', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.denied,
          override: ContactP2POverride.allow,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: false,
        ),
        isTrue,
      );
    });

    test('an explicit allow for this contact means yes', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.allow,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: false,
        ),
        isTrue,
      );
    });

    test('an anonymous identity is refused even with an explicit allow', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.allow,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: true,
        ),
        isFalse,
        reason: 'a direct endpoint is a location signal — an anonymous '
            'identity emitting one defeats the identity',
      );
    });

    test('a blocked or unknown peer is refused', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.allow,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: true,
          localAnonymous: false,
        ),
        isFalse,
      );
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.allow,
          contactKnown: false,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: false,
        ),
        isFalse,
        reason: 'nobody has opted anything in for a stranger',
      );
    });

    test('an explicit deny is refused', () {
      expect(
        p2pMessagingAllows(
          global: P2PGlobalPolicy.allowAll,
          override: ContactP2POverride.deny,
          contactKnown: known,
          contactAccepted: true,
          contactBlocked: false,
          localAnonymous: false,
        ),
        isFalse,
      );
    });
  });
}
