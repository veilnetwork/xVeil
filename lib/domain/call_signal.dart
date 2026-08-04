import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Control-plane message for a call, carried as the JSON body of a
/// `WireKind.callSignal` envelope over the ordinary (durable) messaging channel.
///
/// The signal is transport-agnostic: it rides the SAME anon-or-direct egress and
/// the mailbox/rendezvous relay as chat, so it works identically for anon↔anon,
/// anon↔non-anon, and non-anon↔non-anon pairings. The media itself flows on a
/// separately-negotiated path (see [CallTransportProposal]) — the signal only
/// sets it up and tears it down.
///
/// Wire form is compact JSON with short keys so re-sends stay cheap:
///   {c:callId, k:type, m:{a,v,s}, p:posture, t:{k,r,e}, mk:mediaKey, r:reason,
///    mr:mediaRepairRequested, v:protocolVersion, ts:sentAtMs}
/// Unknown keys are ignored on decode, and an unknown [type]/[posture]/[kind]
/// enum index decodes to its `.unknown` sentinel so a newer peer's additions
/// degrade gracefully instead of throwing.
enum CallSignalType {
  /// Caller → callee: "I want to call you", carries offered media + posture +
  /// transport proposal + the caller's media key.
  offer,

  /// Callee → caller: "I accept", carries the accepted media + the callee's
  /// posture + agreed transport + the callee's media key.
  answer,

  /// Callee → caller: "I decline" (see [CallSignal.reason]).
  reject,

  /// Caller → callee: "never mind" — withdraws an offer before it is answered.
  cancel,

  /// Callee → caller: "I'm already in a call."
  busy,

  /// Either side: "hang up" an offered/connecting/active call.
  end,

  /// Either side, mid-call: media or transport change (add video, start/stop
  /// screen share, switch path). Carries the new [CallSignal.media]/transport.
  renegotiate,

  /// Either side: additional transport/reachability info discovered after the
  /// offer/answer (ICE-like late candidate for the P2P path).
  transportInfo,

  /// Either side, mid-call: a liveness heartbeat. Sent periodically once a call
  /// is connecting/active; receiving ANY signal (this one included) resets the
  /// peer-liveness timer, so a call whose peer vanishes (crash, kill, network
  /// drop — no graceful `end`) is torn down instead of hanging in "in call"
  /// forever. Carries only callId (+ sentAtMs); no state change on receipt.
  health,

  /// Decode-only sentinel for a type this build doesn't know. Never encoded.
  /// (Added enum values go ABOVE this one; an older peer decodes a newer type's
  /// index as its own `unknown` and ignores it — see _enumFromIndex.)
  unknown,
}

/// The SENDER's anonymity posture for this call (per-identity boot property —
/// the peer cannot infer it, so it travels in-band). Drives path negotiation.
enum CallPosture {
  /// Onion-routed identity — media must never take a location-revealing path.
  anonymous,

  /// Direct (non-anonymous) identity — may consent to a P2P media path.
  direct,

  /// Decode-only sentinel. Never encoded.
  unknown,
}

/// The negotiated (or proposed) media path.
enum CallTransportKind {
  /// Full standard onion circuit (used when either party requires anonymity).
  onion,

  /// Media forwarded through relay(s) without onion (direct identities only).
  relay,

  /// Direct peer-to-peer obfs4 (only when both are direct, both consent, and a
  /// reachable endpoint exists; otherwise negotiation falls back to [relay]).
  p2p,

  /// Decode-only sentinel. Never encoded.
  unknown,
}

/// Why a call was rejected/ended/cancelled. Carried on [CallSignalType.reject],
/// [CallSignalType.end], [CallSignalType.cancel], [CallSignalType.busy].
enum CallEndReason {
  hangup,
  declined,
  busy,
  timeout,
  cancelled,
  error,

  /// The peer's build lacks calling, or none of the offered media is supported.
  unsupported,
  unknown,
}

/// Which media streams a call offers/carries. All three can combine.
class CallMedia {
  const CallMedia({
    this.audio = false,
    this.video = false,
    this.screen = false,
  });

  final bool audio;
  final bool video;
  final bool screen;

  bool get isEmpty => !audio && !video && !screen;

  CallMedia copyWith({bool? audio, bool? video, bool? screen}) => CallMedia(
    audio: audio ?? this.audio,
    video: video ?? this.video,
    screen: screen ?? this.screen,
  );

  Map<String, dynamic> toJson() => {
    if (audio) 'a': true,
    if (video) 'v': true,
    if (screen) 's': true,
  };

  static CallMedia fromJson(Map<String, dynamic>? j) => j == null
      ? const CallMedia()
      : CallMedia(
          audio: j['a'] == true,
          video: j['v'] == true,
          screen: j['s'] == true,
        );

  @override
  String toString() => 'CallMedia(a:$audio v:$video s:$screen)';
}

/// A proposed/agreed media path plus the hints the peer needs to join it.
class CallTransportProposal {
  const CallTransportProposal(this.kind, {this.relayNodeId, this.p2pEndpoints});

  final CallTransportKind kind;

  /// For [CallTransportKind.relay]: hex node id of the shared forwarding relay.
  final String? relayNodeId;

  /// For [CallTransportKind.p2p]: direct reachability hints (obfs4 endpoint
  /// URIs). ONLY populated for a direct↔direct call where the sender consents
  /// to reveal its endpoint — never for an anonymous party.
  final List<String>? p2pEndpoints;

  Map<String, dynamic> toJson() => {
    'k': kind.index,
    if (relayNodeId != null) 'r': relayNodeId,
    if (p2pEndpoints != null && p2pEndpoints!.isNotEmpty) 'e': p2pEndpoints,
  };

  static CallTransportProposal fromJson(Map<String, dynamic> j) =>
      CallTransportProposal(
        _enumFromIndex(
          CallTransportKind.values,
          j['k'],
          CallTransportKind.unknown,
        ),
        relayNodeId: j['r'] as String?,
        p2pEndpoints: (j['e'] as List?)?.cast<String>(),
      );

  @override
  String toString() =>
      'CallTransportProposal(${kind.name}${relayNodeId != null ? ' relay=$relayNodeId' : ''})';
}

/// Current call-signal protocol version. Bump on incompatible schema changes;
/// the receiver may downgrade behavior for a lower [CallSignal.protocolVersion].
///
/// v2 (2026-07-17): this build decodes MEDIA_BATCH_MAGIC-prefixed cells on
/// direct and relay media paths. A v2 peer may batch packets already queued at
/// the same instant without a gather timer: relay amortizes envelope+padding,
/// while direct avoids one awaited IPC acknowledgement per RTP packet. The
/// signal wire schema itself is unchanged.
/// v3 (2026-07-20): offer and answer carry independent random 32-byte media
/// contributions. Both endpoints derive directional per-call keys; RTP is then
/// symmetrically sealed once and stays below one QUIC DATAGRAM.
/// v3 seal, revised (2026-08-04): the seal is no longer a relay optimization —
/// it covers direct and onion too, and there is no unsealed mode left. Missing
/// or malformed contributions therefore mean NO media channel, not a fallback
/// path, and no code may branch on the peer's advertised version to decide
/// whether to seal: that field is unauthenticated.
const int kCallSignalProtocolVersion = 3;

/// Historical: the version from which a peer decoded relay media batching.
/// Batching is now a wire format carried INSIDE the seal, so nothing gates on
/// this any more. Kept because it names a real point in the wire's history.
const int kCallRelayBatchingMinVersion = 2;

/// Historical: the version from which a peer sealed relay media. Every peer
/// that can do media at all seals every route now; retained for the same
/// reason as [kCallRelayBatchingMinVersion].
const int kCallRelaySealedMediaMinVersion = 3;

/// Generate one endpoint's E2E-authenticated call-media contribution.
String generateCallMediaKeyContribution() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256), growable: false),
  );
  try {
    return base64UrlEncode(bytes).replaceAll('=', '');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Strictly decode a v3 call-media contribution. An invalid value leaves the
/// call with no key material, and therefore with no media channel on any
/// route — there is no unsealed path it could fall back to.
Uint8List? decodeCallMediaKeyContribution(String? encoded) {
  if (encoded == null || encoded.length < 42 || encoded.length > 44) {
    return null;
  }
  try {
    final bytes = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(encoded)),
    );
    return bytes.length == 32 ? bytes : null;
  } catch (_) {
    return null;
  }
}

class CallSignal {
  const CallSignal({
    required this.callId,
    required this.type,
    this.media,
    this.posture,
    this.transport,
    this.mediaKey,
    this.reason,
    this.mediaRepairRequested = false,
    this.protocolVersion = kCallSignalProtocolVersion,
    this.sentAtMs,
  });

  /// Stable id shared by every signal of one call (offer through end). Both
  /// sides key their call FSM on it.
  final String callId;

  final CallSignalType type;

  /// Offered/accepted/renegotiated media. Present on offer/answer/renegotiate.
  final CallMedia? media;

  /// The sender's anonymity posture. Present on offer/answer.
  final CallPosture? posture;

  /// Proposed/agreed media path. Present on offer/answer/renegotiate/transportInfo.
  final CallTransportProposal? transport;

  /// Base64url random contribution to directional relay-media keys. The call
  /// signal's E2E envelope authenticates it; the final keys are derived only
  /// after both offer and answer contributions are known and never leave the
  /// endpoint. Present on v3 offer/answer.
  final String? mediaKey;

  /// Present on reject/end/cancel/busy.
  final CallEndReason? reason;

  /// End-to-end liveness feedback carried on [CallSignalType.health]. `true`
  /// means signaling still reaches the sender but no RTP/RTCP has arrived at
  /// this receiver for the repair grace period. The sender should refresh its
  /// anonymous outbound route; older peers ignore this additive key.
  final bool mediaRepairRequested;

  final int protocolVersion;

  /// Sender wall-clock (Unix ms) — for ring-timeout / stale-signal handling.
  final int? sentAtMs;

  bool get wantsAudio => media?.audio ?? false;
  bool get wantsVideo => media?.video ?? false;
  bool get wantsScreen => media?.screen ?? false;

  CallSignal copyWith({
    CallSignalType? type,
    CallMedia? media,
    CallPosture? posture,
    CallTransportProposal? transport,
    String? mediaKey,
    CallEndReason? reason,
    bool? mediaRepairRequested,
    int? sentAtMs,
  }) => CallSignal(
    callId: callId,
    type: type ?? this.type,
    media: media ?? this.media,
    posture: posture ?? this.posture,
    transport: transport ?? this.transport,
    mediaKey: mediaKey ?? this.mediaKey,
    reason: reason ?? this.reason,
    mediaRepairRequested: mediaRepairRequested ?? this.mediaRepairRequested,
    protocolVersion: protocolVersion,
    sentAtMs: sentAtMs ?? this.sentAtMs,
  );

  Map<String, dynamic> toJson() => {
    'c': callId,
    'k': type.index,
    if (media != null && !media!.isEmpty) 'm': media!.toJson(),
    if (posture != null) 'p': posture!.index,
    if (transport != null) 't': transport!.toJson(),
    if (mediaKey != null) 'mk': mediaKey,
    if (reason != null) 'r': reason!.index,
    if (mediaRepairRequested) 'mr': true,
    'v': protocolVersion,
    if (sentAtMs != null) 'ts': sentAtMs,
  };

  /// The string that goes in the `WireKind.callSignal` envelope body.
  String encode() => jsonEncode(toJson());

  static CallSignal? tryDecode(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic>) return null;
      final callId = j['c'] as String?;
      if (callId == null || callId.isEmpty) return null;
      return CallSignal(
        callId: callId,
        type: _enumFromIndex(
          CallSignalType.values,
          j['k'],
          CallSignalType.unknown,
        ),
        media: j['m'] == null
            ? null
            : CallMedia.fromJson((j['m'] as Map).cast<String, dynamic>()),
        posture: j['p'] == null
            ? null
            : _enumFromIndex(CallPosture.values, j['p'], CallPosture.unknown),
        transport: j['t'] == null
            ? null
            : CallTransportProposal.fromJson(
                (j['t'] as Map).cast<String, dynamic>(),
              ),
        mediaKey: j['mk'] as String?,
        reason: j['r'] == null
            ? null
            : _enumFromIndex(
                CallEndReason.values,
                j['r'],
                CallEndReason.unknown,
              ),
        mediaRepairRequested: j['mr'] == true,
        protocolVersion: (j['v'] as num?)?.toInt() ?? 1,
        sentAtMs: (j['ts'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'CallSignal(${type.name} call=$callId${media != null ? ' $media' : ''}'
      '${transport != null ? ' via ${transport!.kind.name}' : ''})';
}

/// Decode an enum by wire index, mapping out-of-range/missing to [fallback]
/// (the `.unknown` sentinel) so a newer peer's additions never throw.
T _enumFromIndex<T>(List<T> values, dynamic raw, T fallback) {
  if (raw is num) {
    final i = raw.toInt();
    if (i >= 0 && i < values.length) return values[i];
  }
  return fallback;
}
