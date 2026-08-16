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
    this.screenOn = false,
    this.peerProtocolVersion,
    this.localMediaKey,
    this.peerMediaKey,
    this.peerCapture,
    this.peerCaptureAtMs = 0,
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

  /// Local screen share on: our display replaces the camera as THE video
  /// source (single VP8 track; the peer renders it unchanged). [cameraOn]
  /// keeps the user's camera INTENT while sharing — ending the share restores
  /// the camera when it is still true. Desktop-only for now.
  final bool screenOn;

  /// The peer's [CallSignal.protocolVersion], learned from its offer
  /// (incoming) or answer (outgoing). Gates capabilities that would be
  /// silent noise to an older build — e.g. relay media batching (v2) — so
  /// they only turn on against a peer that provably decodes them. Null
  /// before the first peer signal.
  final int? peerProtocolVersion;

  /// E2E-authenticated v3 key contributions for this live call. These are
  /// transient control-plane state: never persisted, included in diagnostics,
  /// or rendered by [toString]. The native media layer receives only derived
  /// directional keys.
  final String? localMediaKey;
  final String? peerMediaKey;

  /// What the PEER is capturing right now (their mic/camera/screen), learned
  /// from the posture they put on their heartbeat. [media] stays the call's
  /// negotiated shape; this is the live posture inside it — the same split the
  /// group call makes between its room media and each participant's.
  ///
  /// Null until the peer has told us once. That silence is deliberate: a build
  /// that never sends a posture must leave the screen saying nothing rather
  /// than accusing the person of being muted.
  final CallMedia? peerCapture;

  /// Sender timestamp of the newest posture folded into [peerCapture]. Signals
  /// can overtake each other on the overlay, and an older one arriving late
  /// must not restore a microphone the peer has already turned off.
  final int peerCaptureAtMs;

  /// The peer has told us their microphone is off. False while they have said
  /// nothing at all — see [peerCapture].
  bool get peerMicOff => peerCapture != null && !peerCapture!.audio;

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
    // Rebound exactly once, by the fan-out caller: the identity we dialed
    // answers from the device that took the call (see _onAnswer).
    NodeId? peer,
    CallStatus? status,
    CallMedia? media,
    CallPosture? peerPosture,
    CallTransportKind? transport,
    CallEndReason? endReason,
    DateTime? connectedAt,
    DateTime? endedAt,
    bool? micOn,
    bool? cameraOn,
    bool? screenOn,
    int? peerProtocolVersion,
    String? localMediaKey,
    String? peerMediaKey,
    CallMedia? peerCapture,
    int? peerCaptureAtMs,
  }) => Call(
    callId: callId,
    peer: peer ?? this.peer,
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
    screenOn: screenOn ?? this.screenOn,
    peerProtocolVersion: peerProtocolVersion ?? this.peerProtocolVersion,
    localMediaKey: localMediaKey ?? this.localMediaKey,
    peerMediaKey: peerMediaKey ?? this.peerMediaKey,
    peerCapture: peerCapture ?? this.peerCapture,
    peerCaptureAtMs: peerCaptureAtMs ?? this.peerCaptureAtMs,
  );

  @override
  String toString() =>
      'Call(${direction.name} ${status.name} peer=${peer.short} '
      'media=$media${transport != null ? ' via ${transport!.name}' : ''}'
      '${endReason != null ? ' [${endReason!.name}]' : ''})';
}
