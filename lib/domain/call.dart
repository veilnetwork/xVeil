import '../core/ids.dart';
import 'call_signal.dart';

/// Who initiated the call.
enum CallDirection { outgoing, incoming }

/// The call-session lifecycle. Phase 1 (control plane) drives everything up to
/// [connecting]; media (Phase 2+) drives [connecting] → [active].
enum CallStatus {
  /// Outgoing: our offer is sent, we're waiting for the peer to answer/reject.
  dialing,

  /// Incoming: the peer's offer arrived, we're waiting for the local user to
  /// accept or reject.
  ringing,

  /// Answered by both sides; the negotiated media path is being established.
  /// (Phase 1 rests here — no media transport yet.)
  connecting,

  /// Media is flowing (Phase 3+).
  active,

  /// Terminal. See [Call.endReason].
  ended,
}

/// An immutable snapshot of the one active (or just-ended) call session. The
/// [CallService] FSM emits a fresh [Call] on every transition.
class Call {
  const Call({
    required this.callId,
    required this.peer,
    required this.direction,
    required this.media,
    required this.status,
    required this.localPosture,
    required this.startedAt,
    this.peerPosture,
    this.transport,
    this.endReason,
    this.connectedAt,
    this.endedAt,
    this.micOn = true,
    this.cameraOn = true,
  });

  /// Stable id shared with the peer for the whole call (see [CallSignal.callId]).
  final String callId;

  /// The other party.
  final NodeId peer;

  final CallDirection direction;

  /// Media requested/negotiated for this call (audio/video/screen).
  final CallMedia media;

  final CallStatus status;

  /// Our local anonymity posture (fixed per identity at boot).
  final CallPosture localPosture;

  /// The peer's posture — known once we've seen their offer (incoming) or
  /// answer (outgoing). Null before that.
  final CallPosture? peerPosture;

  /// The negotiated media path, resolved from both postures + P2P consent +
  /// reachability once both sides are known. Null until negotiated.
  final CallTransportKind? transport;

  /// Why the call ended (set only in [CallStatus.ended]).
  final CallEndReason? endReason;

  /// When the session started (offer placed / received).
  final DateTime startedAt;

  /// When it reached [connecting] (answered).
  final DateTime? connectedAt;

  /// When it reached [ended].
  final DateTime? endedAt;

  /// Local mic on (transmitting) — toggled by the in-call mic button.
  final bool micOn;

  /// Local camera on (capturing + sending video) — toggled by the in-call
  /// camera button. Only meaningful on a video call.
  final bool cameraOn;

  bool get isIncoming => direction == CallDirection.incoming;
  bool get isOutgoing => direction == CallDirection.outgoing;

  /// The call is still being set up (pre-media).
  bool get isSettingUp =>
      status == CallStatus.dialing ||
      status == CallStatus.ringing ||
      status == CallStatus.connecting;

  /// The call occupies the single active-call slot (anything but ended).
  bool get isLive => status != CallStatus.ended;

  Call copyWith({
    CallStatus? status,
    CallMedia? media,
    CallPosture? peerPosture,
    CallTransportKind? transport,
    CallEndReason? endReason,
    DateTime? connectedAt,
    DateTime? endedAt,
    bool? micOn,
    bool? cameraOn,
  }) =>
      Call(
        callId: callId,
        peer: peer,
        direction: direction,
        media: media ?? this.media,
        status: status ?? this.status,
        localPosture: localPosture,
        startedAt: startedAt,
        peerPosture: peerPosture ?? this.peerPosture,
        transport: transport ?? this.transport,
        endReason: endReason ?? this.endReason,
        connectedAt: connectedAt ?? this.connectedAt,
        endedAt: endedAt ?? this.endedAt,
        micOn: micOn ?? this.micOn,
        cameraOn: cameraOn ?? this.cameraOn,
      );

  @override
  String toString() =>
      'Call(${direction.name} ${status.name} peer=${peer.short} '
      'media=$media${transport != null ? ' via ${transport!.name}' : ''}'
      '${endReason != null ? ' [${endReason!.name}]' : ''})';
}
