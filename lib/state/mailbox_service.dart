// `prefer_initializing_formals` suppressed: external NAMED params with private
// fields can't use `this._x` formals (Dart forbids private named args across
// libraries), so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:veil_flutter/veil_flutter.dart';

import '../core/ids.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_addressing.dart';
import '../data/transport/veil_transport.dart';
import 'mailbox_orchestrator.dart';

/// The deposit surface [MessagingService] uses for offline delivery — sealing a
/// message for an offline [recipient] at their advertised relay. Extracted as an
/// interface so the messaging layer can be tested without a live [VeilClient].
abstract interface class MailboxSink {
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  });
}

/// Runs the offline-delivery side of messaging alongside [MessagingService]:
///
///  * **register** — advertise an always-on relay as THIS node's mailbox host
///    (resolve the relay's KEM key by node_id via [VeilClient.lookupRelayX25519],
///    then [VeilClient.registerRendezvousPublisher]) so senders can deposit for
///    us while we're offline.
///  * **drain** — periodically fetch + open our pending blobs ([MailboxOrchestrator.drain])
///    and hand each recovered message to [deliver] as if it had arrived live;
///    the messaging layer dedups by content id (= message uuid), so a blob that
///    was ALSO delivered live is a no-op.
///  * **stash** — seal + deposit a message for an offline recipient at THEIR
///    advertised relay ([MailboxOrchestrator.stash]).
///
/// The mailbox-relay [node_id] this node advertises is injected (`start`) — the
/// POLICY for choosing an always-on [mailbox]-capable relay (a connected relay
/// peer, a configured set, or a daemon auto-selection) is a separate decision;
/// resolving its KEM key by node_id is the part veil now provides.
class MailboxService implements MailboxSink {
  MailboxService({
    required VeilClient client,
    required NodeId me,
    required MailboxOrchestrator orchestrator,
    required void Function(InboundMessage) deliver,
    RelayKeyCache? relayKeyCache,
    int ourCertVersion = 0,
    Duration drainInterval = const Duration(seconds: 10),
  })  : _client = client,
        _me = me,
        _orchestrator = orchestrator,
        _deliver = deliver,
        _relayKeyCache = relayKeyCache,
        _ourCertVersion = ourCertVersion,
        _drainInterval = drainInterval;

  final VeilClient _client;
  final NodeId _me;
  final MailboxOrchestrator _orchestrator;
  final void Function(InboundMessage) _deliver;
  // Persisted last-known-good relay KEM keys. A fresh resolve is always
  // preferred; this only rescues registration through a transient resolve
  // failure so we don't go unreachable. Null on the loopback/dev path.
  final RelayKeyCache? _relayKeyCache;
  final int _ourCertVersion;
  final Duration _drainInterval;

  /// 16-byte rendezvous auth-cookie for our published mailbox ad. The NETWORK
  /// FETCH path authorizes by our cryptographic identity (NOT this cookie — see
  /// the no-cookie finding), so this is just the rendezvous-registration token.
  ///
  /// DETERMINISTIC per identity (was random per instance). A random cookie made
  /// every rebuilt MailboxService register a NEW (relay, cookie) rendezvous
  /// publisher, so the node accumulated several publisher entries at DISTINCT ad
  /// slots, each with a different cookie. A sender resolving slot 0 then used a
  /// cookie that no longer matched our *current* session-backed subscriber
  /// registration, so the relay dropped its introduce (`cookie_unknown`) and
  /// reverse-direction (incoming) delivery silently failed. Deriving the cookie
  /// from our node_id makes it stable across instances + restarts → exactly one
  /// publisher entry, one slot, one cookie everywhere. The node_id is public
  /// (it IS the ad's key), so this leaks nothing.
  late final Uint8List _cookie = _deriveCookie(_me);

  Timer? _drainTimer;
  bool _draining = false;
  // Back off draining a relay that keeps returning nothing (e.g. one that never
  // answers FETCH): its per-drain timeout periodically stalled the shared IPC
  // and froze the UI. After an empty/failed drain we skip the next 2^streak
  // ticks (capped ~32 = a few minutes) so a relay that recovers is still retried.
  int _emptyDrainStreak = 0;
  int _drainSkips = 0;
  bool _registered = false;
  // Set once the underlying veil handle is permanently closed (the node rebooted
  // out from under this service). Retrying is futile on a dead handle, so we stop
  // the timer instead of busy-looping; a fresh stack rebuild starts a NEW mailbox
  // on the live transport (see messagingServiceProvider).
  bool _handleDead = false;
  // Relay candidates kept so the periodic tick can KEEP retrying registration
  // until one resolves (a relay's published key can appear minutes after we
  // first look — e.g. a just-restarted relay), not just during start()'s window.
  List<NodeId> _relays = const [];

  // The relay we actually REGISTERED a mailbox publisher with. The drain fetches
  // straight from here instead of re-resolving our own rendezvous ad over the
  // DHT each poll (that lookup times out on mobile and stranded pending mail).
  NodeId? _registeredRelay;

  /// Whether we have successfully advertised a mailbox relay this session.
  bool get isRegistered => _registered;

  /// Advertise an always-on mailbox host (the first of [relays] whose relay-key
  /// record resolves) and begin draining. Safe to call again (e.g. after a
  /// reconnect): registration is re-attempted until one candidate sticks, and
  /// the drain timer is only armed once. Candidates that aren't relay-capable
  /// (no resolvable relay-key record) are simply skipped — the resolve itself
  /// validates the choice, so a wrong/derived node_id is non-fatal.
  Future<void> start({required List<NodeId> relays}) async {
    if (_handleDead) return; // this service is bound to a dead handle; no-op
    // Order candidates by Kademlia XOR distance to our own node_id so we
    // deterministically prefer the SAME relay across restarts AND converge with
    // veil's built-in receiver task (pick_rendezvous_relay_deterministic uses the
    // identical metric). Both then advertise ONE stable relay per identity
    // instead of drifting "first that resolved" picks that strand stale ad slots
    // at relays we no longer drain — which a sender resolves into a black hole.
    _relays = relaysByXorDistance(_me, relays);
    debugPrint('xVeil[mailbox]: start — ${relays.length} relay candidate(s), '
        'me=${_me.short}, alreadyRegistered=$_registered');
    // Resolving a relay's KEM key is a DHT FIND_VALUE; right after the node
    // connects its routing table is barely warm, so the first attempt often
    // returns null even though the relay DOES advertise an entry. A quick
    // backoff (≈0,4,8,16s) catches the warm-up case fast; thereafter the
    // periodic drain tick KEEPS retrying registration (see [_drainTick]) until a
    // relay resolves — so a relay whose key only appears later (e.g. a restarted
    // seed) is still picked up. Idempotent; stops as soon as one sticks.
    const backoffSecs = [0, 4, 8, 16];
    for (var attempt = 0; attempt < backoffSecs.length && !_registered; attempt++) {
      if (backoffSecs[attempt] > 0) {
        await Future<void>.delayed(Duration(seconds: backoffSecs[attempt]));
      }
      await _tryRegister();
    }
    debugPrint('xVeil[mailbox]: start done — registered=$_registered');
    _drainTimer ??= Timer.periodic(_drainInterval, (_) => _drainTick());
    unawaited(_drainTick()); // don't wait a full interval for the first drain
  }

  /// One pass over the relay candidates, registering at the first that resolves.
  Future<void> _tryRegister() async {
    for (final relay in _relays) {
      if (_registered) break;
      await _register(relay);
    }
  }

  Future<void> _register(NodeId relay) async {
    if (_registered) return;
    // Prefer a FRESH, verified resolve — now a one-hop fast path straight to the
    // connected relay (see veil's connected-peer resolver), so it succeeds even
    // on a cold routing table right after a restart. Only if that genuinely
    // fails do we fall back to a cached last-known-good key, so a transient DHT
    // hiccup doesn't leave us unreachable. We never cache a miss; only a fresh
    // key is written back, and a cached key that then fails to register is
    // evicted (it may be stale).
    var kem = await _client.lookupRelayX25519(relay.bytes);
    final fromFresh = kem != null;
    kem ??= await _relayKeyCache?.get(relay);
    if (kem == null) {
      // No fresh resolve and no usable cached key — a later start()/reconnect
      // retries.
      debugPrint('xVeil[mailbox]: relay ${relay.short} — KEM key NOT resolved '
          '(no relay-dir entry, no cached key); skipping');
      return;
    }
    try {
      await _client.registerRendezvousPublisher(
        rendezvousNodeId: relay.bytes,
        authCookie: _cookie,
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: kem,
      );
      _registered = true;
      _registeredRelay = relay; // drain fetches straight from here (no DHT re-resolve)
      if (fromFresh) {
        // Persist the freshly-verified key for a future cold start.
        unawaited(_relayKeyCache?.put(relay, kem) ?? Future.value());
      }
      debugPrint('xVeil[mailbox]: REGISTERED rendezvous publisher @ relay '
          '${relay.short} (me=${_me.short} reachable by node_id now; '
          'key=${fromFresh ? "fresh" : "cached"})');
    } catch (e) {
      debugPrint('xVeil[mailbox]: register @ ${relay.short} FAILED: $e');
      if (!fromFresh) {
        // We registered with a cached key and it failed — it may be stale; drop
        // it so the next tick resolves fresh instead of reusing a bad key.
        unawaited(_relayKeyCache?.evict(relay) ?? Future.value());
      }
      // A closed handle never recovers on this transport — stop the retry loop
      // so we don't spam every drain tick. The provider rebuilds a fresh mailbox
      // when the stack comes back up.
      if (e.toString().contains('handle already closed')) {
        _handleDead = true;
        _drainTimer?.cancel();
        _drainTimer = null;
        debugPrint('xVeil[mailbox]: handle dead — stopping retries until a fresh '
            'stack rebuilds this service');
      }
    }
  }

  /// Seal [payload] (the same `WireEnvelope` bytes we'd send live) for offline
  /// [recipient] under [contentId] (the message uuid) and deposit it at the
  /// recipient's advertised relay. Best-effort: throws on no-route / no relay so
  /// the caller's outbox retries.
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    return _orchestrator.stash(
      me: _me,
      recipient: recipient,
      appId: chatAppIdFor(recipient),
      endpointId: veilChatEndpointId,
      data: payload,
      contentId: contentId,
    );
  }

  Future<void> _drainTick() async {
    if (_draining || _handleDead) return;
    if (_drainSkips > 0) {
      _drainSkips--;
      return; // in backoff after empty/failed drains — don't stall the IPC
    }
    _draining = true;
    var gotMail = false;
    try {
      // Keep trying to advertise a mailbox relay until one resolves — a relay's
      // published key can appear well after we first connect, so this persistent
      // retry (every drain interval) is what makes us reachable by node_id once
      // a relay is actually resolvable.
      if (!_registered && _relays.isNotEmpty) {
        await _tryRegister();
      }
      final recovered = await _orchestrator.drain(
        me: _me,
        authCookie: Uint8List(0), // ignored on the network path
        ourCertVersion: _ourCertVersion,
        // Fetch straight from the relay we registered with (if any) — skips the
        // flaky DHT self-ad resolve that was stranding mail on mobile.
        knownRelays: _registeredRelay != null ? [_registeredRelay!] : const [],
        // Dedup is enforced downstream by the messaging layer (it stores by the
        // same content id), so we re-deliver everything the relay returns and
        // let that gate duplicates — keeps this layer storage-free.
        alreadyHave: (_) async => false,
      );
      gotMail = recovered.isNotEmpty;
      for (final m in recovered) {
        _deliver(InboundMessage(src: m.sender, payload: m.data));
      }
    } catch (_) {
      // Transient drain failure (DHT lookup / circuit not ready) — back off.
    } finally {
      _draining = false;
      if (gotMail) {
        _emptyDrainStreak = 0;
        _drainSkips = 0;
      } else {
        _emptyDrainStreak++;
        _drainSkips = 1 << _emptyDrainStreak.clamp(1, 5); // 2,4,8,16,32 ticks
      }
    }
  }

  Future<void> dispose() async {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  /// Stable per-identity rendezvous cookie: the two halves of the 32-byte
  /// node_id XOR-folded to 16 bytes. Deterministic (same across instances /
  /// restarts), uniformly distributed (node_id is a BLAKE3 hash), and reveals
  /// nothing the public ad doesn't already (the ad is keyed by node_id).
  static Uint8List _deriveCookie(NodeId me) {
    final id = me.bytes;
    final c = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      c[i] = id[i] ^ id[i + 16];
    }
    return c;
  }
}

/// Sort [relays] by Kademlia XOR distance to [me]'s node_id (closest first),
/// returning a new list (input untouched). Deterministic and stable across
/// restarts, and IDENTICAL to veil's `pick_rendezvous_relay_deterministic`
/// metric — so the app's mailbox publisher and the node's built-in receiver
/// converge on the SAME rendezvous relay per identity, collapsing the multiple
/// drifting ad slots that previously black-holed incoming delivery. Ties (which
/// require two distinct node_ids with equal distance — impossible for real
/// 32-byte ids) resolve to stable input order.
@visibleForTesting
List<NodeId> relaysByXorDistance(NodeId me, List<NodeId> relays) {
  final anchor = me.bytes;
  final sorted = [...relays];
  sorted.sort((a, b) {
    final ab = a.bytes;
    final bb = b.bytes;
    for (var i = 0; i < 32; i++) {
      final da = ab[i] ^ anchor[i];
      final db = bb[i] ^ anchor[i];
      if (da != db) return da - db;
    }
    return 0;
  });
  return sorted;
}
