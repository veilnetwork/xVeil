import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/transport/veil_flutter_transport.dart';
import 'messaging.dart';
import 'p2p_policy_controller.dart';
import 'providers.dart';

/// P2P direct-session establishment, app side (real-P2P epic, layer 1+2).
///
/// The native admission gate (`veil_media_open_direct_channel` →
/// `peer_pnet_status().admitted`) honestly requires a live direct session —
/// this service builds the missing layer that ESTABLISHES one:
///
///  1. Mints this device's direct-dial endpoints — one `veil:bootstrap?...`
///     URI per private LAN address, carrying our pubkey+nonce and
///     `tcp://<ip>:<listenPort>` — and shares them with an ACCEPTED contact
///     over the existing E2E channel ([MessagingService.sendP2PEndpoints]).
///     Never published to DHT/ads; never sent when the local P2P policy
///     forbids that peer; nothing is shared while the node listener is
///     loopback-only ([lanListenEnabled] false — nobody could dial us).
///  2. On a contact's endpoints frame: re-checks the LOCAL policy (mutual
///     consent — transport admission only proved "accepted contact"), replies
///     with our endpoints (throttled), and dials theirs via the standard
///     bootstrap-join path. A successful dial in EITHER direction registers a
///     live session on both nodes, flipping `admitted` everywhere.
///  3. [ensureReady] is the call-time gate: kick an exchange + dial and poll
///     `admitted` inside a small budget so the transport negotiation can
///     honestly offer p2p when a direct session actually exists.
///
/// NAT traversal (hole punching) is the next layer; today a dial succeeds when
/// the peer is reachable (same LAN / public address).
class P2PEndpointService {
  P2PEndpointService(
    this._messaging, {
    required this._localAllowsP2P,
    required this._joinEndpoint,
    required this._pnetStatus,
    required this._myIdentity,
    required this._listenPort,
    required this._listenScheme,
    required this._lanListenEnabled,
    Future<List<String>> Function()? localAddresses,
    this._listenTransports,
    DateTime Function()? now,
  }) : _localAddresses = localAddresses ?? _defaultLocalAddresses,
       _now = now ?? DateTime.now;

  final MessagingService _messaging;
  final Future<bool> Function(NodeId peer) _localAllowsP2P;
  final Future<void> Function(String uri) _joinEndpoint;
  final Future<({bool admitted, bool hasCert})> Function(Uint8List peer)
  _pnetStatus;
  final BootstrapInvite Function() _myIdentity;
  final int Function() _listenPort;
  final String Function() _listenScheme;
  final bool Function() _lanListenEnabled;
  final Future<List<String>> Function() _localAddresses;

  /// Daemon listener-URI snapshot (null when the running stack can't provide
  /// one — loopback/dev transport). After the node's server-reflexive NAT
  /// probe the wildcard listener host is rewritten to the observed external
  /// IP, which is where the srflx endpoint candidate comes from (Stage B).
  final Future<List<String>> Function()? _listenTransports;
  final DateTime Function() _now;

  /// Newest endpoint URIs a peer shared with us (in-memory; endpoints are
  /// ephemeral runtime facts, not durable contact state).
  final Map<String, List<String>> _peerEndpoints = {};

  /// ts of the newest applied frame per peer — re-drives/out-of-order folds
  /// strictly newer, so a stale mailbox delivery can't regress fresh addresses.
  final Map<String, int> _peerEndpointTs = {};

  /// Last time we SENT our endpoints to a peer (reply throttle).
  final Map<String, DateTime> _lastSharedAt = {};

  /// Per-peer in-flight dial guard.
  final Set<String> _dialing = {};

  void Function(NodeId, String)? _handler;
  bool _started = false;

  static const _shareThrottle = Duration(minutes: 3);
  static const _maxEndpointsPerFrame = 4;

  void start() {
    if (_started) return;
    _started = true;
    _handler = _onFrame;
    _messaging.onP2PEndpoints = _handler;
  }

  void dispose() {
    if (_messaging.onP2PEndpoints == _handler) {
      _messaging.onP2PEndpoints = null;
    }
  }

  /// Peer endpoints currently known (diagnostics/debug hook).
  List<String> knownEndpoints(NodeId peer) =>
      List.unmodifiable(_peerEndpoints[peer.hex] ?? const []);

  /// Share our direct endpoints with [peer] if policy + posture allow.
  /// Throttled per peer unless [force].
  Future<void> maybeShare(NodeId peer, {bool force = false}) async {
    if (!_lanListenEnabled()) return; // loopback bind — nothing dialable
    if (!await _localAllowsP2P(peer)) return;
    final at = _lastSharedAt[peer.hex];
    final now = _now();
    if (!force && at != null && now.difference(at) < _shareThrottle) return;
    final uris = await _mintLocalUris();
    if (uris.isEmpty) return;
    _lastSharedAt[peer.hex] = now;
    final ts = now.millisecondsSinceEpoch;
    final body = jsonEncode({'v': 1, 'ts': ts, 'e': uris});
    await _messaging.sendP2PEndpoints(peer, body, sentAtMs: ts);
  }

  /// Call-time gate: make "peer reachable for P2P" mean "a live direct session
  /// exists (or came up within [budget])". Kicks a share+dial as a side
  /// effect, so even a `false` now warms the path for the next attempt.
  Future<bool> ensureReady(
    NodeId peer, {
    Duration budget = const Duration(milliseconds: 2500),
  }) async {
    if (!await _localAllowsP2P(peer)) return false;
    if (await _admitted(peer)) {
      // Fresh addresses for the peer's own dial/renewal, off the hot path.
      unawaited(maybeShare(peer));
      return true;
    }
    unawaited(maybeShare(peer));
    unawaited(_dialPeer(peer));
    // Real elapsed time, not the injectable wall clock: the poll below is
    // bounded by actual delays, and a frozen test clock must not turn the
    // budget into an infinite loop.
    final sw = Stopwatch()..start();
    while (sw.elapsed < budget) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (await _admitted(peer)) return true;
    }
    return false;
  }

  Future<bool> _admitted(NodeId peer) async {
    try {
      final s = await _pnetStatus(peer.bytes);
      return s.admitted;
    } catch (e) {
      devLog(() => 'xVeil[p2p]: pnet status failed for ${peer.short}: $e');
      return false;
    }
  }

  /// Inbound endpoints frame from an accepted contact. Mutual consent: OUR
  /// policy decides whether we act at all (dial + reply); a denied peer's
  /// frame is dropped without an answer (no policy oracle for the sender —
  /// silence is indistinguishable from an older build).
  void _onFrame(NodeId peer, String bodyJson) {
    unawaited(() async {
      if (!await _localAllowsP2P(peer)) return;
      List<String> uris;
      int ts;
      try {
        final m = jsonDecode(bodyJson);
        if (m is! Map || m['v'] != 1) return;
        ts = (m['ts'] as num?)?.toInt() ?? 0;
        uris = [
          for (final e in (m['e'] as List? ?? const []))
            if (e is String && e.isNotEmpty) e,
        ];
      } catch (_) {
        return;
      }
      if (uris.isEmpty || uris.length > _maxEndpointsPerFrame) return;
      final prevTs = _peerEndpointTs[peer.hex] ?? 0;
      if (ts <= prevTs) return; // stale re-drive/out-of-order
      _peerEndpointTs[peer.hex] = ts;
      _peerEndpoints[peer.hex] = uris;
      devLog(
        () =>
            'xVeil[p2p]: peer ${peer.short} shared ${uris.length} '
            'endpoint(s)',
      );
      // Symmetric warm-up: answer with ours (throttled), then dial theirs.
      unawaited(maybeShare(peer));
      await _dialPeer(peer);
    }());
  }

  /// Redeem the peer's endpoint URIs until a direct session is admitted.
  /// Single-flight per peer; each URI gets a short admitted-poll window (the
  /// node keeps re-dialing registered peers in the background afterwards).
  Future<void> _dialPeer(NodeId peer) async {
    final key = peer.hex;
    final uris = _peerEndpoints[key];
    if (uris == null || uris.isEmpty) return;
    if (!_dialing.add(key)) return;
    try {
      for (final uri in uris) {
        if (await _admitted(peer)) return;
        try {
          await _joinEndpoint(uri);
        } catch (e) {
          devLog(() => 'xVeil[p2p]: join failed for ${peer.short}: $e');
          continue;
        }
        // Give this candidate a moment to hand-shake before the next one
        // overwrites the stored transport (repeat joins refresh + re-dial).
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (await _admitted(peer)) {
            devLog(() => 'xVeil[p2p]: direct session up with ${peer.short}');
            return;
          }
        }
      }
    } finally {
      _dialing.remove(key);
    }
  }

  /// Build one bootstrap URI per usable local address: identity (pubkey +
  /// nonce + algo) from the running stack, transport `tcp://<ip>:<port>`.
  ///
  /// Stage B: additionally append the server-reflexive candidate — the
  /// node's own listener as rewritten by the srflx NAT probe
  /// (`tcp://<observed external ip>:<listenPort>`). LAN candidates stay
  /// FIRST so a same-network peer dials the cheap route before trying the
  /// external one. A bare dial to the external address works for
  /// port-forwarded / full-cone NATs; symmetric/CGNAT still needs the punch
  /// layer and falls back to relay honestly.
  Future<List<String>> _mintLocalUris() async {
    final port = _listenPort();
    if (port <= 0) return const [];
    final scheme = _listenScheme();
    if (scheme != 'tcp' && scheme != 'quic') return const [];
    final identity = _myIdentity();
    final addrs = await _localAddresses();
    final srflx = await _srflxAddresses(
      port,
      scheme: scheme,
      exclude: addrs.toSet(),
    );
    final transports = [
      for (final ip in addrs) '$scheme://$ip:$port',
      for (final ip in srflx) '$scheme://$ip:$port',
    ];
    return [
      for (final t in transports.take(_maxEndpointsPerFrame))
        BootstrapInvite(
          publicKey: identity.publicKey,
          nonce: identity.nonce,
          algo: identity.algo,
          transport: t,
        ).toUri(),
    ];
  }

  /// Public IPv4 hosts of our own listener as the daemon currently
  /// advertises it — non-empty only after the node's srflx probe rewrote
  /// the wildcard listener host to the observed external IP.
  Future<List<String>> _srflxAddresses(
    int listenPort, {
    required String scheme,
    required Set<String> exclude,
  }) async {
    final query = _listenTransports;
    if (query == null) return const [];
    List<String> uris;
    try {
      uris = await query();
    } catch (e) {
      devLog(() => 'xVeil[p2p]: listen transports unavailable: $e');
      return const [];
    }
    final out = <String>[];
    for (final uri in uris) {
      // `srflx://ip:port` = raw observed external address (the port is the
      // probe session's NAT mapping — we substitute our own listen port).
      // `<scheme>://ip:<listenPort>` = an operator-advertised listener that
      // happens to be ours; usable verbatim without changing TCP/QUIC.
      final srflx = RegExp(r'^srflx://([0-9.]+):\d+$').firstMatch(uri);
      final advertised = RegExp(
        '^${RegExp.escape(scheme)}://([0-9.]+):(\\d+)\$',
      ).firstMatch(uri);
      final String host;
      if (srflx != null) {
        host = srflx.group(1)!;
      } else if (advertised != null &&
          int.tryParse(advertised.group(2)!) == listenPort) {
        host = advertised.group(1)!;
      } else {
        continue;
      }
      if (host == '0.0.0.0' ||
          host.startsWith('127.') ||
          _isPrivateV4(host) ||
          exclude.contains(host) ||
          out.contains(host)) {
        continue;
      }
      out.add(host);
    }
    return out;
  }

  /// Private (RFC1918) IPv4 addresses of this device's live interfaces —
  /// the LAN-dialable set. Cellular/carrier-NAT and public addresses are
  /// excluded for now: without hole punching a bare dial to them can't work,
  /// and each extra URI costs the receiver a dial-poll window.
  static Future<List<String>> _defaultLocalAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final out = <String>[];
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          if (_isPrivateV4(a.address)) out.add(a.address);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static bool _isPrivateV4(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}

/// The endpoint service for the ACTIVE identity's messaging pipeline. Null when
/// the real stack isn't up (loopback/dev transport) — call negotiation then
/// falls back to the native admission gate alone, as before this epic.
final p2pEndpointServiceProvider = Provider<P2PEndpointService?>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  final transport = ref.read(veilTransportProvider);
  final stack = ref.watch(realStackProvider);
  if (transport is! VeilFlutterTransport || stack == null) return null;
  final svc = P2PEndpointService(
    messaging,
    localAllowsP2P: (peer) =>
        ref.read(p2pPolicyProvider.notifier).allowsPeer(peer),
    joinEndpoint: transport.joinP2PEndpoint,
    pnetStatus: transport.peerPnetStatus,
    myIdentity: () => stack.myInvite,
    listenPort: () => stack.listenPort,
    listenScheme: () => stack.listenScheme,
    lanListenEnabled: () => stack.lanListen,
    listenTransports: transport.listenTransports,
  )..start();
  ref.onDispose(svc.dispose);
  return svc;
});
