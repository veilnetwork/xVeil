import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/log.dart';
import '../core/ids.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'messaging.dart';
import 'p2p_policy_controller.dart';
import 'providers.dart';
import 'veil_call_media.dart';

const _uuid = Uuid();
Future<bool> _neverP2P(NodeId peer) async => false;

/// How long an unanswered call rings before it auto-ends (the caller's "no
/// answer" and the callee's "missed call").
const Duration kCallRingTimeout = Duration(seconds: 45);

/// Once a call is connecting/active, each side sends a [CallSignalType.health]
/// heartbeat this often.
const Duration kCallHeartbeatInterval = Duration(seconds: 5);

/// …and if NOTHING is heard from the peer for this long, the call is torn down
/// with [CallEndReason.timeout] — the peer vanished (crash, kill, network drop)
/// without a graceful `end`, so the UI must not hang on "in call" forever.
/// Generous vs the heartbeat interval (≈4 missed beats) so ordinary signaling
/// jitter over the durable channel never drops a still-live call.
const Duration kCallLivenessTimeout = Duration(seconds: 20);

/// Pure transport negotiation: given both parties' postures (+ P2P consent and
/// reachability for the direct case), pick the media path per the design matrix.
/// **Anonymity is never sacrificed** — if EITHER side is anonymous the media
/// stays inside the network (onion when both are anon, relay when mixed). A
/// direct P2P path is used only when BOTH sides are non-anonymous, BOTH consent,
/// and the peer is reachable — otherwise it falls back to a relay.
CallTransportKind negotiateCallTransport({
  required CallPosture local,
  required CallPosture peer,
  bool localConsentsP2P = false,
  bool peerConsentsP2P = false,
  bool peerReachable = false,
}) {
  final localAnon = local == CallPosture.anonymous;
  final peerAnon = peer == CallPosture.anonymous;
  if (localAnon && peerAnon) return CallTransportKind.onion;
  if (localAnon || peerAnon) return CallTransportKind.relay; // mixed
  if (localConsentsP2P && peerConsentsP2P && peerReachable) {
    return CallTransportKind.p2p;
  }
  return CallTransportKind.relay;
}

/// Media-plane hook for the call FSM. Started when a call reaches
/// [CallStatus.connecting]; the FSM promotes to [CallStatus.active] once [start]
/// succeeds. Injected (nullable) so the control-plane FSM stays fully testable
/// without any media/native dependency — the real impl (VeilCallMediaController)
/// opens the veil media channel + drives the libwebrtc engine.
abstract class CallMediaController {
  /// Bring up the media session for [call] (open the veil media datagram
  /// channel + start the audio engine). Returns true if media is up.
  Future<bool> start(Call call);

  /// Optionally pre-open the media channel toward the peer so the onion circuit
  /// is warming while the call is still ringing/connecting — otherwise the first
  /// seconds of audio are dropped on a cold circuit (or lost entirely if the
  /// call is short). Default no-op; idempotent; safe to call repeatedly.
  Future<void> prewarm(Call call) async {}

  /// Tear down any running media session. Idempotent.
  Future<void> stop();

  /// Mute/unmute the local mic mid-call (stop/resume transmitting). No-op if no
  /// media session is running.
  Future<void> setMicMuted(bool muted) async {}

  /// Enable/disable the local camera mid-call (start/stop capturing + sending
  /// video). No-op if no media session is running or the call has no video.
  Future<void> setCameraEnabled(bool enabled) async {}

  /// Wall-clock of the last time media packets were seen ARRIVING from the peer
  /// (rx_pkts increased), or null if none yet / no media. The FSM treats this as
  /// proof of life for the liveness timeout: while the peer's media is flowing,
  /// the call is alive even if the (flakier) durable signaling heartbeat is
  /// delayed — signaling silence alone must not drop a call that's clearly up.
  DateTime? get lastMediaRxAt => null;
}

/// The call-session state machine (control plane). One active call at a time.
/// Subscribes to [MessagingService.onCallSignal] for inbound offers/answers/…
/// and sends outbound signals via [MessagingService.sendCallSignal]. Media is
/// layered on via an optional [CallMediaController]: it starts when the call
/// reaches [CallStatus.connecting] and promotes the call to
/// [CallStatus.active].
class CallService {
  CallService(
    this._messaging, {
    DateTime Function()? now,
    CallMediaController? media,
    Future<bool> Function(NodeId peer)? localAllowsP2P,
    Future<bool> Function(NodeId peer)? peerReachableForP2P,
  }) : _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals — public `media:` param → private field.
       _media = media,
       _localAllowsP2P = localAllowsP2P ?? _neverP2P,
       _peerReachableForP2P = peerReachableForP2P ?? _neverP2P;

  final MessagingService _messaging;
  final DateTime Function() _now;
  final CallMediaController? _media;
  final Future<bool> Function(NodeId peer) _localAllowsP2P;
  final Future<bool> Function(NodeId peer) _peerReachableForP2P;

  final _changes = StreamController<Call?>.broadcast();
  void Function(NodeId, CallSignal)? _handler;
  Call? _current;
  Timer? _ringTimer;
  Timer? _heartbeatTimer;
  DateTime? _lastPeerSignalAt;
  bool _started = false;

  /// The single active (or just-ended) call, or null when idle.
  Call? get current => _current;

  /// Emits on every FSM transition, and null when the call slot clears.
  Stream<Call?> get changes => _changes.stream;

  CallPosture get _localPosture => _messaging.isAnonymousIdentity
      ? CallPosture.anonymous
      : CallPosture.direct;

  void start() {
    if (_started) return;
    _started = true;
    _handler = _onSignal;
    _messaging.onCallSignal = _handler;
  }

  // ---- outbound user actions ---------------------------------------------

  /// Place a call to [peer] offering [media]. No-op if a call is already live or
  /// [media] is empty.
  Future<void> placeCall(NodeId peer, CallMedia media) async {
    if (_current != null && _current!.isLive) return; // one call at a time
    if (media.isEmpty) return;
    final callId = _uuid.v4();
    final posture = _localPosture;
    _set(
      Call(
        callId: callId,
        peer: peer,
        direction: CallDirection.outgoing,
        media: media,
        status: CallStatus.dialing,
        localPosture: posture,
        startedAt: _now(),
      ),
    );
    // Advisory proposal from our side; the answer finalizes the path once the
    // callee knows both postures. An anonymous caller is never P2P.
    final mayOfferP2P =
        posture == CallPosture.direct &&
        await _localAllowsP2P(peer) &&
        await _peerReachableForP2P(peer);
    final proposal = CallTransportProposal(
      posture == CallPosture.anonymous
          ? CallTransportKind.onion
          : (mayOfferP2P ? CallTransportKind.p2p : CallTransportKind.relay),
    );
    await _messaging.sendCallSignal(
      peer,
      CallSignal(
        callId: callId,
        type: CallSignalType.offer,
        media: media,
        posture: posture,
        transport: proposal,
        // mediaKey (SRTP keying) is filled in Phase 3 — control plane only now.
      ),
    );
    // Start warming the media circuit to the peer now (while it rings), so audio
    // flows the instant the call is answered instead of after a cold-circuit wait.
    unawaited(_media?.prewarm(_current!));
    _armRingTimeout();
  }

  /// Accept the ringing incoming call.
  Future<void> accept() async {
    final c = _current;
    if (c == null ||
        c.direction != CallDirection.incoming ||
        c.status != CallStatus.ringing) {
      return;
    }
    _cancelRingTimeout();
    final peerProposedP2P = c.transport == CallTransportKind.p2p;
    final transport = negotiateCallTransport(
      local: c.localPosture,
      peer: c.peerPosture ?? CallPosture.anonymous,
      localConsentsP2P: await _localAllowsP2P(c.peer),
      peerConsentsP2P: peerProposedP2P,
      peerReachable: peerProposedP2P && await _peerReachableForP2P(c.peer),
    );
    _set(
      c.copyWith(
        status: CallStatus.connecting,
        transport: transport,
        connectedAt: _now(),
      ),
    );
    _startHeartbeat();
    await _messaging.sendCallSignal(
      c.peer,
      CallSignal(
        callId: c.callId,
        type: CallSignalType.answer,
        media: c.media,
        posture: c.localPosture,
        transport: CallTransportProposal(transport),
      ),
    );
    unawaited(_startMedia());
  }

  /// Reject the ringing incoming call.
  Future<void> reject() async {
    final c = _current;
    if (c == null ||
        c.direction != CallDirection.incoming ||
        c.status != CallStatus.ringing) {
      return;
    }
    await _sendControl(
      c.peer,
      c.callId,
      CallSignalType.reject,
      CallEndReason.declined,
    );
    _end(CallEndReason.declined);
  }

  /// Cancel an outgoing call we placed, before it was answered.
  Future<void> cancel() async {
    final c = _current;
    if (c == null ||
        c.direction != CallDirection.outgoing ||
        c.status != CallStatus.dialing) {
      return;
    }
    await _sendControl(
      c.peer,
      c.callId,
      CallSignalType.cancel,
      CallEndReason.cancelled,
    );
    _end(CallEndReason.cancelled);
  }

  /// Hang up / dismiss the current call whatever its state (maps to
  /// cancel/reject/end as appropriate).
  Future<void> hangup() async {
    final c = _current;
    if (c == null || !c.isLive) return;
    if (c.status == CallStatus.dialing) return cancel();
    if (c.status == CallStatus.ringing) return reject();
    await _sendControl(
      c.peer,
      c.callId,
      CallSignalType.end,
      CallEndReason.hangup,
    );
    _end(CallEndReason.hangup);
  }

  /// Toggle the local mic on/off during a live call (the in-call mic button).
  Future<void> setMicEnabled(bool on) async {
    final c = _current;
    if (c == null || !c.isLive || c.micOn == on) return;
    _set(c.copyWith(micOn: on)); // reflect immediately; the UI watches Call
    await _media?.setMicMuted(!on);
  }

  /// Toggle the local camera on/off during a live video call (camera button).
  Future<void> setCameraEnabled(bool on) async {
    final c = _current;
    if (c == null || !c.isLive || !c.media.video || c.cameraOn == on) return;
    _set(c.copyWith(cameraOn: on));
    await _media?.setCameraEnabled(on);
  }

  // ---- inbound signal handling -------------------------------------------

  void _onSignal(NodeId peer, CallSignal sig) {
    // Any signal from the current call's peer is proof of life — refresh the
    // liveness deadline before dispatching (covers offer/answer/health/… alike).
    final live = _current;
    if (live != null &&
        live.isLive &&
        live.callId == sig.callId &&
        live.peer == peer) {
      _lastPeerSignalAt = _now();
    }
    switch (sig.type) {
      case CallSignalType.offer:
        _onOffer(peer, sig);
      case CallSignalType.answer:
        _onAnswer(peer, sig);
      case CallSignalType.reject:
        _onRemoteEnd(peer, sig, CallEndReason.declined);
      case CallSignalType.busy:
        _onRemoteEnd(peer, sig, CallEndReason.busy);
      case CallSignalType.cancel:
        _onRemoteEnd(peer, sig, CallEndReason.cancelled);
      case CallSignalType.end:
        _onRemoteEnd(peer, sig, sig.reason ?? CallEndReason.hangup);
      case CallSignalType.health:
        // Liveness already refreshed above; a heartbeat carries no state change.
        break;
      case CallSignalType.renegotiate:
      case CallSignalType.transportInfo:
      case CallSignalType.unknown:
        // Phase 2+/6 (mid-call media & path changes) — ignored for now.
        break;
    }
  }

  void _onOffer(NodeId peer, CallSignal sig) {
    final existing = _current;
    if (existing != null && existing.isLive) {
      // Glare: we each offered at the same time. Deterministic tie-break — the
      // lexicographically-smaller callId wins as the caller; the loser adopts
      // the winner's offer. Any other busy case → tell them we're busy.
      final glare =
          existing.peer == peer &&
          existing.direction == CallDirection.outgoing &&
          existing.status == CallStatus.dialing;
      if (glare && sig.callId.compareTo(existing.callId) < 0) {
        _cancelRingTimeout(); // our outgoing offer loses; adopt their incoming
      } else {
        unawaited(
          _sendControl(
            peer,
            sig.callId,
            CallSignalType.busy,
            CallEndReason.busy,
          ),
        );
        return;
      }
    }
    _set(
      Call(
        callId: sig.callId,
        peer: peer,
        direction: CallDirection.incoming,
        media: sig.media ?? const CallMedia(audio: true),
        status: CallStatus.ringing,
        localPosture: _localPosture,
        peerPosture: sig.posture,
        startedAt: _now(),
        transport: sig.transport?.kind,
      ),
    );
    // Warm the media circuit back toward the caller while we ring, so audio is
    // ready the moment the user accepts.
    unawaited(_media?.prewarm(_current!));
    _armRingTimeout();
  }

  void _onAnswer(NodeId peer, CallSignal sig) {
    final c = _current;
    if (c == null ||
        c.callId != sig.callId ||
        c.peer != peer ||
        c.direction != CallDirection.outgoing ||
        c.status != CallStatus.dialing) {
      return;
    }
    _cancelRingTimeout();
    final transport =
        sig.transport?.kind ??
        negotiateCallTransport(
          local: c.localPosture,
          peer: sig.posture ?? CallPosture.anonymous,
        );
    _set(
      c.copyWith(
        status: CallStatus.connecting,
        peerPosture: sig.posture,
        transport: transport,
        connectedAt: _now(),
      ),
    );
    _startHeartbeat();
    unawaited(_startMedia());
  }

  void _onRemoteEnd(NodeId peer, CallSignal sig, CallEndReason reason) {
    final c = _current;
    if (c == null || c.callId != sig.callId || c.peer != peer) return;
    _end(reason);
  }

  // ---- helpers ------------------------------------------------------------

  Future<void> _sendControl(
    NodeId peer,
    String callId,
    CallSignalType type,
    CallEndReason reason,
  ) {
    return _messaging.sendCallSignal(
      peer,
      CallSignal(callId: callId, type: type, reason: reason),
    );
  }

  void _armRingTimeout() {
    _cancelRingTimeout();
    _ringTimer = Timer(kCallRingTimeout, () {
      final c = _current;
      if (c == null || !c.isLive) return;
      // Auto-end an unanswered call, telling the peer so their side stops ringing.
      unawaited(
        _sendControl(
          c.peer,
          c.callId,
          c.isOutgoing ? CallSignalType.cancel : CallSignalType.reject,
          CallEndReason.timeout,
        ),
      );
      _end(CallEndReason.timeout);
    });
  }

  void _cancelRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  /// Start the mid-call liveness heartbeat once a call reaches `connecting`.
  /// Each tick sends a [CallSignalType.health] beat to the peer and, if the peer
  /// has been silent past [kCallLivenessTimeout], tears the call down — this is
  /// what stops a call hanging on "in call" when the peer crashed / was killed /
  /// dropped off the network without sending a graceful `end`.
  void _startHeartbeat() {
    _cancelHeartbeat();
    _lastPeerSignalAt = _now();
    _heartbeatTimer = Timer.periodic(kCallHeartbeatInterval, (_) {
      final c = _current;
      if (c == null || !c.isLive) {
        _cancelHeartbeat();
        return;
      }
      // Proof of life = the most recent of (a signal from the peer) OR (media
      // packets arriving from the peer). Media is the RELIABLE liveness signal;
      // the durable signaling heartbeat is only a backstop for the pre-media
      // (connecting) window — it must never, on its own, drop a call whose
      // media is plainly flowing (the durable channel is exactly what's flaky).
      DateTime? alive = _lastPeerSignalAt;
      final rx = _media?.lastMediaRxAt;
      if (rx != null && (alive == null || rx.isAfter(alive))) alive = rx;
      if (alive != null && _now().difference(alive) > kCallLivenessTimeout) {
        // Peer went silent on BOTH media and signaling → tell them (harmless if
        // already gone), then end locally so the UI leaves instead of hanging.
        unawaited(
          _sendControl(
            c.peer,
            c.callId,
            CallSignalType.end,
            CallEndReason.timeout,
          ),
        );
        _end(CallEndReason.timeout);
        return;
      }
      unawaited(
        _messaging.sendCallSignal(
          c.peer,
          CallSignal(
            callId: c.callId,
            type: CallSignalType.health,
            sentAtMs: _now().millisecondsSinceEpoch,
          ),
        ),
      );
    });
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastPeerSignalAt = null;
  }

  void _set(Call call) {
    _current = call;
    if (!_changes.isClosed) _changes.add(call);
  }

  /// Bring up media for the currently-connecting call, then promote it to
  /// [CallStatus.active]. No-op (call stays `connecting`) when there is no media
  /// controller or media fails to start. Guards against races: only promotes if
  /// the same call is still connecting when `start` returns.
  Future<void> _startMedia() async {
    final media = _media;
    if (media == null) {
      devLog(() => 'xVeil[call-media]: no media controller');
      return;
    }
    final c = _current;
    if (c == null || c.status != CallStatus.connecting) return;
    final callId = c.callId;
    bool ok = false;
    try {
      devLog(
        () =>
            'xVeil[call-media]: start call=${c.callId} '
            'media=a${c.media.audio ? 1 : 0}v${c.media.video ? 1 : 0}'
            's${c.media.screen ? 1 : 0}',
      );
      ok = await media
          .start(c)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              devLog(() => 'xVeil[call-media]: start timeout call=$callId');
              return c.media.video || c.media.screen;
            },
          );
      devLog(() => 'xVeil[call-media]: start result call=$callId ok=$ok');
    } catch (e) {
      devLog(() => 'xVeil[call-media]: start failed call=$callId: $e');
      ok = false;
    }
    final cur = _current;
    if (ok &&
        cur != null &&
        cur.callId == callId &&
        cur.status == CallStatus.connecting) {
      _set(cur.copyWith(status: CallStatus.active));
    }
  }

  void _end(CallEndReason reason) {
    _cancelRingTimeout();
    _cancelHeartbeat();
    unawaited(_media?.stop());
    final c = _current;
    if (c != null && !_changes.isClosed) {
      // Emit the terminal snapshot (so the UI can show "call ended" / reason),
      // then clear the slot with a trailing null so a new call can start.
      _changes.add(
        c.copyWith(
          status: CallStatus.ended,
          endReason: reason,
          endedAt: _now(),
        ),
      );
    }
    _current = null;
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _cancelRingTimeout();
    _cancelHeartbeat();
    if (_messaging.onCallSignal == _handler) _messaging.onCallSignal = null;
    _changes.close();
  }
}

/// The call service for the ACTIVE identity's messaging pipeline. Rebuilds (and
/// disposes the prior one) whenever [messagingServiceProvider] re-points at an
/// identity switch / node reboot.
final callServiceProvider = Provider<CallService>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  // Media plane: drive the libwebrtc engine over veil when the concrete
  // embedded transport is available (macOS/desktop with libveil_media.dylib).
  final transport = ref.read(veilTransportProvider);
  final media = transport is VeilFlutterTransport
      ? VeilCallMediaController(transport)
      : null;
  final svc = CallService(
    messaging,
    media: media,
    localAllowsP2P: (peer) =>
        ref.read(p2pPolicyProvider.notifier).allowsPeer(peer),
    peerReachableForP2P: (peer) async {
      final transport = ref.read(veilTransportProvider);
      final peers = await transport.peers();
      if (peers.any((p) => p.nodeId == peer && p.isActive)) return true;
      // In the embedded runtime `peers()` reports live transport sessions, not
      // every accepted chat identity. A contact can still be reachable for app
      // datagrams (the same path that delivered this call offer/answer) without
      // appearing there, so policy consent is enough to attempt P2P media. The
      // media controller falls back to the anonymous channel if direct open
      // fails.
      return ref.read(p2pPolicyProvider.notifier).allowsPeer(peer);
    },
  )..start();
  ref.onDispose(svc.dispose);
  return svc;
});

class _CurrentCallNotifier extends StateNotifier<Call?> {
  _CurrentCallNotifier(CallService svc) : super(svc.current) {
    _sub = svc.changes.listen((c) => state = c);
  }

  StreamSubscription<Call?>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// The single active call (or null) for the UI to watch.
final currentCallProvider = StateNotifierProvider<_CurrentCallNotifier, Call?>(
  (ref) => _CurrentCallNotifier(ref.watch(callServiceProvider)),
);
