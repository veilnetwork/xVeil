import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/state/messaging_core.dart';
import 'package:xveil/state/p2p_endpoint_service.dart';

Uint8List _pk(int fill) => Uint8List.fromList(List.filled(32, fill));

/// A peer id derived the way the wire derives it — `node_id == BLAKE3(pubkey)`
/// — so an invite minted from the same key really presents THIS peer.
NodeId _peer(int fill) => NodeId(blake3Hash(_pk(fill)));

/// A dialable bootstrap invite belonging to [fill]'s identity.
String _inviteUri(int fill, {String host = '192.168.1.9'}) => BootstrapInvite(
  publicKey: _pk(fill),
  nonce: Uint8List.fromList(List.filled(8, 3)),
  transport: 'tcp://$host:9000',
).toUri();

BootstrapInvite _identity() => BootstrapInvite(
  publicKey: Uint8List.fromList(List.filled(32, 7)),
  nonce: Uint8List.fromList(List.filled(8, 9)),
);

class _FakeMessaging implements MessagingService {
  final List<(NodeId, String)> sentEndpoints = [];

  @override
  void Function(NodeId peer, String bodyJson)? onP2PEndpoints;

  @override
  Future<void> sendP2PEndpoints(
    NodeId peer,
    String bodyJson, {
    required int sentAtMs,
  }) async {
    sentEndpoints.add((peer, bodyJson));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({
    this.allows = true,
    this.lanListen = true,
    List<String>? addresses,
    this.listenTransports,
    this.listenScheme = 'tcp',
    this.injectPunch = false,
    this.punchResult = (connected: false, reason: 'hole punch timed out'),
    this.admitOnJoin = false,
  }) : addresses = addresses ?? ['192.168.1.70', '10.0.0.5'] {
    svc; // force the late-final service (attaches onP2PEndpoints)
  }

  final _FakeMessaging messaging = _FakeMessaging();
  bool allows;

  /// The per-contact messaging opt-in. Defaults to FALSE, matching the product
  /// default — a conversation gets no direct route unless someone asked for it.
  bool messagingAllows = false;
  bool lanListen;
  List<String> addresses;
  List<String>? listenTransports;
  String listenScheme;
  bool admitted = false;

  /// Whether an [attemptHolePunch] adapter is wired (mirrors a stack that
  /// can / cannot punch).
  bool injectPunch;

  /// Canned outcome the injected punch adapter returns.
  P2PPunchResult punchResult;

  /// When set, a successful `joinEndpoint` flips [admitted] — models the
  /// cheap host/LAN dial landing so the ladder never reaches the punch.
  bool admitOnJoin;

  /// Peers the injected punch adapter was invoked for (ladder-order proof).
  final List<Uint8List> punchCalls = [];
  final List<String> joined = [];
  DateTime now = DateTime.utc(2026, 7, 18, 12);

  late final P2PEndpointService svc = P2PEndpointService(
    messaging,
    localAllowsP2P: (_) async => allows,
    messagingAllowsP2P: (_) async => messagingAllows,
    joinEndpoint: (uri) async {
      joined.add(uri);
      if (admitOnJoin) admitted = true;
    },
    pnetStatus: (_) async => (admitted: admitted, hasCert: false),
    myIdentity: _identity,
    listenPort: () => 9000,
    listenScheme: () => listenScheme,
    lanListenEnabled: () => lanListen,
    localAddresses: () async => addresses,
    listenTransports: listenTransports == null
        ? null
        : () async => listenTransports!,
    attemptHolePunch: injectPunch
        ? (peer) async {
            punchCalls.add(peer);
            return punchResult;
          }
        : null,
    now: () => now,
  )..start();
}

void main() {
  _messagingWarmTests();

  test('maybeShare mints one bootstrap URI per LAN address', () async {
    final h = _Harness();
    await h.svc.maybeShare(_peer(1));
    expect(h.messaging.sentEndpoints, hasLength(1));
    final body = jsonDecode(h.messaging.sentEndpoints.single.$2) as Map;
    expect(body['v'], 1);
    final uris = (body['e'] as List).cast<String>();
    expect(uris, hasLength(2));
    expect(uris[0], contains('t=tcp://192.168.1.70:9000'));
    expect(uris[1], contains('t=tcp://10.0.0.5:9000'));
    // Each URI is a redeemable invite carrying our identity.
    final invite = BootstrapInvite.parse(uris.first);
    expect(invite.publicKey, _identity().publicKey);
    expect(invite.transport, 'tcp://192.168.1.70:9000');
  });

  test(
    'maybeShare preserves a QUIC listener scheme for media datagrams',
    () async {
      final h = _Harness(addresses: ['192.168.1.70'], listenScheme: 'quic');
      await h.svc.maybeShare(_peer(1));
      final body = jsonDecode(h.messaging.sentEndpoints.single.$2) as Map;
      final uri = (body['e'] as List).single as String;
      expect(BootstrapInvite.parse(uri).transport, 'quic://192.168.1.70:9000');
    },
  );

  test(
    'maybeShare appends the srflx listener candidate after LAN addresses',
    () async {
      final h = _Harness(
        addresses: ['192.168.1.70'],
        listenTransports: [
          'srflx://203.0.113.42:61812', // observed external addr (probe port)
          'srflx://203.0.113.42:52001', // same IP re-observed — dedup
          'srflx://192.168.1.70:40000', // private observation — same-NAT peer
          'tcp://203.0.113.42:5556', // other listener port — not ours
          'tcp://0.0.0.0:9000', // wildcard — never dialable
          'obfs4-tcp://198.51.100.9:5599', // non-tcp scheme
        ],
      );
      await h.svc.maybeShare(_peer(1));
      final body = jsonDecode(h.messaging.sentEndpoints.single.$2) as Map;
      final uris = (body['e'] as List).cast<String>();
      expect(uris, hasLength(2));
      expect(uris[0], contains('t=tcp://192.168.1.70:9000'));
      expect(uris[1], contains('t=tcp://203.0.113.42:9000'));
    },
  );

  test(
    'maybeShare mints LAN-only when the listener snapshot is unavailable',
    () async {
      final h = _Harness(addresses: ['192.168.1.70']);
      await h.svc.maybeShare(_peer(1));
      final body = jsonDecode(h.messaging.sentEndpoints.single.$2) as Map;
      final uris = (body['e'] as List).cast<String>();
      expect(uris, hasLength(1));
      expect(uris.single, contains('t=tcp://192.168.1.70:9000'));
    },
  );

  test(
    'maybeShare is silent when policy denies or listener is loopback-only',
    () async {
      final denied = _Harness(allows: false);
      await denied.svc.maybeShare(_peer(1));
      expect(denied.messaging.sentEndpoints, isEmpty);

      final loopback = _Harness(lanListen: false);
      await loopback.svc.maybeShare(_peer(1));
      expect(loopback.messaging.sentEndpoints, isEmpty);
    },
  );

  test('maybeShare throttles repeats; force bypasses', () async {
    final h = _Harness();
    final peer = _peer(1);
    await h.svc.maybeShare(peer);
    await h.svc.maybeShare(peer);
    expect(h.messaging.sentEndpoints, hasLength(1));
    h.now = h.now.add(const Duration(minutes: 4));
    await h.svc.maybeShare(peer);
    expect(h.messaging.sentEndpoints, hasLength(2));
    await h.svc.maybeShare(peer, force: true);
    expect(h.messaging.sentEndpoints, hasLength(3));
  });

  test(
    'inbound frame: consenting side replies and dials until admitted',
    () async {
      final h = _Harness();
      final peer = _peer(2);
      final frame = jsonEncode({
        'v': 1,
        'ts': 111,
        'e': [_inviteUri(2)],
      });
      // First joined dial "brings the session up".
      h.messaging.onP2PEndpoints!(peer, frame);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.joined, hasLength(1));
      h.admitted = true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Replied with our endpoints (symmetric warm-up).
      expect(h.messaging.sentEndpoints, hasLength(1));
      expect(h.svc.knownEndpoints(peer), hasLength(1));
    },
  );

  test('inbound frame: denied policy means no dial and no reply', () async {
    final h = _Harness(allows: false);
    final peer = _peer(2);
    h.messaging.onP2PEndpoints!(
      peer,
      jsonEncode({
        'v': 1,
        'ts': 5,
        'e': [_inviteUri(2)],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.joined, isEmpty);
    expect(h.messaging.sentEndpoints, isEmpty);
    expect(h.svc.knownEndpoints(peer), isEmpty);
  });

  test(
    'inbound frame: an endpoint naming a THIRD party is never dialed, the '
    "peer's own endpoint after it still is",
    () async {
      final h = _Harness();
      final peer = _peer(2);
      final foreign = _inviteUri(77, host: '192.168.1.66');
      final own = _inviteUri(2);
      // An ACCEPTED contact — transport admission proves only that — offers a
      // stranger's identity/address first, then its own.
      h.messaging.onP2PEndpoints!(
        peer,
        jsonEncode({
          'v': 1,
          'ts': 1,
          'e': [foreign, own],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // The foreign candidate was skipped, not merely deferred; the peer's own
      // candidate was still redeemed (skip must not abort the whole dial).
      expect(h.joined, [own]);
      h.admitted = true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(h.joined, [own]);
    },
  );

  test(
    'inbound frame: an unparseable endpoint is dropped, not dialed',
    () async {
      final h = _Harness();
      final peer = _peer(2);
      h.messaging.onP2PEndpoints!(
        peer,
        jsonEncode({
          'v': 1,
          'ts': 1,
          'e': ['tcp://192.168.1.66:9000'], // bare address, no identity at all
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.joined, isEmpty);
    },
  );

  test('inbound frame: stale ts never regresses newer endpoints', () async {
    final h = _Harness();
    h.admitted = true; // no dial loops — isolate the fold logic
    final peer = _peer(3);
    String frame(int ts, String host) => jsonEncode({
      'v': 1,
      'ts': ts,
      'e': [_inviteUri(3, host: host)],
    });
    h.messaging.onP2PEndpoints!(peer, frame(200, '192.168.1.20'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.messaging.onP2PEndpoints!(peer, frame(100, '192.168.1.10'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.svc.knownEndpoints(peer).single, contains('192.168.1.20'));
  });

  test('ensureReady is true immediately on an admitted session', () async {
    final h = _Harness()..admitted = true;
    expect(await h.svc.ensureReady(_peer(4)), isTrue);
  });

  test('ensureReady dials known endpoints and reports within budget', () async {
    final h = _Harness();
    final peer = _peer(5);
    h.messaging.onP2PEndpoints!(
      peer,
      jsonEncode({
        'v': 1,
        'ts': 1,
        'e': [_inviteUri(5)],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.admitted = true; // the dial "landed"
    expect(
      await h.svc.ensureReady(peer, budget: const Duration(milliseconds: 400)),
      isTrue,
    );

    h.admitted = false;
    expect(
      await h.svc.ensureReady(
        _peer(6),
        budget: const Duration(milliseconds: 200),
      ),
      isFalse,
    );
  });

  test('ensureReady is false without consent', () async {
    final h = _Harness(allows: false)..admitted = true;
    expect(await h.svc.ensureReady(_peer(7)), isFalse);
  });

  // ── Strict call-time dial ladder (real-P2P Stage B) ──────────────────────

  test(
    'ensureReady admitted short-circuits before any dial or punch, and '
    'force-reshares with a reshare request',
    () async {
      final h = _Harness(injectPunch: true)..admitted = true;
      final peer = _peer(8);
      expect(await h.svc.ensureReady(peer), isTrue);
      // Neither the host dial nor the punch runs when a session already exists.
      expect(h.joined, isEmpty);
      expect(h.punchCalls, isEmpty);
      expect(h.svc.lastFallbackReason(peer), isNull);
      // The forced reshare is unawaited — let it flush, then assert it went out
      // with the mutual reshare-request flag set.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.messaging.sentEndpoints, hasLength(1));
      final body = jsonDecode(h.messaging.sentEndpoints.single.$2) as Map;
      expect(body['r'], 1);
    },
  );

  test('ensureReady force-reshares at call time even inside the throttle', () async {
    final h = _Harness(injectPunch: true);
    final peer = _peer(9);
    // Prime the throttle: a normal share was just sent.
    await h.svc.maybeShare(peer);
    expect(h.messaging.sentEndpoints, hasLength(1));
    // A call-time ensureReady must reshare anyway (bypass throttle) and mark
    // the frame so the peer reshares too — the Stage B one-sided-exchange fix.
    await h.svc.ensureReady(peer, budget: const Duration(milliseconds: 1));
    expect(h.messaging.sentEndpoints.length, greaterThanOrEqualTo(2));
    final body = jsonDecode(h.messaging.sentEndpoints.last.$2) as Map;
    expect(body['r'], 1);
  });

  test(
    'ensureReady runs the explicit punch before relay and records the reason',
    () async {
      final h = _Harness(
        injectPunch: true,
        punchResult: (connected: false, reason: 'no NAT reflector'),
      );
      final peer = _peer(10);
      final ok = await h.svc.ensureReady(
        peer,
        budget: const Duration(milliseconds: 1),
      );
      expect(ok, isFalse);
      // The punch was attempted (before falling back to relay) for this peer.
      expect(h.punchCalls, hasLength(1));
      expect(h.punchCalls.single, peer.bytes);
      // Structured, address-free reason is available for the badge / log.
      expect(h.svc.lastFallbackReason(peer), 'no NAT reflector');
    },
  );

  test('ensureReady returns true when the explicit punch connects', () async {
    final h = _Harness(
      injectPunch: true,
      punchResult: (connected: true, reason: 'direct session up'),
    );
    final peer = _peer(11);
    final ok = await h.svc.ensureReady(
      peer,
      budget: const Duration(milliseconds: 1),
    );
    expect(ok, isTrue);
    expect(h.punchCalls, hasLength(1));
    expect(h.svc.lastFallbackReason(peer), isNull);
  });

  test('ensureReady skips the punch when the host/LAN dial admits first', () async {
    final h = _Harness(injectPunch: true, admitOnJoin: true);
    final peer = _peer(12);
    // The peer shared a dialable endpoint; redeeming it "brings the session up".
    h.messaging.onP2PEndpoints!(
      peer,
      jsonEncode({
        'v': 1,
        'ts': 1,
        'e': [_inviteUri(12)],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // admitOnJoin already flipped admitted via the inbound dial; ensureReady
    // must short-circuit at rung 1 without ever reaching the punch.
    final ok = await h.svc.ensureReady(peer);
    expect(ok, isTrue);
    expect(h.punchCalls, isEmpty);
  });

  test('ensureReady without a punch adapter falls back to relay cleanly', () async {
    // No punch injected (loopback/dev stack): the ladder ends at relay with a
    // generic reason, never throwing.
    final h = _Harness(injectPunch: false);
    final peer = _peer(13);
    final ok = await h.svc.ensureReady(
      peer,
      budget: const Duration(milliseconds: 1),
    );
    expect(ok, isFalse);
    expect(h.punchCalls, isEmpty);
    expect(h.svc.lastFallbackReason(peer), 'direct session unavailable');
  });

  test('inbound frame with reshare request forces a reply past the throttle', () async {
    final h = _Harness();
    final peer = _peer(14);
    h.admitted = true; // isolate the reply path from dial loops
    // Prime the throttle with a normal share.
    await h.svc.maybeShare(peer);
    expect(h.messaging.sentEndpoints, hasLength(1));
    // A throttled frame (no 'r') within the window: reply is suppressed.
    h.messaging.onP2PEndpoints!(
      peer,
      jsonEncode({
        'v': 1,
        'ts': 10,
        'e': ['veil:bootstrap?pk=AAAA&t=tcp://192.168.1.9:9000&a=ed25519&nc=BB'],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.messaging.sentEndpoints, hasLength(1), reason: 'throttled reply');
    // A reshare-requested frame forces a fresh reply despite the throttle.
    h.messaging.onP2PEndpoints!(
      peer,
      jsonEncode({
        'v': 1,
        'ts': 11,
        'r': 1,
        'e': ['veil:bootstrap?pk=AAAA&t=tcp://192.168.1.9:9000&a=ed25519&nc=BB'],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.messaging.sentEndpoints, hasLength(2), reason: 'forced reply');
    // The forced reply does NOT re-request a reshare (settles in one round).
    final reply = jsonDecode(h.messaging.sentEndpoints.last.$2) as Map;
    expect(reply.containsKey('r'), isFalse);
  });
}

/// The messaging warm — the link that gives a CONVERSATION a direct route.
///
/// Until this existed the ladder was reachable only from `call_service`, so no
/// chat ever had a direct session and every message went through the mailbox.
/// The gate is per contact and defaults to off, so the tests below are as much
/// about what it must NOT do.
void _messagingWarmTests() {
  test('no opt-in for the contact ⇒ the ladder never runs', () async {
    final h = _Harness()..messagingAllows = false;
    await h.svc.warmForMessaging(_peer(0x21));
    expect(
      h.messaging.sentEndpoints,
      isEmpty,
      reason: 'a conversation with no per-contact opt-in must not so much as '
          'share an endpoint — that address is the whole privacy cost',
    );
    expect(h.joined, isEmpty);
  });

  test('opted in ⇒ the ladder runs and shares endpoints', () async {
    final h = _Harness()..messagingAllows = true;
    await h.svc.warmForMessaging(_peer(0x22));
    expect(
      h.messaging.sentEndpoints,
      hasLength(1),
      reason: 'the ladder starts with a forced mutual endpoint exchange',
    );
  });

  test('an existing direct session is left alone', () async {
    final h = _Harness()
      ..messagingAllows = true
      ..admitted = true;
    await h.svc.warmForMessaging(_peer(0x23));
    expect(
      h.messaging.sentEndpoints,
      isEmpty,
      reason: 'already direct — re-running the ladder would reshare endpoints '
          'on a schedule the peer never asked for',
    );
  });

  test('the ladder is throttled per peer, not run per frame', () async {
    final h = _Harness()..messagingAllows = true;
    final peer = _peer(0x24);
    await h.svc.warmForMessaging(peer);
    final afterFirst = h.messaging.sentEndpoints.length;
    expect(afterFirst, 1);

    // A conversation puts many frames through the same egress point.
    for (var i = 0; i < 5; i++) {
      await h.svc.warmForMessaging(peer);
    }
    expect(
      h.messaging.sentEndpoints,
      hasLength(afterFirst),
      reason: 'every ack, receipt and message goes through the same call — the '
          'ladder must not follow each one',
    );

    // Past the window it may try again: a warm that found nothing should get
    // another go within the life of a conversation.
    h.now = h.now.add(const Duration(minutes: 3));
    await h.svc.warmForMessaging(peer);
    expect(h.messaging.sentEndpoints, hasLength(afterFirst + 1));
  });

  test('a different peer is not throttled by the first', () async {
    final h = _Harness()..messagingAllows = true;
    await h.svc.warmForMessaging(_peer(0x25));
    await h.svc.warmForMessaging(_peer(0x26));
    expect(h.messaging.sentEndpoints, hasLength(2));
  });
}
