// `prefer_initializing_formals` suppressed: external NAMED params with private
// fields can't use `this._x` formals (Dart forbids private named args across
// libraries), so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:typed_data';

import 'package:veil_flutter/veil_ffi.dart'
    show VeilClient, VeilEvent, VeilEventKind;

import '../core/ids.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_addressing.dart';
import '../data/transport/veil_mailbox_network.dart'
    show MailboxDrainUnreachable;
import '../data/transport/veil_transport.dart';
import 'mailbox_orchestrator.dart';
import 'package:xveil/core/log.dart';

/// How often an IDLE client polls its relays.
///
/// Raised from 10s after measuring the mechanism it backs up: over 16 deposits
/// on a live pair — awake and dozing — the relay's wake ping arrived every
/// time, faster than the clock skew between the two devices, so the poll never
/// delivered any of them. What it costs when nothing is happening was 4.2
/// drains a minute; this makes that roughly one.
///
/// The poll is NOT redundant, which is why it is lengthened rather than
/// removed: a deposit made while the recipient has no live session cannot be
/// pinged at all, and a ping can be lost. That case was not reproducible on
/// the stand, so its value is unmeasured — not disproved.
const kIdleDrainInterval = Duration(seconds: 60);

/// The longest an idle client may go between drains, back-off included.
const kMaxIdleDrainGap = Duration(minutes: 5);

/// How many drain ticks to skip after [streak] consecutive empty drains, at a
/// poll cadence of [interval].
///
/// The escalation is exponential, and the ceiling is a TIME rather than a tick
/// count. It used to be a tick count, which meant raising the poll interval
/// silently multiplied the worst case with it — at a 60s cadence a 32-tick
/// back-off is half an hour of undelivered mail, and this poll exists to catch
/// the deposit whose wake ping was lost. A net with a half-hour hole is not a
/// net.
int idleDrainSkips(int streak, Duration interval) {
  final exponential = 1 << streak.clamp(1, 5);
  if (interval.inMilliseconds <= 0) return exponential;
  final ceiling =
      (kMaxIdleDrainGap.inMilliseconds ~/ interval.inMilliseconds) - 1;
  return exponential.clamp(1, ceiling < 1 ? 1 : ceiling);
}

/// The deposit surface [MessagingService] uses for offline delivery — sealing a
/// message for an offline [recipient] at their advertised relay. Extracted as an
/// interface so the messaging layer can be tested without a live [VeilClient].
abstract interface class MailboxSink {
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  });

  /// Hint that a peer is live-reachable right now (an inbound frame just
  /// arrived), so any mail it stashed should be drained promptly rather than on
  /// the idle back-off. Best-effort + debounced; see [MailboxService.nudgeDrain].
  void nudgeDrain();

  /// Hint that a conversation is ACTIVE right now (the user just sent
  /// something, or mail just arrived), so a reply is likely to land at the
  /// relay within seconds — poll at the fast burst cadence for a bounded
  /// window instead of the idle interval. See [MailboxService.noteActivity].
  void noteActivity();

  /// Suspend periodic/immediate FETCH work while latency-critical media owns
  /// the device. Deposits and recovered-message delivery are unaffected.
  bool get backgroundDrainPaused;
  set backgroundDrainPaused(bool value);
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
    Duration drainInterval = kIdleDrainInterval,
  }) : _client = client,
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
  // ---- Conversation burst window ("hot" mode) ----------------------------
  // Dialogs are bursty: after one message, the next usually follows within
  // seconds. While hot, the drain polls at [hotDrainInterval] and empty drains
  // do NOT escalate the idle back-off; the window is (re)armed by mail that
  // actually arrived or by the user sending something (noteActivity), and
  // expires on its own, so a genuinely idle client never pays the fast
  // cadence. This is the battery guard: cost is strictly proportional to
  // user-visible activity.
  //
  // A live inbound frame deliberately does NOT arm it — see [nudgeDrain].
  // It used to, on the reasoning that a frame means a conversation; measured
  // on a phone paired with a desktop, the identity's own sync beacons arrive
  // every ~20 s and held the window open indefinitely, so an idle pair polled
  // at the burst cadence forever.
  DateTime? _hotUntil;

  /// Fast poll cadence while a conversation is active. Mutable for tests.
  Duration hotDrainInterval = const Duration(seconds: 3);

  /// How long one activity signal keeps the fast cadence armed. Each new
  /// signal re-arms the full window, so an ongoing dialog stays hot; two
  /// minutes of silence returns to the idle interval + exponential back-off.
  Duration hotWindow = const Duration(minutes: 2);

  bool get _isHot {
    final until = _hotUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _heat() => _hotUntil = DateTime.now().add(hotWindow);
  // Back off draining a relay that keeps returning nothing (e.g. one that never
  // answers FETCH): its per-drain timeout periodically stalled the shared IPC
  // and froze the UI. After an empty/failed drain we skip the next 2^streak
  // ticks, bounded so the total gap never exceeds [kMaxIdleDrainGap].
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
  bool _disposed = false;
  final Completer<void> _disposeSignal = Completer<void>();
  Future<void>? _startInFlight;
  Completer<void>? _drainCompletion;
  // Relay candidates kept so the periodic tick can KEEP retrying registration
  // until one resolves (a relay's published key can appear minutes after we
  // first look — e.g. a just-restarted relay), not just during start()'s window.
  List<NodeId> _relays = const [];

  // The relay we actually REGISTERED a mailbox publisher with. The drain fetches
  // straight from here instead of re-resolving our own rendezvous ad over the
  // DHT each poll (that lookup times out on mobile and stranded pending mail).
  NodeId? _registeredRelay;

  // Candidate relays whose KEM key we have successfully resolved + cached, so the
  // drain can fetch them DIRECT. A SENDER may deposit offline mail at ANY relay
  // our ad advertises — the built-in receiver task (picks from connected peers, a
  // different set than our seed list) and stale prior-session slots all draw from
  // the same connected-relay pool, so draining every warmed candidate collects a
  // deposit even when it landed on a relay other than [_registeredRelay]. Only
  // warmed candidates are drained — one without a known key would burn a 5s fetch
  // timeout on the (always-failing) relay self-resolve fallback.
  final Set<String> _warmedRelays = {};
  // Bounds the eager warm-retry loop so a permanently-unresolvable candidate (a
  // down seed) doesn't trigger a resolve every tick forever. ~2 min at 10s.
  int _warmAttempts = 0;
  static const int _maxWarmAttempts = 12;
  // Bounds the "cover the REMAINING candidates with a KEM publisher" retries
  // after the first registration stuck — same rationale as the warm bound.
  int _registerAttempts = 0;
  static const int _maxRegisterAttempts = 12;
  // Rotates through the unwarmed candidates so a down one doesn't starve warming
  // of the others (we warm only ONE per tick to keep the UI isolate responsive).
  int _warmCursor = 0;

  /// Whether we have successfully advertised a mailbox relay this session.
  bool get isRegistered => _registered;

  /// Advertise an always-on mailbox host (the first of [relays] whose relay-key
  /// record resolves) and begin draining. Safe to call again (e.g. after a
  /// reconnect): registration is re-attempted until one candidate sticks, and
  /// the drain timer is only armed once. Candidates that aren't relay-capable
  /// (no resolvable relay-key record) are simply skipped — the resolve itself
  /// validates the choice, so a wrong/derived node_id is non-fatal.
  /// The most recently started service, for debug-hook access only (the hook
  /// flips [debugDrainPaused] during stand experiments). Cleared on dispose.
  static MailboxService? debugCurrent;

  Future<void> start({required List<NodeId> relays}) {
    if (_handleDead || _disposed) return Future<void>.value();
    debugCurrent = this;
    final running = _startInFlight;
    if (running != null) return running;
    late final Future<void> run;
    run = _start(relays).whenComplete(() {
      if (identical(_startInFlight, run)) _startInFlight = null;
    });
    _startInFlight = run;
    return run;
  }

  Future<void> _start(List<NodeId> relays) async {
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
    if (_disposed || _handleDead) return;
    if (preferred != null && _relays.any((r) => r.hex == preferred.hex)) {
      _relays = [preferred, ..._relays.where((r) => r.hex != preferred.hex)];
    }
    devLog(
      () =>
          'xVeil[mailbox]: start — ${relays.length} relay candidate(s), '
          'me=${_me.short}, alreadyRegistered=$_registered',
    );
    // Resolving a relay's KEM key is a DHT FIND_VALUE; right after the node
    // connects its routing table is barely warm, so the first attempt often
    // returns null even though the relay DOES advertise an entry. A quick
    // backoff (≈0,4,8,16s) catches the warm-up case fast; thereafter the
    // periodic drain tick KEEPS retrying registration (see [_drainTick]) until a
    // relay resolves — so a relay whose key only appears later (e.g. a restarted
    // seed) is still picked up. Idempotent; stops as soon as one sticks.
    const backoffSecs = [0, 4, 8, 16];
    for (
      var attempt = 0;
      attempt < backoffSecs.length && !_registered;
      attempt++
    ) {
      if (backoffSecs[attempt] > 0) {
        await Future.any<void>([
          Future<void>.delayed(Duration(seconds: backoffSecs[attempt])),
          _disposeSignal.future,
        ]);
      }
      if (_disposed || _handleDead) return;
      await _tryRegister();
    }
    if (_disposed || _handleDead) return;
    devLog(() => 'xVeil[mailbox]: start done — registered=$_registered');
    if (_drainTimer == null) _armDrainLoop();
    // In-network deposit wake: a mailbox relay that just STORED a deposit for
    // us pings our live session (MAILBOX_WAKE event) — drain immediately
    // instead of waiting out the poll schedule. Best-effort; relay-debounced.
    _wakeSub ??= _client.events().listen((ev) {
      if (ev.kind == VeilEventKind.mailboxWake) onDepositWake();
    });
    unawaited(_drainTick()); // don't wait a full interval for the first drain
  }

  StreamSubscription<VeilEvent>? _wakeSub;

  /// A wake that arrived while a drain was already in flight.
  ///
  /// [_drainTick] drops such a tick, which is right for a TIMER tick (the pass
  /// under way is already doing that work) and wrong for a wake: a wake is a
  /// relay saying a specific deposit just landed, and the pass under way may be
  /// past its fetch rounds and unable to see it. Dropping it cost the whole
  /// remainder of that pass plus a poll interval — measured as the slow mode of
  /// a bimodal delivery time on the stand, ~8-10s against ~2.8s when the wake
  /// found the node idle. Remembered here and spent the moment the pass ends.
  bool _wakePending = false;

  /// A relay told us a deposit just landed ([VeilEventKind.mailboxWake]) —
  /// authoritative "you have mail", so drain NOW (no nudge debounce; the relay
  /// already debounces per receiver) and open the burst window for the rest of
  /// the exchange.
  void onDepositWake() {
    if (backgroundDrainPaused ||
        _disposed ||
        _handleDead ||
        _drainTimer == null) {
      return;
    }
    _heat();
    _drainSkips = 0;
    _emptyDrainStreak = 0;
    _armDrainLoop();
    if (_draining) {
      _wakePending = true;
      devLog(
        () => 'xVeil[mailbox]: deposit wake during a drain — queued for its end',
      );
      return;
    }
    devLog(() => 'xVeil[mailbox]: deposit wake — draining now');
    unawaited(_drainTick());
  }

  /// (Re)arm the self-scheduling drain loop at the CURRENT cadence — the hot
  /// burst interval while a conversation window is open, the idle interval
  /// otherwise. Self-scheduling (vs a fixed [Timer.periodic]) is what lets the
  /// cadence follow the hot window without stacking timers; the loop stops
  /// whenever [_drainTimer] is cleared (dispose / dead handle).
  void _armDrainLoop() {
    if (_disposed || _handleDead) return;
    _drainTimer?.cancel();
    _drainTimer = Timer(_isHot ? hotDrainInterval : _drainInterval, () {
      unawaited(
        _drainTick().whenComplete(() {
          if (_drainTimer != null && !_disposed && !_handleDead) {
            _armDrainLoop();
          }
        }),
      );
    });
  }

  /// Relays where a KEM-bearing publisher entry was registered THIS session.
  /// Registering at EVERY resolvable candidate (not just the first) makes
  /// every published ad slot carry our relay KEM key — so a sender that can
  /// only resolve SOME slots after our restart still finds a deposit-capable
  /// ad, instead of hitting usable(KEM)=0 until the preferred slot propagates.
  final Set<String> _publisherRegistered = {};

  /// One pass over the relay candidates, registering at EVERY one that
  /// resolves. The FIRST success stays the drain anchor ([_registeredRelay] /
  /// preferred-relay persistence); the rest only add KEM-bearing publisher
  /// entries (the node's built-in refresh keeps them alive, preserving KEM).
  Future<void> _tryRegister() async {
    for (final relay in _relays) {
      if (_disposed || _handleDead) return;
      await _register(relay);
    }
  }

  Future<void> _register(NodeId relay) async {
    if (_disposed || _handleDead || _publisherRegistered.contains(relay.hex)) {
      return;
    }
    // Prefer a FRESH, verified resolve — now a one-hop fast path straight to the
    // connected relay (see veil's connected-peer resolver), so it succeeds even
    // on a cold routing table right after a restart. Only if that genuinely
    // fails do we fall back to a cached last-known-good key, so a transient DHT
    // hiccup doesn't leave us unreachable. We never cache a miss; only a fresh
    // key is written back, and a cached key that then fails to register is
    // evicted (it may be stale).
    var fromFresh = false;
    try {
      var kem = await _client.lookupRelayX25519(relay.bytes);
      fromFresh = kem != null;
      kem ??= await _relayKeyCache?.get(relay);
      if (kem == null || _disposed || _handleDead) {
        // No fresh resolve and no usable cached key — a later start()/reconnect
        // retries.
        if (kem == null) {
          devLog(
            () =>
                'xVeil[mailbox]: relay ${relay.short} — KEM key NOT resolved '
                '(no relay-dir entry, no cached key); skipping',
          );
        }
        return;
      }
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
      _publisherRegistered.add(relay.hex);
      if (!_registered) {
        _registered = true;
        _registeredRelay = relay; // drain anchor (no DHT re-resolve per poll)
        // Remember this relay so the next session re-picks it first (Fix 4).
        unawaited(_relayKeyCache?.setPreferredRelay(relay) ?? Future.value());
      }
      if (fromFresh) {
        // Persist the freshly-verified key for a future cold start.
        unawaited(_relayKeyCache?.put(relay, kem) ?? Future.value());
      }
      devLog(
        () =>
            'xVeil[mailbox]: REGISTERED rendezvous publisher @ relay '
            '${relay.short} (me=${_me.short} reachable by node_id now; '
            'key=${fromFresh ? "fresh" : "cached"})',
      );
    } catch (e) {
      devLog(() => 'xVeil[mailbox]: register @ ${relay.short} FAILED: $e');
      if (!fromFresh && !_disposed) {
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
        devLog(
          () =>
              'xVeil[mailbox]: handle dead — stopping retries until a fresh '
              'stack rebuilds this service',
        );
      }
    }
  }

  /// Seal [payload] (the same `WireEnvelope` bytes we'd send live) for offline
  /// [recipient] under [contentId] (the message uuid) and deposit it at the
  /// recipient's advertised relay. Best-effort: throws on no-route / no relay so
  /// the caller's outbox retries.
  @override
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

  /// Resolve + cache the KEM key of ONE not-yet-warmed candidate relay so the
  /// drain can fetch it DIRECT (key-given). [lookupRelayX25519] is a one-hop
  /// relay-dir query to a connected relay (NOT a recursive DHT walk), but we still
  /// do at most ONE per drain tick to keep the UI isolate responsive (warming all
  /// candidates + the 8s own-ad self-resolve in a single tick caused ANRs). Over a
  /// few ticks every candidate gets warmed; the registered relay drains meanwhile.
  Future<void> _warmNextCandidate() async {
    final cache = _relayKeyCache;
    if (cache == null) return;
    final unwarmed = _relays
        .where((r) => !_warmedRelays.contains(r.hex))
        .toList();
    if (unwarmed.isEmpty) return;
    final relay = unwarmed[_warmCursor++ % unwarmed.length];
    try {
      final kem = await _client.lookupRelayX25519(relay.bytes);
      if (kem != null && kem.length == 32) {
        await cache.put(relay, kem);
        if (_warmedRelays.add(relay.hex)) {
          // A NEWLY-warmed relay just entered the drain union — drain promptly to
          // check it instead of waiting out the escalated empty-drain back-off
          // accrued while only the registered relay's dead blobs came back.
          _drainSkips = 0;
          _emptyDrainStreak = 0;
        }
      }
    } catch (_) {
      // best-effort — fetch() skips a relay without a known key
    }
  }

  // Debounce so a burst of inbound frames triggers at most one extra drain per
  // window (a live chat exchange is many small frames a second).
  DateTime? _lastNudge;
  static const Duration _nudgeDebounce = Duration(seconds: 2);

  /// Hand one drained message to the app.
  ///
  /// The one attribution in this app that is already proven rather than
  /// claimed: `m.sender` is the orchestrator's `verifiedSender`, recovered from
  /// the blob's sidecar and confirmed by the auth-deliver signature — never the
  /// relay's wire hint. So this path states [SenderProvenance.signed] and means
  /// it (audit X/V-01).
  void _deliverDrained(DrainedMessage m) => _deliver(
    InboundMessage(
      src: m.sender,
      payload: m.data,
      provenance: SenderProvenance.signed,
    ),
  );

  /// A peer is provably LIVE-reachable right now (we just received a frame from
  /// it), so a message it stashed for us is likely already sitting at the relay
  /// — drain NOW instead of waiting out the idle exponential back-off.
  ///
  /// This is the latency lever for the desktop→phone case where the live
  /// rendezvous introduce is being dropped (`cookie_unknown`) but the sender's
  /// other live frames (acks, sync beacons) still arrive: without it the stashed
  /// message surfaces only on the next idle drain (~30 s on the stand); with it,
  /// within the debounce window (~seconds). Cheap + self-limiting: one fetch
  /// round, debounced, and a no-op while a drain is already in flight.
  @override
  void nudgeDrain() {
    if (backgroundDrainPaused ||
        _disposed ||
        _handleDead ||
        _drainTimer == null) {
      return;
    }
    // Deliberately does NOT open the burst window. A live frame proves the
    // peer is reachable; it does not prove a person is talking. The frames
    // that arrive on their own — acks, and the sync beacons another device of
    // this same identity emits every few seconds — would otherwise re-arm the
    // window forever, and a phone paired with a desktop would pay the fast
    // cadence for as long as both are online, with nobody using either. If
    // there really was mail behind this frame, the drain below finds it and
    // the gotMail branch opens the window on evidence instead of on a guess.
    _armDrainLoop();
    final now = DateTime.now();
    final last = _lastNudge;
    if (last != null && now.difference(last) < _nudgeDebounce) return;
    _lastNudge = now;
    // Clear the pending skip so the tick below actually runs its body (a
    // drain in progress is respected — _drainTick early-returns on _draining).
    // The streak itself is left alone: it is what we have learned about this
    // mailbox being empty, and a frame from a peer is not evidence against
    // it. Resetting it here restarted the escalation on every beacon, so the
    // timer cadence never grew past the first step while any paired device
    // was online — measured on a phone as emptyStreak pinned at 1.
    _drainSkips = 0;
    unawaited(_drainTick());
  }

  /// The user just SENT something (message / file / request): a reply tends to
  /// follow within seconds, but it almost always arrives as mailbox mail here
  /// (the live introduce toward us may be down — that's the whole point), so
  /// poll fast for [hotWindow]. No immediate drain: the reply physically can't
  /// be at the relay yet; the first hot tick a few seconds out is the earliest
  /// useful probe. Bounded battery cost: the window only exists around real
  /// user actions and expires on silence.
  @override
  void noteActivity() {
    if (backgroundDrainPaused ||
        _disposed ||
        _handleDead ||
        _drainTimer == null) {
      return;
    }
    _heat();
    _drainSkips = 0;
    _emptyDrainStreak = 0;
    _armDrainLoop(); // re-arm NOW at the hot cadence (a pending idle-interval
    // timer would otherwise delay the first fast poll by up to _drainInterval)
  }

  bool _backgroundDrainPaused = false;

  @override
  bool get backgroundDrainPaused => _backgroundDrainPaused;

  @override
  set backgroundDrainPaused(bool value) {
    if (_backgroundDrainPaused == value) return;
    _backgroundDrainPaused = value;
    if (!value && !_disposed && !_handleDead && _drainTimer != null) {
      // A call can last longer than the idle backoff. Once media releases the
      // gate, look for mail promptly instead of waiting several more minutes.
      _drainSkips = 0;
      _emptyDrainStreak = 0;
      unawaited(_drainTick());
    }
  }

  /// Stand-only alias retained for the debug hook.
  bool get debugDrainPaused => backgroundDrainPaused;
  set debugDrainPaused(bool value) => backgroundDrainPaused = value;

  Future<void> _drainTick() {
    if (backgroundDrainPaused) return Future<void>.value();
    if (_draining || _disposed || _handleDead) return Future<void>.value();
    _draining = true;
    final completion = Completer<void>();
    _drainCompletion = completion;
    return _runDrainTick().whenComplete(() {
      _draining = false;
      if (identical(_drainCompletion, completion)) _drainCompletion = null;
      if (!completion.isCompleted) completion.complete();
      // A wake that landed mid-pass names mail this pass may never have looked
      // for. Spend it now rather than making it wait out a poll interval. Only
      // a wake does this: it is evidence of a specific deposit, where a timer
      // tick is just the schedule.
      if (_wakePending) {
        _wakePending = false;
        if (!_disposed && !_handleDead && !backgroundDrainPaused) {
          devLog(() => 'xVeil[mailbox]: spending the wake queued mid-drain');
          unawaited(_drainTick());
        }
      }
    });
  }

  Future<void> _runDrainTick() async {
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
      await _warmNextCandidate();
    }
    if (_drainSkips > 0) {
      _drainSkips--;
      return; // in backoff after empty/failed drains — don't stall the IPC
    }
    var gotMail = false;
    var unreachable = false;
    try {
      // Keep trying to advertise a mailbox relay until one resolves — a relay's
      // published key can appear well after we first connect, so this persistent
      // retry (every drain interval) is what makes us reachable by node_id once
      // a relay is actually resolvable. Once ONE stuck we are reachable; keep
      // (bounded) trying to cover the REMAINING candidates too, so every ad
      // slot carries our KEM key (see [_publisherRegistered]).
      if (_relays.isNotEmpty &&
          (!_registered ||
              (_publisherRegistered.length < _relays.length &&
                  _registerAttempts < _maxRegisterAttempts))) {
        if (_registered) _registerAttempts++;
        await _tryRegister();
      }
      // Deduped union: the relay we registered at + the candidate relays whose
      // KEM key we have warmed. The deposit lands on whichever relay our freshest
      // KEM ad named, and on this network that is ALWAYS one of the bundled
      // candidates (the node's built-in receiver task and any stale prior-session
      // slot also pick from the same connected-relay pool). Draining them all
      // collects it — this closes the deposit-relay != drain-relay black hole
      // WITHOUT the own-ad DHT self-resolve (which returns 0 on mobile anyway and
      // blocked the UI isolate ~8s per refresh -> ANR). Empty only before
      // registration, where fetch() falls back to its own-ad self-resolve.
      final drainSet = <String, NodeId>{};
      if (_registeredRelay != null) {
        drainSet[_registeredRelay!.hex] = _registeredRelay!;
      }
      for (final r in _relays) {
        if (_warmedRelays.contains(r.hex)) drainSet[r.hex] = r;
      }
      final sw = Stopwatch()..start();
      devLog(
        () =>
            'xVeil[mailbox]: drain start relays='
            '${drainSet.values.map((r) => r.short).join(",")} hot=$_isHot',
      );
      final recovered = await _orchestrator.drain(
        me: _me,
        authCookie: Uint8List(0), // ignored on the network path
        ourCertVersion: _ourCertVersion,
        knownRelays: drainSet.values.toList(),
        // Cooperative preemption: FETCH itself is an IPC/network future and
        // cannot be force-cancelled safely, but the orchestrator checks this
        // before/after every round. Starting a call therefore bounds an
        // already-running 16-round backlog drain to its current round instead
        // of letting it perturb video for another ~50 seconds.
        shouldContinue: () =>
            !backgroundDrainPaused && !_disposed && !_handleDead,
        // Dedup is enforced downstream by the messaging layer (it stores by the
        // same content id), so we re-deliver everything the relay returns and
        // let that gate duplicates — keeps this layer storage-free.
        alreadyHave: (_) async => false,
        // Deliver as each blob opens, rather than when the loop ends. The
        // rounds after the one that produced a message are hunting a BACKLOG:
        // they re-fetch, meet the relay still serving the blob whose ack is in
        // flight, and wait for the removal to land. Correct work — but it is
        // about mail we do not have yet, and holding the batch until it
        // finished made every message wait out the search for its successors.
        onMessage: _deliverDrained,
      );
      devLog(
        () =>
            'xVeil[mailbox]: drain done recovered=${recovered.length} '
            'in ${sw.elapsedMilliseconds}ms',
      );
      // Already handed up one-by-one via `onMessage` above; the list is kept
      // only to decide heat and back-off below.
      gotMail = recovered.isNotEmpty;
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
      if (gotMail) {
        // Mail delivered — clear all back-off and re-poll promptly (more may be
        // queued at the relay), and open the burst window: an incoming message
        // is the strongest predictor that another follows within seconds.
        _heat();
        _emptyDrainStreak = 0;
        _drainSkips = 0;
        if (_drainTimer != null) {
          _armDrainLoop(); // switch to the hot cadence NOW
        }
      } else if (unreachable) {
        // Transient: bounded retry. Don't touch the idle streak (a relay never
        // confirmed empty), and cap the skip low so pending mail is stranded for
        // seconds, not minutes — while still spacing the (up to fetch-timeout)
        // IPC sends enough not to stall the UI every tick.
        _drainSkips = _failureBackoffSkips;
      } else if (_isHot) {
        // Empty, but a conversation window is open: keep polling every hot
        // tick — "empty right now" is expected while we WAIT for the reply,
        // so it must not count toward the idle back-off. The window's own
        // expiry is the bound (then the branch below resumes escalating).
        _emptyDrainStreak = 0;
        _drainSkips = 0;
      } else {
        // A relay authoritatively answered with an empty mailbox — genuinely
        // idle, so the exponential back-off is appropriate here.
        _emptyDrainStreak++;
        _drainSkips = idleDrainSkips(_emptyDrainStreak, _drainInterval);
      }
      devLog(
        () =>
            'xVeil[mailbox]: drain verdict gotMail=$gotMail '
            'unreachable=$unreachable skips=$_drainSkips '
            'emptyStreak=$_emptyDrainStreak hot=$_isHot',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handleDead = true;
    if (identical(debugCurrent, this)) debugCurrent = null;
    if (!_disposeSignal.isCompleted) _disposeSignal.complete();
    _drainTimer?.cancel();
    _drainTimer = null;
    await _wakeSub?.cancel();
    _wakeSub = null;
    await _startInFlight;
    await _drainCompletion?.future;
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
