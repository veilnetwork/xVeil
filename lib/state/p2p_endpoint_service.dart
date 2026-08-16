import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_ffi.dart' show VeilHolePunchStatus;

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/transport/veil_flutter_transport.dart';
import 'group_service_providers.dart';
import 'messaging.dart';
import 'p2p_policy_controller.dart';
import 'providers.dart';

/// Outcome of one explicit call-path hole-punch attempt as the endpoint
/// service consumes it: whether a direct session came up, plus a short,
/// address-free reason (structured stage name) for the transport badge/log
/// when it did not.
typedef P2PPunchResult = ({bool connected, String reason});

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
    required this._messagingAllowsP2P,
    required this._joinEndpoint,
    required this._pnetStatus,
    required this._myIdentity,
    required this._listenPort,
    required this._listenScheme,
    required this._lanListenEnabled,
    Future<List<String>> Function()? localAddresses,
    Future<List<NodeId>> Function()? acceptedPeers,
    Future<bool> Function(NodeId peer)? isOwnDevice,
    Future<NodeId> Function()? selfNode,
    this._listenTransports,
    this._attemptHolePunch,
    DateTime Function()? now,
  }) : _localAddresses = localAddresses ?? _defaultLocalAddresses,
       _acceptedPeers = acceptedPeers ?? _noPeers,
       _isOwnDevice = isOwnDevice ?? _notOwnDevice,
       // ignore: prefer_initializing_formals — public `selfNode:` → private field.
       _selfNode = selfNode,
       _now = now ?? DateTime.now;

  static Future<bool> _notOwnDevice(NodeId peer) async => false;

  static Future<List<NodeId>> _noPeers() async => const [];

  final MessagingService _messaging;
  final Future<bool> Function(NodeId peer) _localAllowsP2P;

  /// The per-contact opt-in that governs [warmForMessaging] — STRICTER than
  /// [_localAllowsP2P] and separate from it on purpose, so that relaxing the
  /// call-path policy cannot quietly hand every conversation a direct route.
  final Future<bool> Function(NodeId peer) _messagingAllowsP2P;

  /// Is this node a device of MY OWN identity document? Gates the re-keying
  /// of endpoint candidates whose wire source is the identity itself (mail
  /// between my devices is sealed AS the identity) — see [_onFrame].
  final Future<bool> Function(NodeId peer) _isOwnDevice;

  /// The RUNNING NODE's transport id. On the master it equals the identity;
  /// on a sibling it does not, and that difference is what lets [_onFrame]
  /// tell "my own echo" from "the master's candidates" — both present the
  /// shared identity key. Null falls back to the identity invite's id.
  final Future<NodeId> Function()? _selfNode;
  final Future<void> Function(String uri) _joinEndpoint;
  final Future<({bool admitted, bool hasCert})> Function(Uint8List peer)
  _pnetStatus;
  final BootstrapInvite Function() _myIdentity;
  final int Function() _listenPort;
  final String Function() _listenScheme;
  final bool Function() _lanListenEnabled;

  /// Contacts to tell when our own address changes. Injected rather than read
  /// from storage here so the service stays a pure negotiator.
  final Future<List<NodeId>> Function() _acceptedPeers;
  final Future<List<String>> Function() _localAddresses;

  /// Explicit call-path hole punch (real-P2P Stage B). Runs one bounded
  /// native attempt toward the peer and reports whether a direct session
  /// came up plus a short, address-free reason. Null when the running stack
  /// can't punch (loopback/dev transport) — the ladder then skips straight
  /// to relay. Injected so tests can drive the ladder with a mock.
  final Future<P2PPunchResult> Function(Uint8List peer)? _attemptHolePunch;

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

  /// Short, address-free reason the last [ensureReady] ladder fell back to
  /// relay for a peer (structured hole-punch outcome / stage name). Read by
  /// the transport-badge/log layer; cleared when a direct session comes up.
  final Map<String, String> _fallbackReason = {};

  /// Last time the MESSAGING warm ran the ladder for a peer. Separate from
  /// [_lastSharedAt]: that throttles one frame, this throttles the whole
  /// ladder, which reshares, dials and punches.
  final Map<String, DateTime> _lastWarmAt = {};

  void Function(NodeId, String)? _handler;
  bool _started = false;

  static const _shareThrottle = Duration(minutes: 3);

  /// How often a conversation may re-run the ladder toward one peer. A chat
  /// sends many frames — acks, receipts, typing — through the same egress, and
  /// the ladder is expensive on both ends. Shorter than [_shareThrottle]
  /// because a warm that finds nothing should get another go within the life of
  /// a conversation, not three minutes later.
  static const _warmThrottle = Duration(minutes: 2);
  static const _maxEndpointsPerFrame = 4;

  /// Host/LAN-dial slice of the call-time ladder: how long to poll for the
  /// cheap same-network dial to admit a session before escalating to the
  /// explicit hole punch. Kept short so the punch (up to its own ~5 s daemon
  /// budget) still fits inside the call FSM's signaling window.
  static const _hostDialWindow = Duration(milliseconds: 1500);

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

  /// Why the last call-time [ensureReady] for [peer] settled on relay, as a
  /// short address-free phrase (structured hole-punch outcome / stage), or
  /// null when the direct route is up / was never attempted. Fed into the
  /// transport-badge/log layer; never carries peer addresses.
  String? lastFallbackReason(NodeId peer) => _fallbackReason[peer.hex];

  /// Share our direct endpoints with [peer] if policy + posture allow.
  /// Throttled per peer unless [force]. When [requestReshare] is set the
  /// frame asks the receiver to reply with FRESH endpoints even inside its
  /// own throttle window — call-time exchange must be mutual (a one-sided
  /// exchange, the receiver's throttled non-reply, was the Stage B bug).
  Future<void> maybeShare(
    NodeId peer, {
    bool force = false,
    bool requestReshare = false,
  }) async {
    if (!_lanListenEnabled()) return; // loopback bind — nothing dialable
    if (!await _localAllowsP2P(peer)) return;
    final at = _lastSharedAt[peer.hex];
    final now = _now();
    if (!force && at != null && now.difference(at) < _shareThrottle) return;
    final uris = await _mintLocalUris();
    if (uris.isEmpty) return;
    _lastSharedAt[peer.hex] = now;
    final ts = now.millisecondsSinceEpoch;
    final body = jsonEncode({
      'v': 1,
      'ts': ts,
      'e': uris,
      if (requestReshare) 'r': 1,
    });
    await _messaging.sendP2PEndpoints(peer, body, sentAtMs: ts);
  }

  /// Tell every accepted contact where to find us, because we just moved.
  ///
  /// A node reboot — the anonymity switch, an identity change, a routing change
  /// — does not come back on the same port: `_teardownRealStack` alternates the
  /// listen offset deliberately, so the next boot never rebinds a port still in
  /// lingering teardown. Every peer's cached endpoint for us is therefore wrong
  /// the moment we come back, and nothing used to say so. They found out only
  /// when something else happened to run the ladder, and until then a direct
  /// route could not be dialed in either direction.
  ///
  /// Nothing else fills this gap. [warmForMessaging] returns early when
  /// [_admitted] is true, and admitted means "some live session exists" — which
  /// it does, over the relay — so the conversation path never reshares. The
  /// call path does force a reshare, but only once a call is already being
  /// placed, which is exactly when there is no time left to recover.
  ///
  /// Forced past the share throttle, since the address really did change.
  /// [requestReshare] because the peer's own view is symmetric: it wants ours,
  /// we want its. [max] bounds the boot burst on a large roster; the rest keep
  /// the ordinary path (a share on their next ladder run).
  Future<void> announceLocalEndpoints({int max = 32}) async {
    if (!_lanListenEnabled()) return; // loopback bind — nothing dialable
    final List<NodeId> peers;
    try {
      peers = await _acceptedPeers();
    } catch (e) {
      devLog(() => 'xVeil[p2p]: could not list contacts to announce to: $e');
      return;
    }
    if (peers.isEmpty) return;
    devLog(
      () =>
          'xVeil[p2p]: announcing our endpoints to '
          '${peers.length > max ? max : peers.length} contact(s) after node boot',
    );
    for (final peer in peers.take(max)) {
      try {
        await maybeShare(peer, force: true, requestReshare: true);
      } catch (e) {
        // One unreachable contact must not stop the rest being told.
        devLog(() => 'xVeil[p2p]: announce to ${peer.short} failed: $e');
      }
    }
  }

  /// Messaging entry to the ladder — the reason a conversation can ever get a
  /// direct route at all. [ensureReady] is the CALL path: it must answer now,
  /// so the caller waits on it. A chat must not wait on anything, so this is
  /// fire-and-forget and returns nothing: the message it rode in on still goes
  /// out the way it always did, and it is the NEXT one that benefits.
  ///
  /// Order matters. The throttle is checked first and in memory, so the steady
  /// state of a busy conversation is one map lookup per frame — the policy read
  /// hits storage and [_admitted] crosses the FFI, and neither belongs on the
  /// path of every ack and receipt.
  ///
  /// [messagingAllowsP2P] is the per-contact opt-in, NOT the global policy the
  /// call path uses. See `p2pMessagingAllows`.
  Future<void> warmForMessaging(NodeId peer) async {
    if (!_lanListenEnabled()) return; // loopback bind — nothing dialable
    final last = _lastWarmAt[peer.hex];
    final now = _now();
    if (last != null && now.difference(last) < _warmThrottle) return;
    // Stamp BEFORE the awaits: two frames leaving back to back would otherwise
    // both pass the check and run the ladder twice.
    _lastWarmAt[peer.hex] = now;
    try {
      if (!await _messagingAllowsP2P(peer)) return;
      // Already direct — nothing to warm, and re-running the ladder here would
      // reshare endpoints on a schedule the peer never asked for.
      if (await _admitted(peer)) return;
      devLog(
        () =>
            'xVeil[p2p]: messaging warm — running the ladder for '
            '${peer.short}',
      );
      final ok = await ensureReady(peer);
      devLog(
        () =>
            'xVeil[p2p]: messaging warm for ${peer.short} '
            '${ok ? "got a direct session" : "stayed on the relay path"}',
      );
    } catch (e) {
      // Best-effort by construction: the conversation is already delivering
      // over the mailbox, and a warm that throws must not touch that.
      devLog(() => 'xVeil[p2p]: messaging warm for ${peer.short} failed: $e');
    }
  }

  /// Call-time gate: make "peer reachable for P2P" mean "a live direct session
  /// exists (or came up within the ladder)". Strict ladder, escalating only
  /// when the cheaper rung fails, matching the Stage B design order:
  ///
  ///   existing admitted → host/LAN dial → explicit hole punch → relay.
  ///
  /// Call-time exchange bypasses the 3-minute share throttle on BOTH sides
  /// (forced reshare + reshare-request flag), so the peer always has fresh
  /// endpoints to dial back. A relay fallback records a short, address-free
  /// reason ([lastFallbackReason]); a side-effect punch keeps running
  /// daemon-side even past [budget], warming the direct route for the next
  /// attempt. Anonymity never reaches here — [_localAllowsP2P] denies P2P
  /// for an anonymous local identity, and the daemon refuses a punch under
  /// an onion-service posture regardless.
  Future<bool> ensureReady(
    NodeId peer, {
    Duration budget = const Duration(milliseconds: 2500),
  }) async {
    if (!await _localAllowsP2P(peer)) return false;

    // Rung 1 — existing admitted session short-circuits (idempotent). Still
    // force a mutual reshare so the peer's own renewal has fresh endpoints.
    if (await _admitted(peer)) {
      _fallbackReason.remove(peer.hex);
      unawaited(maybeShare(peer, force: true, requestReshare: true));
      return true;
    }

    // Force a mutual, throttle-bypassing endpoint exchange before dialing:
    // both sides must reshare fresh endpoints at call time.
    await maybeShare(peer, force: true, requestReshare: true);

    // Rung 2 — host/LAN dial: redeem the peer's shared endpoints (also
    // REGISTERS the peer with the daemon, a precondition for the punch) and
    // give the cheap same-network route a short window to admit.
    unawaited(_dialPeer(peer));
    // Real elapsed time, not the injectable wall clock: the poll is bounded
    // by actual delays, and a frozen test clock must not turn it into an
    // infinite loop.
    final hostSw = Stopwatch()..start();
    final hostWindow = budget < _hostDialWindow ? budget : _hostDialWindow;
    while (hostSw.elapsed < hostWindow) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (await _admitted(peer)) {
        _fallbackReason.remove(peer.hex);
        return true;
      }
    }

    // Rung 3 — explicit hole punch, BEFORE relay. Skipped only when the stack
    // can't punch (loopback/dev). The native attempt is bounded and single-
    // flight daemon-side; on success `admitted` flips the standard way.
    final punch = _attemptHolePunch;
    if (punch != null) {
      try {
        final result = await punch(peer.bytes);
        if (result.connected || await _admitted(peer)) {
          _fallbackReason.remove(peer.hex);
          return true;
        }
        _fallbackReason[peer.hex] = result.reason;
        devLog(
          () =>
              'xVeil[p2p]: hole punch for ${peer.short} did not connect '
              '(${result.reason})',
        );
      } catch (e) {
        _fallbackReason[peer.hex] = 'direct punch failed';
        devLog(() => 'xVeil[p2p]: hole punch failed for ${peer.short}: $e');
      }
    } else {
      _fallbackReason[peer.hex] = 'direct session unavailable';
    }

    // Rung 4 — relay fallback (the caller downgrades to relay). Reason stays
    // for the transport badge / log.
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
      // Every early exit names its reason in the dev log. The WIRE stays
      // silent for a denied peer (no policy oracle for the sender), but a
      // silent local drop already cost a live-stand session: both call-time
      // exchanges vanished without a trace and the call fell back to relay
      // (2026-07-24). The outer catch also covers a throwing policy/provider
      // read — an exception in this unawaited closure is otherwise invisible.
      try {
        if (!await _localAllowsP2P(peer)) {
          devLog(
            () =>
                'xVeil[p2p]: drop endpoints from ${peer.short} '
                '(local policy denies)',
          );
          return;
        }
        List<String> uris;
        int ts;
        bool reshareRequested;
        try {
          final m = jsonDecode(bodyJson);
          if (m is! Map || m['v'] != 1) {
            devLog(
              () =>
                  'xVeil[p2p]: drop endpoints from ${peer.short} '
                  '(unsupported frame version)',
            );
            return;
          }
          ts = (m['ts'] as num?)?.toInt() ?? 0;
          reshareRequested = m['r'] == 1;
          uris = [
            for (final e in (m['e'] as List? ?? const []))
              if (e is String && e.isNotEmpty) e,
          ];
        } catch (_) {
          devLog(
            () =>
                'xVeil[p2p]: drop endpoints from ${peer.short} '
                '(unparseable frame)',
          );
          return;
        }
        if (uris.isEmpty || uris.length > _maxEndpointsPerFrame) {
          devLog(
            () =>
                'xVeil[p2p]: drop endpoints from ${peer.short} '
                '(endpoint count ${uris.length})',
          );
          return;
        }
        // Group candidates by the device their invite PRESENTS. Ordinarily
        // that is [peer] itself and this makes one group. But mail between
        // my own devices is sealed AS the identity, so a sibling's share can
        // arrive carrying the identity's node id — MY OWN — as its wire
        // source; under the old single-key flow those candidates were stored
        // under a peer nobody would ever dial and then died one by one in
        // binding ("invite names …"). Re-keying is allowed ONLY toward a
        // device of my own identity document, from a sender that is my own
        // identity/device — a candidate naming any third party is dropped
        // exactly as before, so an accepted contact still cannot make us
        // dial a node we never chose.
        NodeId me;
        try {
          me = await _selfNode?.call() ?? _myIdentity().nodeId;
        } catch (_) {
          me = _myIdentity().nodeId;
        }
        final ownSender = peer == me || await _isOwnDevice(peer);
        if (!ownSender) {
          // The ordinary contact path, byte-for-byte as it always was:
          // stored under the wire source, candidate validity judged at dial
          // ([_invitePresents]), one symmetric reply to the sender.
          final prevTs = _peerEndpointTs[peer.hex] ?? 0;
          if (ts <= prevTs) {
            // stale re-drive/out-of-order
            devLog(
              () =>
                  'xVeil[p2p]: drop endpoints from ${peer.short} '
                  '(stale ts $ts <= $prevTs)',
            );
            return;
          }
          _peerEndpointTs[peer.hex] = ts;
          _peerEndpoints[peer.hex] = uris;
          devLog(
            () =>
                'xVeil[p2p]: peer ${peer.short} shared ${uris.length} '
                'endpoint(s)${reshareRequested ? ' (reshare requested)' : ''}',
          );
          // Symmetric warm-up: answer with ours (forced fresh when the peer
          // asked — call-time mutual exchange — else throttled), then dial
          // theirs. The reply never re-requests a reshare, so the exchange
          // settles in one round trip each way rather than ping-ponging.
          unawaited(maybeShare(peer, force: reshareRequested));
          await _dialPeer(peer);
          return;
        }
        // MY OWN identity/device sent this. Mail between my devices is
        // sealed AS the identity, so the wire source may be my own node id
        // and cannot key anything: under the old single-key flow a
        // sibling's candidates were stored under a peer nobody would ever
        // dial and then died one by one in binding ("invite names …").
        // Re-key each candidate by the node its invite PRESENTS — but only
        // toward my own identity document, so a candidate naming any third
        // party is dropped exactly as before.
        //
        // Two subtleties, both measured on the stand:
        // - "me" must be the TRANSPORT node id, not the identity invite's:
        //   on a sibling the two differ, and with the identity as "me" every
        //   candidate the master shared (they all present the shared
        //   identity key) was skipped as this node's own echo — twenty-eight
        //   drained shares processed in total silence.
        // - devices SHARE the identity key, so the presented id cannot tell
        //   a sibling's candidate from my own echoed one. The ADDRESS can:
        //   a candidate carrying one of the URIs this node currently mints
        //   is my own share coming back; any other address under the
        //   identity's key is a sibling worth dialing (the dial pins the
        //   identity key — exactly what the master presents).
        final Set<String> myCurrentUris;
        try {
          myCurrentUris = (await _mintLocalUris()).toSet();
        } catch (_) {
          return; // cannot tell echoes apart — better silent than self-dial
        }
        final deviceById = <String, NodeId>{};
        final urisById = <String, List<String>>{};
        for (final uri in uris) {
          final NodeId presented;
          try {
            presented = BootstrapInvite.parse(uri).nodeId;
          } catch (_) {
            devLog(
              () =>
                  'xVeil[p2p]: drop endpoint from ${peer.short} '
                  '(unparseable invite)',
            );
            continue;
          }
          if (myCurrentUris.contains(uri)) {
            // My own share, echoed back through the identity mailbox.
            continue;
          }
          if (presented == me) {
            // The shared identity key at an address that is not mine — a
            // sibling. Never dialed when it could be THIS node (see above).
            deviceById[presented.hex] = presented;
            (urisById[presented.hex] ??= []).add(uri);
            continue;
          }
          if (presented != peer && !await _isOwnDevice(presented)) {
            devLog(
              () =>
                  'xVeil[p2p]: drop endpoint from ${peer.short} '
                  '(invite names ${presented.short})',
            );
            continue;
          }
          deviceById[presented.hex] = presented;
          (urisById[presented.hex] ??= []).add(uri);
        }
        final stored = <NodeId>[];
        for (final entry in deviceById.entries) {
          final device = entry.value;
          final group = urisById[entry.key]!;
          final prevTs = _peerEndpointTs[device.hex] ?? 0;
          if (ts <= prevTs) {
            devLog(
              () =>
                  'xVeil[p2p]: drop endpoints from ${device.short} '
                  '(stale ts $ts <= $prevTs)',
            );
            continue;
          }
          _peerEndpointTs[device.hex] = ts;
          _peerEndpoints[device.hex] = List.unmodifiable(group);
          devLog(
            () =>
                'xVeil[p2p]: peer ${device.short} shared ${group.length} '
                'endpoint(s)${reshareRequested ? ' (reshare requested)' : ''}',
          );
          stored.add(device);
        }
        // The reply goes to each device that actually shared — replying to
        // the wire source would be replying to this node's own name when
        // the attribution collapsed.
        for (final device in stored) {
          unawaited(maybeShare(device, force: reshareRequested));
        }
        for (final device in stored) {
          await _dialPeer(device);
        }
      } catch (e) {
        devLog(
          () => 'xVeil[p2p]: endpoints frame from ${peer.short} failed: $e',
        );
      }
    }());
  }

  /// Redeem the peer's endpoint URIs until a direct session is admitted.
  /// Single-flight per peer; each URI gets a short admitted-poll window (the
  /// node keeps re-dialing registered peers in the background afterwards).
  ///
  /// Every candidate is bound to [peer] before it is joined: the invite's
  /// `node_id` (BLAKE3 of its public key) MUST be the peer whose frame carried
  /// it. Without that, an ACCEPTED contact — the only sender that reaches this
  /// path — could name a third party's identity/address and make us open a
  /// session with, and register, a node we never chose. The daemon's own join
  /// path already pins its issuer (`expected_issuer_pk`); this is the app-side
  /// half of the same admission.
  Future<void> _dialPeer(NodeId peer) async {
    final key = peer.hex;
    final uris = _peerEndpoints[key];
    if (uris == null || uris.isEmpty) return;
    if (!_dialing.add(key)) return;
    try {
      for (final uri in uris) {
        if (await _admitted(peer)) return;
        if (!_invitePresents(uri, peer)) continue;
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

  /// Whether [uri] is a parseable bootstrap invite that presents [peer]'s own
  /// identity. An unparseable or foreign-identity candidate is dropped with a
  /// named, address-free reason — never dialed.
  bool _invitePresents(String uri, NodeId peer) {
    final NodeId presented;
    try {
      presented = BootstrapInvite.parse(uri).nodeId;
    } catch (_) {
      devLog(
        () =>
            'xVeil[p2p]: drop endpoint from ${peer.short} '
            '(unparseable invite)',
      );
      return false;
    }
    if (presented != peer) {
      devLog(
        () =>
            'xVeil[p2p]: drop endpoint from ${peer.short} '
            '(invite names ${presented.short})',
      );
      return false;
    }
    return true;
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
    messagingAllowsP2P: (peer) =>
        ref.read(p2pPolicyProvider.notifier).allowsMessagingPeer(peer),
    isOwnDevice: (peer) async =>
        await ref.read(groupServiceProvider)?.isMyDevice(peer) ?? false,
    selfNode: () => transport.nodeId(),
    joinEndpoint: transport.joinP2PEndpoint,
    pnetStatus: transport.peerPnetStatus,
    myIdentity: () => stack.myInvite,
    listenPort: () => stack.listenPort,
    listenScheme: () => stack.listenScheme,
    lanListenEnabled: () => stack.lanListen,
    listenTransports: transport.listenTransports,
    acceptedPeers: () async {
      final conversations = await ref.read(storageProvider).loadConversations();
      final seen = <String>{};
      return [
        for (final c in conversations)
          if (c.peer.canMessage && seen.add(c.peer.nodeId.hex)) c.peer.nodeId,
      ];
    },
    attemptHolePunch: (peer) async {
      final status = await transport.attemptP2PHolePunch(peer);
      return (
        connected: status == VeilHolePunchStatus.connected,
        reason: p2pPunchReasonPhrase(status),
      );
    },
  )..start();
  // The link that gives a CONVERSATION a direct route. Without it the ladder
  // exists but nothing in messaging ever calls it, which is exactly the state
  // this replaces.
  messaging.prepareDirectRoute = (peer) {
    // Never toward MYSELF. The master's node id IS the identity address, so
    // its own mirror sends named this node — and the warm then exchanged
    // endpoints with itself over the realtime loop, "met" itself, and
    // stamped its own hex into every per-peer cache (measured on the stand:
    // out/in endpoint pairs 11 ms apart, both this node).
    if (peer.hex == stack.myInvite.nodeId.hex) return;
    unawaited(svc.warmForMessaging(peer));
  };
  // This provider is rebuilt by a node boot (it watches the real stack), and a
  // boot is exactly when our listen port changes under everyone. Tell them.
  unawaited(svc.announceLocalEndpoints());
  ref.onDispose(() {
    messaging.prepareDirectRoute = null;
    svc.dispose();
  });
  return svc;
});

/// Short, address-free reason phrase for a non-connected hole-punch outcome —
/// the structured stage name surfaced to the transport badge / `/call_state`
/// / logs. Never carries peer addresses.
String p2pPunchReasonPhrase(VeilHolePunchStatus status) => switch (status) {
  VeilHolePunchStatus.connected => 'direct session up',
  VeilHolePunchStatus.noReflector => 'no NAT reflector',
  VeilHolePunchStatus.signalingTimeout => 'NAT signaling timed out',
  VeilHolePunchStatus.mappingUnusable => 'no usable NAT mapping',
  VeilHolePunchStatus.punchTimeout => 'hole punch timed out',
  VeilHolePunchStatus.quicFailed => 'direct QUIC failed',
  VeilHolePunchStatus.refusedAnonymous => 'anonymous mode',
  VeilHolePunchStatus.unknownPeer => 'peer not yet exchanged',
  VeilHolePunchStatus.unsupported => 'punch unsupported',
  VeilHolePunchStatus.unknown => 'direct punch failed',
};
