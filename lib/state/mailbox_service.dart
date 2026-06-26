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
import '../data/transport/veil_mailbox_network.dart' show MailboxDrainUnreachable;
import '../data/transport/veil_transport.dart';
import 'mailbox_orchestrator.dart';
import 'package:xveil/core/log.dart';

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
  // Fixed, low back-off after an UNREACHABLE drain (no relay answered). Unlike a
  // confirmed-empty inbox this does not escalate: we don't know whether mail is
  // waiting, so we keep polling within seconds (here: skip one tick ≈ one extra
  // drain interval between attempts) rather than the exponential idle back-off.
  static const int _failureBackoffSkips = 1;
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

  // Other relays our OWN rendezvous ad still advertises beyond [_registeredRelay]
  // — stale slots from prior sessions, and the node's built-in receiver task's
  // relay (it picks from connected peers, a different set than our seed list, so
  // it can name a DIFFERENT relay). A SENDER resolves the freshest KEM-bearing ad
  // and may deposit to one of THESE, not the single relay we registered at this
  // session — which black-holed offline delivery. So the drain fetches the UNION.
  // Refreshed periodically ([_selfResolveEveryTicks]); the registered relay is
  // ALWAYS drained regardless, so this can only ADD coverage, never remove it.
  List<NodeId> _advertisedRelays = const [];
  // Candidate relays whose KEM key we have successfully resolved + cached, so the
  // drain can fetch them DIRECT. Only these are added to the drain union — a
  // candidate without a known key would otherwise burn a 5s fetch timeout per
  // tick on the (always-failing) relay self-resolve fallback.
  final Set<String> _warmedRelays = {};
  // Bounds the eager warm-retry loop so a permanently-unresolvable candidate (a
  // down seed) doesn't trigger a resolve every tick forever. ~2 min at 10s.
  int _warmAttempts = 0;
  static const int _maxWarmAttempts = 12;
  int _selfResolveCountdown = 0;
  // ~1 min between own-ad self-resolves at the default 10s drain interval. The
  // resolve is a DHT walk (too costly every tick), but stale-relay drift is slow.
  static const int _selfResolveEveryTicks = 6;

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
    // Prefer the relay we registered at LAST session (persisted) so we re-pick
    // the SAME relay first instead of drifting to another resolvable candidate —
    // drift leaves a stale ad slot at the old relay that a sender can still
    // deposit to. It still has to resolve; if the relay is gone we fall straight
    // through to the XOR order. No-op when there's no cache (loopback/dev).
    final preferred = await _relayKeyCache?.getPreferredRelay();
    if (preferred != null && _relays.any((r) => r.hex == preferred.hex)) {
      _relays = [
        preferred,
        ..._relays.where((r) => r.hex != preferred.hex),
      ];
    }
    devLog(() => 'xVeil[mailbox]: start — ${relays.length} relay candidate(s), '
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
    devLog(() => 'xVeil[mailbox]: start done — registered=$_registered');
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
      devLog(() => 'xVeil[mailbox]: relay ${relay.short} — KEM key NOT resolved '
          '(no relay-dir entry, no cached key); skipping');
      return;
    }
    try {
      await _client.registerRendezvousPublisher(
        rendezvousNodeId: relay.bytes,
        authCookie: _cookie,
        // 1h, matching veil's built-in receiver task (RENDEZVOUS_AD_VALIDITY_SECS
        // =3600). The maintenance tick republishes our live entry well within the
        // window, so reachability is unaffected — but a relay we STOP advertising
        // (failover/relay change) now has its stale ad expire in ≤1h instead of
        // lingering 24h, shrinking the window in which a sender can deposit to a
        // relay we no longer drain. (Union-drain already collects such deposits;
        // this just bounds how long the drift set stays large.)
        validityWindowSecs: 3600,
        relayKemAlgo: 0,
        relayKemPk: kem,
      );
      _registered = true;
      _registeredRelay = relay; // drain fetches straight from here (no DHT re-resolve)
      // Remember this relay so the next session re-picks it first (Fix 4).
      unawaited(_relayKeyCache?.setPreferredRelay(relay) ?? Future.value());
      if (fromFresh) {
        // Persist the freshly-verified key for a future cold start.
        unawaited(_relayKeyCache?.put(relay, kem) ?? Future.value());
      }
      devLog(() => 'xVeil[mailbox]: REGISTERED rendezvous publisher @ relay '
          '${relay.short} (me=${_me.short} reachable by node_id now; '
          'key=${fromFresh ? "fresh" : "cached"})');
    } catch (e) {
      devLog(() => 'xVeil[mailbox]: register @ ${relay.short} FAILED: $e');
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
        devLog(() => 'xVeil[mailbox]: handle dead — stopping retries until a fresh '
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

  /// Resolve + cache the KEM key of EVERY candidate relay so the drain can fetch
  /// each one DIRECT (key-given). [lookupRelayX25519] is a one-hop relay-dir
  /// query to a connected relay (NOT the recursive DHT walk that a node's own-ad
  /// self-resolve needs), so it succeeds on mobile where self-resolve returns 0.
  /// Best-effort: a candidate whose key won't resolve is just skipped by fetch().
  Future<void> _warmCandidateKeys() async {
    final cache = _relayKeyCache;
    if (cache == null) return;
    for (final relay in _relays) {
      if (_warmedRelays.contains(relay.hex)) continue; // already have its key
      try {
        final kem = await _client.lookupRelayX25519(relay.bytes);
        if (kem != null && kem.length == 32) {
          await cache.put(relay, kem);
          if (_warmedRelays.add(relay.hex)) {
            // A NEWLY-warmed relay just entered the drain union — drain promptly
            // to check it instead of waiting out the escalated empty-drain
            // back-off we accrued while only the registered relay's dead blobs
            // came back.
            _drainSkips = 0;
            _emptyDrainStreak = 0;
          }
        }
      } catch (_) {
        // best-effort — fetch() falls back / skips a relay without a known key
      }
    }
  }

  /// Resolve our OWN rendezvous ad to discover EVERY relay it advertises (not
  /// just the one we registered at this session), and cache each relay's public
  /// KEM key so the drain can fetch it key-given DIRECT. Best-effort + bounded: a
  /// failure leaves the prior set intact, and the registered relay is drained
  /// regardless — so this can only ADD drain coverage, never remove it. NOTE: on
  /// mobile this typically returns 0 (a node can't resolve its own ad over the
  /// DHT) — [_warmCandidateKeys] + draining all candidates is the reliable path;
  /// this just adds any relay OUTSIDE the candidate pool when it does resolve.
  Future<void> _refreshAdvertisedRelays() async {
    try {
      final replicas = await _client.mailbox
          .lookupRendezvousReplicas(_me.bytes)
          .timeout(const Duration(seconds: 8));
      final relays = <NodeId>[];
      for (final r in replicas) {
        final relay = NodeId(Uint8List.fromList(r.relayNodeId));
        relays.add(relay);
        if (r.rendezvousKemPk.length == 32) {
          unawaited(_relayKeyCache?.put(
                relay,
                Uint8List.fromList(r.rendezvousKemPk),
              ) ??
              Future.value());
        }
      }
      _advertisedRelays = relays;
      devLog(() => 'xVeil[mailbox]: advertised relays=${relays.length} '
          '(${relays.map((r) => r.short).join(",")})');
    } catch (e) {
      // Keep the prior set; the registered relay still drains every tick.
      devLog(() => 'xVeil[mailbox]: self-resolve advertised relays failed: $e');
    }
  }

  Future<void> _drainTick() async {
    if (_draining || _handleDead) return;
    // Warm candidate relay KEM keys BEFORE the back-off gate. The registered
    // relay keeps returning our un-openable dead blobs (recovered=empty), which
    // escalates the empty-drain back-off and would SKIP the body below — so if we
    // warmed there, we'd never discover the relay the deposit actually landed on
    // once back-off kicks in. One-hop resolves, bounded, and self-limiting once
    // every candidate is warmed.
    if (_registered &&
        _warmedRelays.length < _relays.length &&
        _warmAttempts < _maxWarmAttempts) {
      _warmAttempts++;
      await _warmCandidateKeys();
    }
    if (_drainSkips > 0) {
      _drainSkips--;
      return; // in backoff after empty/failed drains — don't stall the IPC
    }
    _draining = true;
    var gotMail = false;
    var unreachable = false;
    try {
      // Keep trying to advertise a mailbox relay until one resolves — a relay's
      // published key can appear well after we first connect, so this persistent
      // retry (every drain interval) is what makes us reachable by node_id once
      // a relay is actually resolvable.
      if (!_registered && _relays.isNotEmpty) {
        await _tryRegister();
      }
      // Periodically warm the KEM key of EVERY candidate relay (so we can fetch
      // each one DIRECT) and, as a desktop-only bonus, self-resolve our own ad.
      // The drain below covers the UNION of all candidate relays — the deposit
      // lands on whichever relay our freshest KEM ad named, and on this network
      // that is ALWAYS one of the bundled candidates (the node's built-in
      // receiver task and any stale prior-session slot also pick from the same
      // connected-relay pool). Draining them all collects it even though a node
      // CANNOT resolve its OWN rendezvous ad over the DHT on mobile (the
      // self-resolve returns 0 — which is why only draining _registeredRelay
      // black-holed offline mail deposited to a different advertised relay).
      if (_registered) {
        if (_selfResolveCountdown <= 0) {
          await _refreshAdvertisedRelays();
          _selfResolveCountdown = _selfResolveEveryTicks;
        } else {
          _selfResolveCountdown--;
        }
      }
      // Deduped union: the relay we registered at + ALL candidate relays (the
      // deposit almost certainly hit one of them) + any relay our own ad still
      // advertises (self-resolve bonus). A deposit to ANY of them is collected,
      // closing the deposit-relay != drain-relay black hole. Empty only before
      // registration, where fetch() falls back to its own-ad self-resolve.
      final drainSet = <String, NodeId>{};
      if (_registeredRelay != null) {
        drainSet[_registeredRelay!.hex] = _registeredRelay!;
      }
      for (final r in _relays) {
        if (_warmedRelays.contains(r.hex)) drainSet[r.hex] = r;
      }
      for (final r in _advertisedRelays) {
        drainSet[r.hex] = r;
      }
      final recovered = await _orchestrator.drain(
        me: _me,
        authCookie: Uint8List(0), // ignored on the network path
        ourCertVersion: _ourCertVersion,
        knownRelays: drainSet.values.toList(),
        // Dedup is enforced downstream by the messaging layer (it stores by the
        // same content id), so we re-deliver everything the relay returns and
        // let that gate duplicates — keeps this layer storage-free.
        alreadyHave: (_) async => false,
      );
      gotMail = recovered.isNotEmpty;
      for (final m in recovered) {
        _deliver(InboundMessage(src: m.sender, payload: m.data));
      }
    } on MailboxDrainUnreachable {
      // Every known relay failed to ANSWER (vs. a relay answering "empty"). We
      // do NOT know the mailbox is empty, so this must NOT inflate the idle
      // back-off — that conflation let a single transient (DHT self-resolve /
      // reply-circuit hiccup) suppress draining for minutes while a sender kept
      // depositing. Retry at a bounded, near-cadence interval instead.
      unreachable = true;
    } catch (_) {
      // Other unexpected drain fault — treat like an unreachable transient (keep
      // polling), never like a confirmed-empty inbox.
      unreachable = true;
    } finally {
      _draining = false;
      if (gotMail) {
        // Mail delivered — clear all back-off and re-poll promptly (more may be
        // queued at the relay).
        _emptyDrainStreak = 0;
        _drainSkips = 0;
      } else if (unreachable) {
        // Transient: bounded retry. Don't touch the idle streak (a relay never
        // confirmed empty), and cap the skip low so pending mail is stranded for
        // seconds, not minutes — while still spacing the (up to fetch-timeout)
        // IPC sends enough not to stall the UI every tick.
        _drainSkips = _failureBackoffSkips;
      } else {
        // A relay authoritatively answered with an empty mailbox — genuinely
        // idle, so the exponential back-off is appropriate here.
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
