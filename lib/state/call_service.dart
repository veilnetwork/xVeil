import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'messaging.dart';
import 'providers.dart';
import 'veil_call_media.dart';

const _uuid = Uuid();

/// How long an unanswered call rings before it auto-ends (the caller's "no
/// answer" and the callee's "missed call").
const Duration kCallRingTimeout = Duration(seconds: 45);

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

  /// Tear down any running media session. Idempotent.
  Future<void> stop();
}

/// The call-session state machine (control plane). One active call at a time.
/// Subscribes to [MessagingService.onCallSignal] for inbound offers/answers/…
/// and sends outbound signals via [MessagingService.sendCallSignal]. Media is
/// layered on via an optional [CallMediaController]: it starts when the call
/// reaches [CallStatus.connecting] and promotes the call to
/// [CallStatus.active].
class CallService {
  CallService(this._messaging, {DateTime Function()? now, CallMediaController? media})
      : _now = now ?? DateTime.now,
        // ignore: prefer_initializing_formals — public `media:` param → private field.
        _media = media;

  final MessagingService _messaging;
  final DateTime Function() _now;
  final CallMediaController? _media;

  final _changes = StreamController<Call?>.broadcast();
  void Function(NodeId, CallSignal)? _handler;
  Call? _current;
  Timer? _ringTimer;
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
    _set(Call(
      callId: callId,
      peer: peer,
      direction: CallDirection.outgoing,
      media: media,
      status: CallStatus.dialing,
      localPosture: posture,
      startedAt: _now(),
    ));
    // Advisory proposal from our side; the answer finalizes the path once the
    // callee knows both postures. An anonymous caller is never P2P.
    final proposal = CallTransportProposal(posture == CallPosture.anonymous
        ? CallTransportKind.onion
        : CallTransportKind.relay);
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
    final transport = negotiateCallTransport(
      local: c.localPosture,
      peer: c.peerPosture ?? CallPosture.anonymous,
    );
    _set(c.copyWith(
      status: CallStatus.connecting,
      transport: transport,
      connectedAt: _now(),
    ));
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
        c.peer, c.callId, CallSignalType.reject, CallEndReason.declined);
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
        c.peer, c.callId, CallSignalType.cancel, CallEndReason.cancelled);
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
        c.peer, c.callId, CallSignalType.end, CallEndReason.hangup);
    _end(CallEndReason.hangup);
  }

  // ---- inbound signal handling -------------------------------------------

  void _onSignal(NodeId peer, CallSignal sig) {
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
      final glare = existing.peer == peer &&
          existing.direction == CallDirection.outgoing &&
          existing.status == CallStatus.dialing;
      if (glare && sig.callId.compareTo(existing.callId) < 0) {
        _cancelRingTimeout(); // our outgoing offer loses; adopt their incoming
      } else {
        unawaited(_sendControl(
            peer, sig.callId, CallSignalType.busy, CallEndReason.busy));
        return;
      }
    }
    _set(Call(
      callId: sig.callId,
      peer: peer,
      direction: CallDirection.incoming,
      media: sig.media ?? const CallMedia(audio: true),
      status: CallStatus.ringing,
      localPosture: _localPosture,
      peerPosture: sig.posture,
      startedAt: _now(),
    ));
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
    final transport = sig.transport?.kind ??
        negotiateCallTransport(
          local: c.localPosture,
          peer: sig.posture ?? CallPosture.anonymous,
        );
    _set(c.copyWith(
      status: CallStatus.connecting,
      peerPosture: sig.posture,
      transport: transport,
      connectedAt: _now(),
    ));
    unawaited(_startMedia());
  }

  void _onRemoteEnd(NodeId peer, CallSignal sig, CallEndReason reason) {
    final c = _current;
    if (c == null || c.callId != sig.callId || c.peer != peer) return;
    _end(reason);
  }

  // ---- helpers ------------------------------------------------------------

  Future<void> _sendControl(
      NodeId peer, String callId, CallSignalType type, CallEndReason reason) {
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
      unawaited(_sendControl(
        c.peer,
        c.callId,
        c.isOutgoing ? CallSignalType.cancel : CallSignalType.reject,
        CallEndReason.timeout,
      ));
      _end(CallEndReason.timeout);
    });
  }

  void _cancelRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = null;
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
    if (media == null) return;
    final c = _current;
    if (c == null || c.status != CallStatus.connecting) return;
    final callId = c.callId;
    bool ok = false;
    try {
      ok = await media.start(c);
    } catch (_) {
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
    unawaited(_media?.stop());
    final c = _current;
    if (c != null && !_changes.isClosed) {
      // Emit the terminal snapshot (so the UI can show "call ended" / reason),
      // then clear the slot with a trailing null so a new call can start.
      _changes.add(
          c.copyWith(status: CallStatus.ended, endReason: reason, endedAt: _now()));
    }
    _current = null;
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _cancelRingTimeout();
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
  final svc = CallService(messaging, media: media)..start();
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
