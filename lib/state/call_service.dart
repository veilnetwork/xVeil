import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/log.dart';
import '../core/ids.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'messaging.dart';
import 'call_slot.dart';
import 'p2p_endpoint_service.dart';
import 'p2p_policy_controller.dart';
import 'providers.dart';
import 'veil_call_media.dart';

const _uuid = Uuid();
Future<bool> _neverP2P(NodeId peer) async => false;

enum CallMediaDeviceKind { camera, microphone, screen }

/// A locally available capture device. IDs never leave this endpoint; call
/// signaling only carries the media set, not hardware details.
class CallMediaDevice {
  const CallMediaDevice({
    required this.id,
    required this.label,
    required this.kind,
    this.facing,
    this.selected = false,
  });

  final String id;
  final String label;
  final CallMediaDeviceKind kind;
  final String? facing;
  final bool selected;
}

/// How long an unanswered call rings before it auto-ends (the caller's "no
/// answer" and the callee's "missed call").
/// 45 s covered the happy path but not this network's real control-plane
/// tail: when the first live send of the callee's `answer` is lost, the
/// durable copy arrives via the mailbox path (deposit → relay wake → drain),
/// which legitimately takes tens of seconds — the caller's dial timeout then
/// fired exactly as the callee accepted, tearing down a call both users
/// wanted (observed live 2026-07-17). 75 s spans the mailbox tail plus the
/// fast call-signal re-drive ladder, and is within ordinary telephony ring
/// times.
const Duration kCallRingTimeout = Duration(seconds: 75);

/// Once a call is connecting/active, each side sends a [CallSignalType.health]
/// heartbeat this often.
const Duration kCallHeartbeatInterval = Duration(seconds: 5);

/// …and if NOTHING is heard from the peer for this long, the call is torn down
/// with [CallEndReason.timeout] — the peer vanished (crash, kill, network drop)
/// without a graceful `end`, so the UI must not hang on "in call" forever.
/// Generous vs the heartbeat interval (≈4 missed beats) so ordinary signaling
/// jitter over the durable channel never drops a still-live call.
const Duration kCallLivenessTimeout = Duration(seconds: 20);

/// A connected media engine should exchange RTP or RTCP even when speech is
/// quiet. If none arrives for this long while signaling is demonstrably alive,
/// ask the peer to refresh its outbound route. Repair must preserve onion for
/// either anonymous party; two direct parties may only fall back P2P → relay.
const Duration kCallMediaRepairAfter = Duration(seconds: 10);

/// Pure transport negotiation: given both parties' postures (+ P2P consent and
/// reachability for the direct case), pick the media path per the design matrix.
/// **Anonymity is never sacrificed** — if EITHER side is anonymous the media
/// uses onion. When both sides are non-anonymous, direct P2P is preferred when
/// both consent and the peer is reachable; otherwise media uses a relay.
CallTransportKind negotiateCallTransport({
  required CallPosture local,
  required CallPosture peer,
  bool localConsentsP2P = false,
  bool peerConsentsP2P = false,
  bool peerReachable = false,
}) {
  final localAnon = local == CallPosture.anonymous;
  final peerAnon = peer == CallPosture.anonymous;
  if (localAnon || peerAnon) return CallTransportKind.onion;
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

  /// The route the media engine actually opened. It must equal the negotiated
  /// route, except for the explicitly permitted direct P2P → non-onion relay
  /// fallback. Null until a channel is open.
  CallTransportKind? get activeTransport => null;

  /// Human-readable reason the active route differs from the negotiated one
  /// (the p2p → relay fallback), or null when the route is as negotiated.
  /// Surfaced by the transport badge so "relay" answers "why not p2p?".
  String? get transportFallbackReason => null;

  /// Tear down any running media session. Idempotent.
  Future<void> stop();

  /// Mute/unmute the local mic mid-call (stop/resume transmitting). No-op if no
  /// media session is running.
  Future<void> setMicMuted(bool muted) async {}

  /// Enable/disable the local camera mid-call (start/stop capturing + sending
  /// video). No-op if no media session is running or the call has no video.
  Future<void> setCameraEnabled(bool enabled) async {}

  Future<List<CallMediaDevice>> listCameras() async => const [];
  Future<List<CallMediaDevice>> listMicrophones() async => const [];
  Future<List<CallMediaDevice>> listScreens() async => const [];
  Future<bool> selectCamera(String id) async => false;
  Future<bool> selectMicrophone(String id) async => false;
  Future<bool> selectScreen(String id) async => false;

  /// Mount the video pipeline (send + receive) on the live session of a call
  /// that started audio-only — the mid-call audio→video upgrade. Does NOT
  /// start the camera; that stays behind [setCameraEnabled]. Returns false
  /// when there is no live session or no video backend.
  Future<bool> setVideoEnabled(bool enabled) async => false;

  /// Start/stop sharing the local screen as the call's video source (replaces
  /// the camera while on — single VP8 track). Returns false when this
  /// platform has no screen backend or capture can't start; a no-op false if
  /// no media session is running.
  Future<bool> setScreenShareEnabled(bool enabled) async => false;

  /// Emits when the OS revokes an active local screen-capture session (for
  /// example from Android's system sharing chip). The FSM folds that external
  /// stop back into local state and announces it to the peer.
  Stream<void> get screenShareStopped => const Stream<void>.empty();

  /// Wall-clock of the last time media packets were seen ARRIVING from the peer
  /// (rx_pkts increased), or null if none yet / no media. The FSM treats this as
  /// proof of life for the liveness timeout: while the peer's media is flowing,
  /// the call is alive even if the (flakier) durable signaling heartbeat is
  /// delayed — signaling silence alone must not drop a call that's clearly up.
  DateTime? get lastMediaRxAt => null;

  /// Rebuild/refresh the current outbound route after the peer reports
  /// end-to-end media silence. Implementations must preserve the negotiated
  /// route kind, be idempotent/rate-limited, and return whether media is usable.
  Future<bool> repairRoute() async => true;

  /// Follow a mutually safe mid-call fallback. The only currently valid switch
  /// is P2P -> non-onion relay for two direct identities.
  Future<bool> switchRoute(CallTransportKind transport) async => false;

  /// Non-sensitive live transport counters for diagnostics. Implementations
  /// must not include media bytes, keys, peer addresses, or cleartext.
  Map<String, Object?> get diagnostics => const {};
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
    CallSlot? callSlot,
    bool startMuted = false,
    Future<bool> Function(NodeId peer)? localAllowsP2P,
    Future<bool> Function(NodeId peer)? peerReachableForP2P,
  }) : _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals — public `media:` param → private field.
       _media = media,
       // ignore: prefer_initializing_formals — public `callSlot:` → private field.
       _callSlot = callSlot,
       // ignore: prefer_initializing_formals — public `startMuted:` → private field.
       _startMuted = startMuted,
       _localAllowsP2P = localAllowsP2P ?? _neverP2P,
       _peerReachableForP2P = peerReachableForP2P ?? _neverP2P;

  final MessagingService _messaging;
  final DateTime Function() _now;
  final CallMediaController? _media;
  final CallSlot? _callSlot;
  final bool _startMuted;
  final Future<bool> Function(NodeId peer) _localAllowsP2P;
  final Future<bool> Function(NodeId peer) _peerReachableForP2P;

  final _changes = StreamController<Call?>.broadcast();
  void Function(NodeId, CallSignal)? _handler;
  Call? _current;
  Timer? _ringTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<void>? _screenShareStoppedSub;
  DateTime? _lastPeerSignalAt;
  bool _started = false;

  /// A callee may discover that P2P is unusable immediately after accepting
  /// and send `transportInfo(relay)` before its durable `answer` reaches the
  /// caller. Keep that safe downgrade until the answer proves both parties are
  /// direct; otherwise an out-of-order signal would be silently lost and the
  /// two media engines would open different routes.
  String? _pendingRelayCallId;
  NodeId? _pendingRelayPeer;
  CallTransportKind? _outgoingProposal;
  int _mediaOperationEpoch = 0;

  /// sentAtMs of the newest peer renegotiate applied to the current call —
  /// re-drives and out-of-order deliveries fold strictly-newer (an old
  /// re-driven media set must never regress a newer one). Reset per call.
  int _lastRenegotiateAtMs = 0;

  /// The single active (or just-ended) call, or null when idle.
  Call? get current => _current;
  Map<String, Object?> get mediaDiagnostics => _media?.diagnostics ?? const {};

  /// Why the live route differs from the negotiated one (p2p → relay
  /// fallback), or null. For the transport badge / diagnostics.
  String? get transportFallbackReason => _media?.transportFallbackReason;

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
    _screenShareStoppedSub = _media?.screenShareStopped.listen((_) {
      if (_current?.screenOn == true) {
        unawaited(setScreenShareEnabled(false));
      }
    });
  }

  // ---- outbound user actions ---------------------------------------------

  /// Place a call to [peer] offering [media]. No-op if a call is already live or
  /// [media] is empty.
  Future<void> placeCall(NodeId peer, CallMedia media) async {
    if (_current != null && _current!.isLive) return; // one call at a time
    if (media.isEmpty) return;
    if (!(_callSlot?.acquire(CallSlotOwner.direct) ?? true)) return;
    final callId = _uuid.v4();
    final posture = _localPosture;
    final localMediaKey = generateCallMediaKeyContribution();
    _set(
      Call(
        callId: callId,
        peer: peer,
        direction: CallDirection.outgoing,
        media: media,
        status: CallStatus.dialing,
        localPosture: posture,
        startedAt: _now(),
        micOn: !_startMuted,
        // Camera intent tracks the offered media set. An audio-only call must
        // start with the camera OFF, or the UI toggle reads "on" and its tap
        // (→ off) is a no-op — making the audio→video upgrade unreachable.
        cameraOn: media.video,
        localMediaKey: localMediaKey,
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
    final current = _current;
    if (current == null ||
        current.callId != callId ||
        current.status != CallStatus.dialing) {
      return;
    }
    _outgoingProposal = proposal.kind;
    await _messaging.sendCallSignal(
      peer,
      CallSignal(
        callId: callId,
        type: CallSignalType.offer,
        media: media,
        posture: posture,
        transport: proposal,
        mediaKey: localMediaKey,
      ),
    );
    // The realtime leg can deliver the offer and its answer while the durable
    // enqueue above is still completing. In that race `_onAnswer` already
    // moved this call to connecting/active before this future resumes; arming
    // a 75-second timer here would later cancel a perfectly healthy call.
    final stillDialing = _current;
    if (stillDialing != null &&
        stillDialing.callId == callId &&
        stillDialing.peer == peer &&
        stillDialing.status == CallStatus.dialing) {
      _armRingTimeout(callId);
    }
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
        mediaKey: c.localMediaKey,
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
    // The user's decision must clear the UI instantly: the control signal's
    // durable leg awaits an encrypted-store outbox write, which can take
    // seconds. Send it in the background; _end() never depends on it.
    unawaited(
      _sendControl(
        c.peer,
        c.callId,
        CallSignalType.reject,
        CallEndReason.declined,
      ),
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
    unawaited(
      _sendControl(
        c.peer,
        c.callId,
        CallSignalType.cancel,
        CallEndReason.cancelled,
      ),
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
    unawaited(
      _sendControl(c.peer, c.callId, CallSignalType.end, CallEndReason.hangup),
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

  Future<List<CallMediaDevice>> listCameras() =>
      _media?.listCameras() ?? Future.value(const []);

  Future<List<CallMediaDevice>> listMicrophones() =>
      _media?.listMicrophones() ?? Future.value(const []);

  Future<List<CallMediaDevice>> listScreens() =>
      _media?.listScreens() ?? Future.value(const []);

  Future<bool> selectCamera(String id) async {
    final c = _current;
    if (c == null || !c.isLive) return false;
    return await _media?.selectCamera(id) ?? false;
  }

  Future<bool> selectMicrophone(String id) async {
    final c = _current;
    if (c == null || !c.isLive) return false;
    return await _media?.selectMicrophone(id) ?? false;
  }

  Future<bool> selectScreen(String id) async {
    final c = _current;
    if (c == null || !c.isLive) return false;
    return await _media?.selectScreen(id) ?? false;
  }

  /// Phone-oriented one-tap front/back switch. Multiple lenses of the same
  /// facing remain available in the full device picker.
  Future<bool> switchCameraFacing() async {
    final devices = await listCameras();
    if (devices.length < 2) return false;
    final current = devices.where((device) => device.selected).firstOrNull;
    final opposite = devices.where(
      (device) =>
          current == null ||
          (current.facing == 'front' && device.facing == 'back') ||
          (current.facing != 'front' && device.facing == 'front'),
    );
    final next = opposite.isNotEmpty
        ? opposite.first
        : devices.firstWhere((device) => !device.selected);
    return selectCamera(next.id);
  }

  /// Toggle the local camera on/off during a live call (camera button).
  /// While a screen share is running the camera stays off at the source (the
  /// share owns the single video track) — only the INTENT flag flips, and
  /// ending the share restores whatever it says.
  ///
  /// On an audio-only call, turning the camera ON upgrades the call to video:
  /// the already-negotiated route (and its privacy posture) is untouched —
  /// only the media set grows, exactly like a screen share start — and the
  /// peer learns about it via the same renegotiate signal.
  Future<void> setCameraEnabled(bool on) async {
    final c = _current;
    if (c == null || !c.isLive) return;
    if (!c.media.video) {
      if (!on) return; // nothing to turn off in an audio-only call
      final ok = await _media?.setVideoEnabled(true) ?? false;
      if (!ok) return; // no video backend — stay an audio call
      final cur = _current;
      if (cur == null || !cur.isLive || cur.callId != c.callId) return;
      _set(
        cur.copyWith(media: cur.media.copyWith(video: true), cameraOn: true),
      );
      await _media?.setCameraEnabled(true);
      await _announceMediaSet();
      return;
    }
    if (c.cameraOn == on) return;
    _set(c.copyWith(cameraOn: on));
    if (!c.screenOn) await _media?.setCameraEnabled(on);
  }

  /// Toggle sharing the local screen as the call's video source (screen
  /// button, desktop). The screen replaces the camera on the same VP8 track;
  /// ending the share restores the camera if [Call.cameraOn] still wants it.
  /// The peer is told via a renegotiate signal carrying the updated media set
  /// (advisory — its UI can badge the share; the video content changes anyway).
  Future<void> setScreenShareEnabled(bool on) async {
    final c = _current;
    if (c == null || !c.isLive || !c.media.video || c.screenOn == on) return;
    if (on) {
      final ok = await _media?.setScreenShareEnabled(true) ?? false;
      if (!ok) return; // no backend / capture failed — state stays camera
      _set(c.copyWith(screenOn: true, media: c.media.copyWith(screen: true)));
    } else {
      await _media?.setScreenShareEnabled(false);
      _set(c.copyWith(screenOn: false, media: c.media.copyWith(screen: false)));
      if (c.cameraOn) await _media?.setCameraEnabled(true);
    }
    await _announceMediaSet();
  }

  /// Tell the peer the call's media set changed (camera upgrade, screen share
  /// start/end) via a renegotiate signal carrying the full current set.
  Future<void> _announceMediaSet() async {
    final cur = _current;
    if (cur == null || !cur.isLive) return;
    await _messaging.sendCallSignal(
      cur.peer,
      CallSignal(
        callId: cur.callId,
        type: CallSignalType.renegotiate,
        media: cur.media,
      ),
    );
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
        // Liveness already refreshed above. A repair request is end-to-end
        // evidence that OUR outbound media is black-holed after its first hop.
        if (sig.mediaRepairRequested) {
          unawaited(_repairMediaRoute(peer, sig.callId));
        }
        break;
      case CallSignalType.renegotiate:
        _onRenegotiate(peer, sig);
      case CallSignalType.transportInfo:
        final c = _current;
        final requested = sig.transport?.kind;
        if (c != null &&
            c.callId == sig.callId &&
            c.peer == peer &&
            c.direction == CallDirection.outgoing &&
            c.status == CallStatus.dialing &&
            c.localPosture == CallPosture.direct &&
            requested == CallTransportKind.relay) {
          _pendingRelayCallId = sig.callId;
          _pendingRelayPeer = peer;
        } else if (c != null &&
            c.callId == sig.callId &&
            c.peer == peer &&
            c.isLive &&
            c.transport == CallTransportKind.p2p &&
            requested == CallTransportKind.relay &&
            c.localPosture == CallPosture.direct &&
            c.peerPosture == CallPosture.direct) {
          unawaited(_followRelayFallback(peer, sig.callId));
        }
        // Onion is never accepted here: the original posture negotiation is
        // the only authority that can select it.
        break;
      case CallSignalType.unknown:
        break;
    }
  }

  /// Mid-call media change from the peer (their screen share started/ended).
  /// Advisory: folds the new media set into the call so the UI reflects it.
  /// Durable re-drives / out-of-order deliveries apply strictly-newer-by-
  /// sentAt only ([_lastRenegotiateAtMs]) — a re-driven stale set must never
  /// overwrite a newer one.
  void _onRenegotiate(NodeId peer, CallSignal sig) {
    final c = _current;
    if (c == null || !c.isLive || c.callId != sig.callId || c.peer != peer) {
      return;
    }
    final media = sig.media;
    final at = sig.sentAtMs;
    if (media == null || media.isEmpty || at == null) return;
    if (at <= _lastRenegotiateAtMs) return; // stale or duplicate re-drive
    _lastRenegotiateAtMs = at;
    final gainedVideo = media.video && !c.media.video;
    if (gainedVideo) {
      // The peer upgraded an audio call to video: mount our own video
      // pipeline (send + receive) on the live session so their frames render.
      // Receiving video never implies transmitting it — our camera is OFF
      // until the user turns it on (audio-only calls carry the constructor's
      // default cameraOn=true, which was meaningless without video).
      _set(c.copyWith(media: media, cameraOn: false));
      unawaited(_media?.setVideoEnabled(true));
    } else {
      _set(c.copyWith(media: media));
    }
  }

  Future<void> _repairMediaRoute(NodeId peer, String callId) async {
    final media = _media;
    final before = _current;
    if (media == null ||
        before == null ||
        before.callId != callId ||
        before.peer != peer ||
        !before.isLive ||
        before.status != CallStatus.active) {
      // A peer can become active first and request repair while this side is
      // still opening its initial media channel (Apple TCC prompts make that
      // window several seconds). There is no established local route to
      // repair yet: repairRoute() correctly returns false for a null channel,
      // but treating that as a terminal repair failure tears down a healthy
      // call just before startup completes. The normal heartbeat will request
      // again if media is still silent after both sides are active.
      return;
    }
    var repaired = false;
    try {
      repaired = await media.repairRoute();
    } catch (e) {
      devLog(() => 'xVeil[call-media]: route repair failed call=$callId: $e');
    }
    final cur = _current;
    if (cur == null ||
        cur.callId != callId ||
        cur.peer != peer ||
        !cur.isLive) {
      return;
    }
    final actual = media.activeTransport;
    if (repaired && actual == cur.transport) return;
    // repaired with NO open channel = a rebuild is still converging (repair
    // pending). Ending here would kill a call that is seconds from recovery;
    // a genuinely failed rebuild resurfaces as repaired=false on the peer's
    // next repair request and fails closed below.
    if (repaired && actual == null) return;
    if (repaired &&
        cur.transport == CallTransportKind.p2p &&
        actual == CallTransportKind.relay &&
        cur.localPosture == CallPosture.direct &&
        cur.peerPosture == CallPosture.direct) {
      _set(cur.copyWith(transport: CallTransportKind.relay));
      await _announceRelayFallback(cur);
      return;
    }
    // Fail closed. A broken route must not silently become onion (or any other
    // route) merely to keep the call UI alive.
    unawaited(
      _sendControl(peer, callId, CallSignalType.end, CallEndReason.error),
    );
    _end(CallEndReason.error);
  }

  Future<void> _followRelayFallback(NodeId peer, String callId) async {
    final media = _media;
    final before = _current;
    if (media == null ||
        before == null ||
        before.callId != callId ||
        before.peer != peer ||
        !before.isLive) {
      return;
    }
    // Supersede an in-flight P2P start. Its eventual failure belongs to the
    // abandoned route and must not tear down the relay session opened below.
    _mediaOperationEpoch++;
    var ok = false;
    try {
      ok = await media.switchRoute(CallTransportKind.relay);
    } catch (e) {
      devLog(() => 'xVeil[call-media]: relay follow failed call=$callId: $e');
    }
    final cur = _current;
    if (cur == null ||
        cur.callId != callId ||
        cur.peer != peer ||
        !cur.isLive) {
      return;
    }
    if (ok && media.activeTransport == CallTransportKind.relay) {
      _set(
        cur.copyWith(
          transport: CallTransportKind.relay,
          status: cur.status == CallStatus.connecting
              ? CallStatus.active
              : cur.status,
        ),
      );
      return;
    }
    unawaited(
      _sendControl(peer, callId, CallSignalType.end, CallEndReason.error),
    );
    _end(CallEndReason.error);
  }

  Future<void> _announceRelayFallback(Call call) => _messaging.sendCallSignal(
    call.peer,
    CallSignal(
      callId: call.callId,
      type: CallSignalType.transportInfo,
      transport: const CallTransportProposal(CallTransportKind.relay),
    ),
  );

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
    if (existing == null &&
        !(_callSlot?.acquire(CallSlotOwner.direct) ?? true)) {
      unawaited(
        _sendControl(peer, sig.callId, CallSignalType.busy, CallEndReason.busy),
      );
      return;
    }
    final offeredMedia = sig.media ?? const CallMedia(audio: true);
    final peerMediaKey = decodeCallMediaKeyContribution(sig.mediaKey) == null
        ? null
        : sig.mediaKey;
    _set(
      Call(
        callId: sig.callId,
        peer: peer,
        direction: CallDirection.incoming,
        media: offeredMedia,
        status: CallStatus.ringing,
        localPosture: _localPosture,
        peerPosture: sig.posture,
        startedAt: _now(),
        transport: sig.transport?.kind,
        peerProtocolVersion: sig.protocolVersion,
        micOn: !_startMuted,
        cameraOn: offeredMedia.video,
        localMediaKey: generateCallMediaKeyContribution(),
        peerMediaKey: peerMediaKey,
      ),
    );
    _armRingTimeout(sig.callId);
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
    final peerPosture = sig.posture ?? CallPosture.anonymous;
    final proposed = sig.transport?.kind;
    // The answer is a proposal, not authority to weaken either side's policy.
    // Any anonymous party forces onion. Two direct parties use P2P only when
    // our own offer also allowed it; every other answer is a non-onion relay.
    var transport =
        c.localPosture == CallPosture.anonymous ||
            peerPosture != CallPosture.direct
        ? CallTransportKind.onion
        : proposed == CallTransportKind.p2p &&
              _outgoingProposal == CallTransportKind.p2p
        ? CallTransportKind.p2p
        : CallTransportKind.relay;
    _outgoingProposal = null;
    final pendingRelay =
        _pendingRelayCallId == sig.callId && _pendingRelayPeer == peer;
    _pendingRelayCallId = null;
    _pendingRelayPeer = null;
    if (pendingRelay &&
        transport == CallTransportKind.p2p &&
        c.localPosture == CallPosture.direct &&
        sig.posture == CallPosture.direct) {
      transport = CallTransportKind.relay;
    }
    final peerMediaKey = decodeCallMediaKeyContribution(sig.mediaKey) == null
        ? null
        : sig.mediaKey;
    _set(
      c.copyWith(
        status: CallStatus.connecting,
        peerPosture: sig.posture,
        transport: transport,
        connectedAt: _now(),
        peerProtocolVersion: sig.protocolVersion,
        peerMediaKey: peerMediaKey,
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

  void _armRingTimeout(String callId) {
    _cancelRingTimeout();
    _ringTimer = Timer(kCallRingTimeout, () {
      final c = _current;
      // Defense in depth: a ring timer belongs to exactly one unanswered call.
      // It must never act on a replacement call or on this call after answer.
      if (c == null ||
          c.callId != callId ||
          (c.status != CallStatus.dialing && c.status != CallStatus.ringing)) {
        return;
      }
      devLog(
        () =>
            'xVeil[call]: ring timeout call=${c.callId} '
            'dir=${c.direction.name} status=${c.status.name}',
      );
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
            mediaRepairRequested:
                c.status == CallStatus.active &&
                _now().difference(
                      _media?.lastMediaRxAt ?? c.connectedAt ?? c.startedAt,
                    ) >=
                    kCallMediaRepairAfter,
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
    if (_current?.callId != call.callId) {
      _lastRenegotiateAtMs = 0;
      _pendingRelayCallId = null;
      _pendingRelayPeer = null;
      _outgoingProposal = null;
    }
    // Offline mailbox deposits do ML-KEM sealing and multi-relay onion fanout.
    // Keep that durable work parked while realtime call setup/media is live;
    // the messaging outbox retains every frame and resumes on the next flush
    // after `_end` clears this gate.
    _messaging.backgroundStashPaused = call.status != CallStatus.ended;
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
    final operationEpoch = ++_mediaOperationEpoch;
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
    if (operationEpoch != _mediaOperationEpoch ||
        cur == null ||
        cur.callId != callId ||
        cur.status != CallStatus.connecting) {
      return;
    }
    if (ok) {
      final actualTransport = media.activeTransport;
      if (actualTransport != null && actualTransport != cur.transport) {
        if (cur.transport == CallTransportKind.p2p &&
            actualTransport == CallTransportKind.relay &&
            cur.localPosture == CallPosture.direct &&
            cur.peerPosture == CallPosture.direct) {
          final relayed = cur.copyWith(
            status: CallStatus.active,
            transport: CallTransportKind.relay,
          );
          _set(relayed);
          unawaited(_announceRelayFallback(relayed));
          return;
        }
        devLog(
          () =>
              'xVeil[call-media]: refused route mismatch call=$callId '
              'negotiated=${cur.transport?.name ?? 'unset'} '
              'actual=${actualTransport.name}',
        );
        unawaited(
          _sendControl(
            cur.peer,
            callId,
            CallSignalType.end,
            CallEndReason.error,
          ),
        );
        _end(CallEndReason.error);
        return;
      }
      _set(cur.copyWith(status: CallStatus.active));
      return;
    }
    unawaited(
      _sendControl(cur.peer, callId, CallSignalType.end, CallEndReason.error),
    );
    _end(CallEndReason.error);
  }

  Future<void> _stopMediaAndReleaseSlot() async {
    try {
      await _media?.stop();
    } catch (_) {
      // Teardown is best-effort, but the global slot must never leak.
    } finally {
      _callSlot?.release(CallSlotOwner.direct);
    }
  }

  void _end(CallEndReason reason) {
    _cancelRingTimeout();
    _cancelHeartbeat();
    _pendingRelayCallId = null;
    _pendingRelayPeer = null;
    _outgoingProposal = null;
    _mediaOperationEpoch++;
    _messaging.backgroundStashPaused = false;
    if (_media == null) {
      _callSlot?.release(CallSlotOwner.direct);
    } else {
      unawaited(_stopMediaAndReleaseSlot());
    }
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
    _messaging.backgroundStashPaused = false;
    unawaited(_screenShareStoppedSub?.cancel());
    _screenShareStoppedSub = null;
    if (_media == null) {
      _callSlot?.release(CallSlotOwner.direct);
    } else {
      unawaited(_stopMediaAndReleaseSlot());
    }
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
    callSlot: ref.read(callSlotProvider),
    // The physical phone is used as a receive/camera endpoint and must never
    // begin transmitting room audio merely because a call connected. The user
    // can explicitly unmute from the call controls. Keep desktop behavior
    // unchanged; iOS currently has a separate device posture/test flow.
    startMuted: Platform.isAndroid,
    localAllowsP2P: (peer) =>
        ref.read(p2pPolicyProvider.notifier).allowsPeer(peer),
    // Real-P2P epic: "reachable" now means "a live direct session exists, or
    // came up within the endpoint service's small dial budget" — the service
    // exchanges LAN endpoints with the consenting contact and dials them, so
    // the proposal only says p2p when direct media can actually flow. The
    // native direct media open stays the authoritative admission gate. When
    // the service is unavailable (loopback/dev stack) keep the old optimistic
    // answer and let that native gate decide.
    peerReachableForP2P: (peer) async {
      final p2p = ref.read(p2pEndpointServiceProvider);
      if (p2p == null) return true;
      return p2p.ensureReady(peer);
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
