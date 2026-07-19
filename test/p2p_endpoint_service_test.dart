import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/state/messaging_core.dart';
import 'package:xveil/state/p2p_endpoint_service.dart';

NodeId _peer(int fill) => NodeId(Uint8List.fromList(List.filled(32, fill)));

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
  }) : addresses = addresses ?? ['192.168.1.70', '10.0.0.5'] {
    svc; // force the late-final service (attaches onP2PEndpoints)
  }

  final _FakeMessaging messaging = _FakeMessaging();
  bool allows;
  bool lanListen;
  List<String> addresses;
  List<String>? listenTransports;
  String listenScheme;
  bool admitted = false;
  final List<String> joined = [];
  DateTime now = DateTime.utc(2026, 7, 18, 12);

  late final P2PEndpointService svc = P2PEndpointService(
    messaging,
    localAllowsP2P: (_) async => allows,
    joinEndpoint: (uri) async => joined.add(uri),
    pnetStatus: (_) async => (admitted: admitted, hasCert: false),
    myIdentity: _identity,
    listenPort: () => 9000,
    listenScheme: () => listenScheme,
    lanListenEnabled: () => lanListen,
    localAddresses: () async => addresses,
    listenTransports: listenTransports == null
        ? null
        : () async => listenTransports!,
    now: () => now,
  )..start();
}

void main() {
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
        'e': [
          'veil:bootstrap?pk=AAAA&t=tcp://192.168.1.9:9000&a=ed25519&nc=BB',
        ],
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
        'e': [
          'veil:bootstrap?pk=AAAA&t=tcp://192.168.1.9:9000&a=ed25519&nc=BB',
        ],
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.joined, isEmpty);
    expect(h.messaging.sentEndpoints, isEmpty);
    expect(h.svc.knownEndpoints(peer), isEmpty);
  });

  test('inbound frame: stale ts never regresses newer endpoints', () async {
    final h = _Harness();
    h.admitted = true; // no dial loops — isolate the fold logic
    final peer = _peer(3);
    String frame(int ts, String host) => jsonEncode({
      'v': 1,
      'ts': ts,
      'e': ['veil:bootstrap?pk=AAAA&t=tcp://$host:9000&a=ed25519&nc=BB'],
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
        'e': [
          'veil:bootstrap?pk=AAAA&t=tcp://192.168.1.9:9000&a=ed25519&nc=BB',
        ],
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
}
