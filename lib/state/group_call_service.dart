import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call_signal.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import 'call_service.dart';
import 'call_slot.dart';
import 'group_service_providers.dart';
import 'providers.dart';
import 'veil_group_call_media.dart';

const _uuid = Uuid();
const Duration kGroupCallRingTimeout = Duration(seconds: 45);
const Duration kGroupCallHeartbeatInterval = Duration(seconds: 5);
const Duration kGroupCallLivenessTimeout = Duration(seconds: 20);

/// How long a live unmuted participant may stay silent before we treat our
/// inbound leg from them as black-holed and re-announce a JOIN so they
/// re-dial us (stale-rendezvous media circuit repair).
const Duration kGroupCallMediaRepairSilence = Duration(seconds: 10);

/// Floor between two repair JOIN re-announces so a genuinely unreachable
/// peer cannot make us spam the room.
const Duration kGroupCallMediaRepairMinInterval = Duration(seconds: 15);
const Duration kGroupCallReannounceInterval = Duration(seconds: 60);
const Duration kGroupCallTombstoneTtl = Duration(minutes: 3);

/// How long after the last received `announce` a room still counts as ongoing
/// for the passive "group call in progress" banner. Joined members re-announce
/// every [kGroupCallReannounceInterval]; 2.5 minutes tolerates one lost
/// announce plus delivery jitter before the banner honestly disappears.
const Duration kGroupCallRoomTtl = Duration(seconds: 150);

/// A group room known to be ongoing from its periodic `announce` frames —
/// the state behind the chat-header "join the call" banner. Purely passive:
/// holding one of these neither rings nor joins.
class ActiveGroupRoom {
  const ActiveGroupRoom({
    required this.groupId,
    this.channelId,
    this.channelEpoch,
    required this.callId,
    required this.initiator,
    required this.membershipEpoch,
    required this.media,
    required this.lastAnnounceAt,
  });

  final NodeId groupId;
  final NodeId? channelId;
  final int? channelEpoch;
  final String callId;
  final NodeId initiator;
  final int membershipEpoch;
  final CallMedia media;
  final DateTime lastAnnounceAt;
}

/// Native/media-plane boundary for an N-party room. The control FSM is useful
/// and fully testable independently, while the production implementation owns
/// one capture/mixer and a membership-synchronized set of peer channels.
abstract class GroupCallMediaController {
  Future<bool> start(GroupCall call);
  Future<void> update(GroupCall call);
  Future<void> stop();
  Future<void> setMicMuted(bool muted) async {}
  Future<void> setCameraEnabled(bool enabled) async {}
  Future<bool> setVideoEnabled(bool enabled) async => false;
  Future<bool> setScreenShareEnabled(bool enabled) async => false;
  Future<List<CallMediaDevice>> listScreens() async => const [];
  Future<bool> selectScreen(String id) async => false;
  bool get screenCaptureAccessGranted => true;
  bool requestScreenCaptureAccess() => true;
  Stream<void> get screenShareStopped => const Stream<void>.empty();
  DateTime? lastMediaRxAt(NodeId peer) => null;

  /// Drop any cached media channel toward [peer] so the next roster sync
  /// dials a fresh one. A JOIN signal from an already-known participant means
  /// the peer (re)started its media session — its old rendezvous/circuit is
  /// dead, and keeping the cached channel silently sends audio into the void
  /// (live stand, 2026-07-24: restarted phone rejoined and heard nothing).
  Future<void> invalidatePeerChannel(NodeId peer) async {}
}

class GroupCallService {
  GroupCallService(
    this._groups, {
    GroupCallMediaController? media,
    CallSlot? callSlot,
    DateTime Function()? now,
    bool Function()? otherCallBusy,
    Duration heartbeatInterval = kGroupCallHeartbeatInterval,
    Duration reannounceInterval = kGroupCallReannounceInterval,
    List<Duration> channelEpochReannounceDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) : // Named public `media:` parameter intentionally initializes private field.
       // ignore: prefer_initializing_formals
       _media = media,
       // ignore: prefer_initializing_formals
       _callSlot = callSlot,
       _now = now ?? DateTime.now,
       _otherCallBusy = otherCallBusy ?? (() => false),
       // ignore: prefer_initializing_formals
       _heartbeatInterval = heartbeatInterval,
       // ignore: prefer_initializing_formals
       _reannounceInterval = reannounceInterval,
       _channelEpochReannounceDelays = List.unmodifiable(
         channelEpochReannounceDelays,
       );

  final GroupService _groups;
  final GroupCallMediaController? _media;
  final CallSlot? _callSlot;
  final DateTime Function() _now;
  final bool Function() _otherCallBusy;
  final Duration _heartbeatInterval;
  final Duration _reannounceInterval;
  final List<Duration> _channelEpochReannounceDelays;
  final StreamController<GroupCall?> _changes = StreamController.broadcast();

  StreamSubscription<GroupCallSignal>? _subscription;
  StreamSubscription<void>? _screenShareStoppedSubscription;
  Timer? _ringTimer;
  Timer? _heartbeatTimer;
  Timer? _reannounceTimer;
  DateTime? _lastMediaRepairJoinAt;
  final List<Timer> _channelEpochReannounceTimers = [];
  GroupCall? _current;
  bool _started = false;

  /// Recently terminal room ids, RAM-only and slightly longer than the
  /// two-minute durable call-frame TTL. An admin `end` and an older periodic
  /// `announce` can traverse different relays and arrive out of order; without
  /// this guard the delayed announce rings the already-ended room again.
  /// Holds only rooms that are OVER (admin end / we lost membership) — a
  /// decline or missed ring must not bury a room that is still going.
  final Map<String, DateTime> _endedCallTombstones = <String, DateTime>{};

  /// Call ids that already had their one full-screen ring on this device
  /// (declined, missed, or left). Later announces refresh the passive room
  /// banner but never ring again — re-ringing every tombstone expiry was the
  /// old behavior and it reads as harassment, not as an invitation.
  final Set<String> _ringSuppressedCallIds = <String>{};

  /// Ongoing rooms learned from periodic announces, keyed by group hex —
  /// feeds the chat-header "group call in progress" banner. Purely passive.
  final Map<String, ActiveGroupRoom> _knownRooms = <String, ActiveGroupRoom>{};

  /// Bumped whenever [_knownRooms] changes so banner widgets can listen
  /// without the service pushing full call snapshots at them.
  final ValueNotifier<int> roomsRevision = ValueNotifier<int>(0);

  GroupCall? get current => _current;
  GroupCallMediaController? get mediaController => _media;
  Stream<GroupCall?> get changes => _changes.stream;

  void start() {
    if (_started) return;
    _started = true;
    _groups.changes.addListener(_onGroupChanged);
    _subscription = _groups.groupCallIncoming.listen(
      (signal) => unawaited(_onSignal(signal)),
    );
    _screenShareStoppedSubscription = _media?.screenShareStopped.listen((_) {
      if (_current?.screenOn == true) {
        unawaited(setScreenShareEnabled(false));
      }
    });
  }

  void _onGroupChanged() => unawaited(_reconcileMembership());

  /// The call this pass was about, as it stands NOW — or null if it is no
  /// longer the one to publish against.
  ///
  /// Every pass in here starts by taking `_current` into a local, then awaits
  /// the group state, an admission read or a broadcast. What comes back is a
  /// decision about the call as it was; publishing it as `was.copyWith(...)`
  /// writes back the WHOLE snapshot, so anything the person changed while the
  /// awaits ran — a mic toggled, a camera turned on, a peer joined — is
  /// silently undone, and an ended call can be put back on screen as live
  /// (report14 X14-M7).
  ///
  /// Matching the id is not enough on its own: it says the room is the same
  /// room, not that the snapshot is still the truth about it. So the caller
  /// takes the CURRENT one from here and merges only the fields it owns.
  GroupCall? _stillCurrent(GroupCall was) {
    final live = _current;
    if (live == null || live.callId != was.callId || !live.isLive) return null;
    return live;
  }

  Future<void> _reconcileMembership() async {
    final call = _current;
    if (call == null || !call.isLive) return;
    final state = await _groups.stateOf(call.groupId);
    final admission = await _groups.currentVoiceChannelAdmission(
      call.groupId,
      call.channelId,
    );
    if (state == null ||
        admission == null ||
        !admission.recipients.contains(_groups.selfId)) {
      // Against the room this verdict was computed FOR, the same check the
      // participant update below already makes. Both reads above are awaited,
      // and a room can end and another begin while they run — so an exclusion
      // decided about the old one used to end whichever room happened to be
      // current when it landed.
      if (_current?.callId == call.callId) {
        _end(CallEndReason.error, roomOver: true);
      }
      return;
    }
    // From here on the CURRENT call, not the snapshot this pass started from:
    // the two reads above are awaited, and what they say about membership must
    // be merged onto whatever else has happened meanwhile.
    final live = _stillCurrent(call);
    if (live == null) return;
    final participants = Map<String, GroupCallParticipant>.from(
      live.participants,
    );
    participants.removeWhere(
      (hex, participant) =>
          state.members[hex] == null ||
          !admission.recipients.contains(participant.nodeId),
    );
    final epochChanged = state.epoch != live.membershipEpoch;
    final channelEpochChanged = admission.channelEpoch != live.channelEpoch;
    if (participants.length != live.participants.length ||
        epochChanged ||
        channelEpochChanged) {
      _set(
        live.copyWith(
          membershipEpoch: state.epoch,
          channelEpoch: admission.channelEpoch,
          participants: participants,
        ),
      );
      await _syncMedia();
      if ((epochChanged || channelEpochChanged) &&
          live.isJoined(_groups.selfId)) {
        if (channelEpochChanged) {
          _scheduleChannelEpochReannounces(live.callId, admission.channelEpoch);
        }
        await _reannounce();
      }
    }
  }

  Future<bool> startCall(
    NodeId groupId,
    CallMedia media, {
    NodeId? channelId,
  }) async {
    if (media.isEmpty || (_current?.isLive ?? false) || _otherCallBusy()) {
      return false;
    }
    if (!_takeSlot()) return false;
    final state = await _groups.stateOf(groupId);
    final admission = await _groups.currentVoiceChannelAdmission(
      groupId,
      channelId,
    );
    if (_disposed ||
        state == null ||
        admission == null ||
        !admission.recipients.contains(_groups.selfId)) {
      // Only the lease this call took — which is now what `release` means.
      _releaseSlot();
      return false;
    }
    final now = _now();
    final call = GroupCall(
      groupId: groupId,
      channelId: channelId,
      channelEpoch: admission.channelEpoch,
      callId: _uuid.v4(),
      initiator: _groups.selfId,
      membershipEpoch: state.epoch,
      media: media,
      status: GroupCallStatus.connecting,
      startedAt: now,
      joinedAt: now,
      micOn: media.audio,
      cameraOn: media.video && !media.screen,
      screenOn: media.screen,
      participants: {
        _groups.selfId.hex: GroupCallParticipant(
          nodeId: _groups.selfId,
          media: media,
          joinedAt: now,
          lastSeenAt: now,
          mediaUpdatedAtMs: now.millisecondsSinceEpoch,
        ),
      },
    );
    _set(call);
    final sent = await _groups.broadcastGroupCallSignal(
      groupId,
      channelId: channelId,
      callId: call.callId,
      type: GroupCallSignalType.announce,
      media: media,
    );
    if (sent == null) {
      _end(CallEndReason.error, roomOver: true);
      return false;
    }
    // The broadcast is an await too. A teardown landing there left this
    // continuation to arm two periodic timers on a disposed service and
    // report success — `_startMedia` already refused, so the timers were the
    // whole of it, and they never stop (report19 XV19-H1).
    if (!_stillOn(call)) return false;
    _startTimers();
    unawaited(_startMedia(call.callId));
    return true;
  }

  Future<bool> join() async {
    final call = _current;
    if (call == null ||
        !call.isLive ||
        call.status != GroupCallStatus.ringing ||
        _otherCallBusy()) {
      return false;
    }
    final state = await _groups.stateOf(call.groupId);
    final admission = await _groups.currentVoiceChannelAdmission(
      call.groupId,
      call.channelId,
    );
    if (state == null || admission == null) {
      // TRANSIENT unavailability: the group snapshot or the (possibly
      // rotated) channel admission simply has not arrived yet — announces
      // and control frames ride the relay and can lag the ring by tens of
      // seconds. Ending the room here turned every eager join into
      // "join → ended" on the live stand (2026-07-24). Keep ringing so a
      // retry (user tap, hook, or the next announce) can succeed.
      devLog(
        () =>
            'xVeil[group-call]: join deferred — '
            '${state == null ? 'group state' : 'channel admission'} '
            'not available yet (still ringing)',
      );
      return false;
    }
    if (!admission.recipients.contains(_groups.selfId)) {
      // AUTHORITATIVE exclusion: the admission is present and we are not in
      // it — kicked or channel membership revoked. This one is final.
      _end(CallEndReason.error, roomOver: true);
      return false;
    }
    final now = _now();
    final participants =
        Map<String, GroupCallParticipant>.from(call.participants)
          ..[_groups.selfId.hex] = GroupCallParticipant(
            nodeId: _groups.selfId,
            media: call.media,
            joinedAt: now,
            lastSeenAt: now,
            mediaUpdatedAtMs: now.millisecondsSinceEpoch,
          );
    final joined = call.copyWith(
      membershipEpoch: state.epoch,
      channelEpoch: admission.channelEpoch,
      status: GroupCallStatus.connecting,
      joinedAt: now,
      participants: participants,
    );
    if (!_stillOn(call)) return false;
    _set(joined);
    _cancelRingTimer();
    final sent = await _groups.broadcastGroupCallSignal(
      call.groupId,
      channelId: call.channelId,
      callId: call.callId,
      type: GroupCallSignalType.join,
      media: call.media,
    );
    if (sent == null) {
      _end(CallEndReason.error);
      return false;
    }
    if (!_stillOn(call)) return false;
    _startTimers();
    unawaited(_startMedia(call.callId));
    return true;
  }

  Future<void> decline() async {
    final call = _current;
    if (call == null || call.status != GroupCallStatus.ringing) return;
    // Declining is local-only. Broadcasting it would disclose a recipient's
    // choice to the whole group while adding no room state. The room keeps
    // going without us — the banner still offers a way in.
    _end(CallEndReason.declined);
  }

  /// Join an ongoing room from the passive banner: a declined or missed ring,
  /// or re-joining after leave. Adopts the announced room as a local ringing
  /// call, then runs the ordinary join path.
  Future<bool> joinRoom(NodeId groupId, {NodeId? channelId}) async {
    final current = _current;
    if (current != null && current.isLive) return false;
    if (_otherCallBusy()) return false;
    final room = activeRoomFor(groupId, channelId: channelId);
    if (room == null) return false;
    if (!_takeSlot()) return false;
    _suppressRing(room.callId);
    final at = room.lastAnnounceAt;
    _set(
      GroupCall(
        groupId: room.groupId,
        channelId: room.channelId,
        channelEpoch: room.channelEpoch,
        callId: room.callId,
        initiator: room.initiator,
        membershipEpoch: room.membershipEpoch,
        media: room.media,
        status: GroupCallStatus.ringing,
        startedAt: at,
        micOn: room.media.audio,
        cameraOn: room.media.video && !room.media.screen,
        screenOn: room.media.screen,
        participants: {
          room.initiator.hex: GroupCallParticipant(
            nodeId: room.initiator,
            media: room.media,
            joinedAt: at,
            lastSeenAt: _now(),
            mediaUpdatedAtMs: at.millisecondsSinceEpoch,
          ),
        },
      ),
    );
    return join();
  }

  Future<void> leave() async {
    final call = _current;
    if (call == null || !call.isLive) return;
    // Local teardown never waits on the network: the leave broadcast is a
    // durable enqueue PER MEMBER, so awaiting it held the UI "in call" for
    // seconds (same class as the 1:1 hangup fix). A lost leave only costs the
    // peers one liveness timeout before they drop us.
    if (call.isJoined(_groups.selfId)) {
      unawaited(
        _groups.broadcastGroupCallSignal(
          call.groupId,
          channelId: call.channelId,
          callId: call.callId,
          type: GroupCallSignalType.leave,
          reason: CallEndReason.hangup,
        ),
      );
    }
    _end(CallEndReason.hangup);
  }

  Future<bool> endForEveryone() async {
    final call = _current;
    if (call == null || !call.isLive) return false;
    // The permission gate stays synchronous-local (group state read); the
    // room-wide end broadcast rides in the background like every other
    // teardown signal — an admin's hangup must clear the UI instantly.
    final state = await _groups.stateOf(call.groupId);
    final role = state?.roleOf(_groups.selfId);
    if (role == null || role.rank < GroupRole.admin.rank) return false;
    // The permission was checked for THIS call; ending whatever is current
    // instead would end a room this answer says nothing about.
    if (!_stillOn(call)) return false;
    unawaited(
      _groups.broadcastGroupCallSignal(
        call.groupId,
        channelId: call.channelId,
        callId: call.callId,
        type: GroupCallSignalType.end,
        reason: CallEndReason.hangup,
      ),
    );
    _end(CallEndReason.hangup, roomOver: true);
    return true;
  }

  Future<void> setMicEnabled(bool enabled) async {
    final call = _current;
    if (call == null || !call.isLive || call.micOn == enabled) return;
    _set(call.copyWith(micOn: enabled));
    await _media?.setMicMuted(!enabled);
    await _announceMedia();
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final call = _current;
    if (call == null || !call.isLive) return;
    if (!call.media.video) {
      if (!enabled || !(await _media?.setVideoEnabled(true) ?? false)) return;
      final current = _current;
      if (current == null || !current.isLive || current.callId != call.callId) {
        return;
      }
      _set(
        current.copyWith(
          media: current.media.copyWith(video: true),
          cameraOn: true,
        ),
      );
      await _media?.setCameraEnabled(true);
      await _announceMedia();
      return;
    }
    if (call.cameraOn == enabled) return;
    _set(call.copyWith(cameraOn: enabled));
    if (!call.screenOn) await _media?.setCameraEnabled(enabled);
    await _announceMedia();
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    final call = _current;
    if (call == null ||
        !call.isLive ||
        !call.media.video ||
        call.screenOn == enabled) {
      return;
    }
    if (enabled && !(await _media?.setScreenShareEnabled(true) ?? false)) {
      return;
    }
    if (!enabled) {
      await _media?.setScreenShareEnabled(false);
      if (call.cameraOn) await _media?.setCameraEnabled(true);
    }
    // THE CALL IS RE-READ AFTER THE I/O, the way `setCameraEnabled` does it
    // one method up. Everything above awaits the native engine, and the room
    // can end or be replaced while that runs — `call` is a snapshot from
    // before it. Publishing `call.copyWith(...)` then wrote the OLD room back
    // over whatever is current: an ended call came back live, carrying its own
    // callId, with no timers and no media behind it.
    final current = _current;
    if (current == null || !current.isLive || current.callId != call.callId) {
      return;
    }
    _set(current.copyWith(screenOn: enabled));
    await _announceMedia();
  }

  Future<List<CallMediaDevice>> listScreens() =>
      _media?.listScreens() ?? Future.value(const []);

  Future<bool> selectScreen(String id) async {
    final call = _current;
    if (call == null || !call.isLive) return false;
    return await _media?.selectScreen(id) ?? false;
  }

  bool get screenCaptureAccessGranted =>
      _media?.screenCaptureAccessGranted ?? true;

  bool requestScreenCaptureAccess() =>
      _media?.requestScreenCaptureAccess() ?? true;

  Future<void> _announceMedia() async {
    var call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    final media = _localMedia(call);
    final now = _now();
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    final self = participants[_groups.selfId.hex];
    if (self != null) {
      participants[_groups.selfId.hex] = self.copyWith(
        media: media,
        lastSeenAt: now,
        mediaUpdatedAtMs: now.millisecondsSinceEpoch,
      );
      call = call.copyWith(participants: participants);
      _set(call);
    }
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      channelId: call.channelId,
      callId: call.callId,
      type: GroupCallSignalType.renegotiate,
      media: media,
    );
  }

  Future<void> _onSignal(GroupCallSignal signal) async {
    var call = _current;
    if (signal.type == GroupCallSignalType.announce) {
      if (_isEndedCall(signal.groupId, signal.callId)) return;
      // Every announce for a room that is not known-dead keeps the passive
      // banner alive — including ones that must not ring (already declined,
      // busy in another call, no free slot).
      _recordRoom(signal);
      if (call == null || !call.isLive) {
        if (_ringSuppressedCallIds.contains(signal.callId)) return;
        if (_otherCallBusy()) return;
        if (!_takeSlot()) return;
        final at = DateTime.fromMillisecondsSinceEpoch(signal.sentAtMs);
        final media = signal.media!;
        call = GroupCall(
          groupId: signal.groupId,
          channelId: signal.channelId,
          channelEpoch: signal.channelEpoch,
          callId: signal.callId,
          initiator: signal.author,
          membershipEpoch: signal.membershipEpoch,
          media: media,
          status: GroupCallStatus.ringing,
          startedAt: at,
          micOn: media.audio,
          cameraOn: media.video && !media.screen,
          screenOn: media.screen,
          participants: {
            signal.author.hex: GroupCallParticipant(
              nodeId: signal.author,
              media: media,
              joinedAt: at,
              lastSeenAt: _now(),
              mediaUpdatedAtMs: signal.sentAtMs,
            ),
          },
        );
        _set(call);
        _armRingTimer();
        return;
      }
      if (call.groupId != signal.groupId ||
          call.channelId != signal.channelId) {
        return;
      }
      if (call.callId != signal.callId) {
        // Simultaneous rooms converge on the lexicographically smaller id.
        if (signal.callId.compareTo(call.callId) >= 0) return;
        _end(CallEndReason.cancelled);
        await _onSignal(signal);
        return;
      }
      // Announce carries room capabilities so a peer that missed join can be
      // reconstructed. For an already-known participant it is only presence:
      // applying those capabilities would turn their muted mic/camera back on.
      _touchParticipant(
        signal,
        joinedIfMissing: true,
        foldExistingMedia: false,
      );
      return;
    }
    // Durable lifecycle frames are intentionally short-lived but may reorder.
    // Remember an authenticated admin end even when its announce has not
    // arrived yet, so end-before-announce cannot resurrect a phantom ring.
    if (signal.type == GroupCallSignalType.end &&
        (call == null ||
            !call.isLive ||
            call.groupId != signal.groupId ||
            call.callId != signal.callId)) {
      final state = await _groups.stateOf(signal.groupId);
      final role = state?.roleOf(signal.author);
      if (role != null && role.rank >= GroupRole.admin.rank) {
        _rememberEndedCall(signal.groupId, signal.callId);
        _forgetRoom(signal.groupId, signal.channelId);
      }
      return;
    }
    if (call == null ||
        !call.isLive ||
        call.groupId != signal.groupId ||
        call.channelId != signal.channelId ||
        call.callId != signal.callId) {
      return;
    }
    switch (signal.type) {
      case GroupCallSignalType.join:
        final rejoined = call.participants.containsKey(signal.author.hex);
        _touchParticipant(signal, joinedIfMissing: true);
        if (rejoined) {
          // The peer restarted its media session (leave/crash/app restart);
          // the channel we opened toward its previous session is dead.
          await _media?.invalidatePeerChannel(signal.author);
        }
        await _syncMedia();
      case GroupCallSignalType.leave:
        _removeParticipant(signal.author);
      case GroupCallSignalType.end:
        final state = await _groups.stateOf(call.groupId);
        final role = state?.roleOf(signal.author);
        // The role was read for THIS room. `_end` acts on whatever is current,
        // so without this an admin of room A, arriving after a switch, ended
        // room B — an authorization fact applied to a different object
        // (report19 XV19-H1).
        if (role != null &&
            role.rank >= GroupRole.admin.rank &&
            _stillOn(call)) {
          _end(signal.reason ?? CallEndReason.hangup, roomOver: true);
        }
      case GroupCallSignalType.heartbeat:
        _touchParticipant(signal, joinedIfMissing: false);
      case GroupCallSignalType.renegotiate:
        _touchParticipant(signal, joinedIfMissing: false);
        await _syncMedia();
      case GroupCallSignalType.busy:
        // Busy is per-recipient feedback, not a room-wide terminal event.
        break;
      case GroupCallSignalType.announce:
      case GroupCallSignalType.unknown:
        break;
    }
  }

  void _touchParticipant(
    GroupCallSignal signal, {
    required bool joinedIfMissing,
    bool foldExistingMedia = true,
  }) {
    final call = _current;
    if (call == null) return;
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    final existing = participants[signal.author.hex];
    if (existing == null && !joinedIfMissing) return;
    final now = _now();
    final incomingMedia = signal.media;
    final applyMedia =
        incomingMedia != null &&
        (existing == null ||
            (foldExistingMedia &&
                signal.sentAtMs >= existing.mediaUpdatedAtMs));
    participants[signal.author.hex] = existing == null
        ? GroupCallParticipant(
            nodeId: signal.author,
            media: incomingMedia ?? call.media,
            joinedAt: now,
            lastSeenAt: now,
            mediaUpdatedAtMs: incomingMedia == null ? 0 : signal.sentAtMs,
          )
        : existing.copyWith(
            media: applyMedia ? incomingMedia : null,
            lastSeenAt: now,
            mediaUpdatedAtMs: applyMedia ? signal.sentAtMs : null,
          );
    _set(call.copyWith(participants: participants));
  }

  void _removeParticipant(NodeId peer) {
    final call = _current;
    if (call == null) return;
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    )..remove(peer.hex);
    _set(call.copyWith(participants: participants));
    unawaited(_syncMedia());
  }

  Future<void> _startMedia(String callId) async {
    final controller = _media;
    final call = _current;
    if (controller == null ||
        call == null ||
        call.callId != callId ||
        call.status != GroupCallStatus.connecting) {
      return;
    }
    bool ready = false;
    try {
      ready = await controller.start(call);
    } catch (_) {
      ready = false;
    }
    final current = _current;
    if (ready &&
        current != null &&
        current.callId == callId &&
        current.status == GroupCallStatus.connecting) {
      _set(current.copyWith(status: GroupCallStatus.active));
    }
  }

  Future<void> _syncMedia() async {
    final call = _current;
    if (call == null ||
        !call.isLive ||
        !call.isJoined(_groups.selfId) ||
        _media == null) {
      return;
    }
    await _media.update(call);
  }

  void _startTimers() {
    _heartbeatTimer ??= Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_heartbeat());
    });
    _reannounceTimer ??= Timer.periodic(_reannounceInterval, (_) {
      unawaited(_reannounce());
    });
  }

  CallMedia _localMedia(GroupCall call) => CallMedia(
    audio: call.micOn,
    video: call.media.video && call.cameraOn,
    screen: call.media.video && call.screenOn,
  );

  /// A media circuit can silently black-hole: the sender's channel resolved a
  /// stale rendezvous (peer restarted moments earlier) and every datagram is
  /// swallowed downstream while the local enqueue keeps "succeeding" — the
  /// native no-route self-heal never fires (live stand, 2026-07-24: restarted
  /// pair, mac→phone audio flowed, phone→mac stayed at zero packets forever).
  /// Only the RECEIVER can see the silence, so it re-announces its own JOIN;
  /// the repeat-join handler on every peer invalidates its channel toward us
  /// and re-dials with a fresh rendezvous resolve.
  void _maybeRequestMediaRepair(GroupCall call) {
    final media = _media;
    if (media == null) return;
    final now = _now();
    var starved = false;
    for (final participant in call.participants.values) {
      if (participant.nodeId == _groups.selfId) continue;
      // A muted peer legitimately sends nothing.
      if (!participant.media.audio) continue;
      if (now.difference(participant.joinedAt) < kGroupCallMediaRepairSilence) {
        continue;
      }
      final rxAt = media.lastMediaRxAt(participant.nodeId);
      if (rxAt == null || now.difference(rxAt) > kGroupCallMediaRepairSilence) {
        starved = true;
        break;
      }
    }
    if (!starved) return;
    final last = _lastMediaRepairJoinAt;
    if (last != null &&
        now.difference(last) < kGroupCallMediaRepairMinInterval) {
      return;
    }
    _lastMediaRepairJoinAt = now;
    devLog(
      () =>
          'xVeil[group-call]: no media from a live unmuted participant — '
          're-announcing join so peers re-dial our channel',
    );
    unawaited(
      _groups.broadcastGroupCallSignal(
        call.groupId,
        channelId: call.channelId,
        callId: call.callId,
        type: GroupCallSignalType.join,
        media: _localMedia(call),
      ),
    );
  }

  Future<void> _heartbeat() async {
    final call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      channelId: call.channelId,
      callId: call.callId,
      type: GroupCallSignalType.heartbeat,
      // A renegotiation is a live frame and can be lost. Every heartbeat
      // repeats the current posture so peers converge within one liveness tick
      // instead of retaining a stale mic/camera state indefinitely.
      media: _localMedia(call),
    );
    _maybeRequestMediaRepair(call);
    // The broadcast above is awaited, so the liveness verdict below has to be
    // computed against — and written back onto — the call as it stands now.
    final live = _stillCurrent(call);
    if (live == null) return;
    final now = _now();
    final participants = Map<String, GroupCallParticipant>.from(
      live.participants,
    );
    var changed = false;
    for (final participant in live.participants.values) {
      if (participant.nodeId == _groups.selfId) continue;
      final mediaAt = _media?.lastMediaRxAt(participant.nodeId);
      final aliveAt = mediaAt != null && mediaAt.isAfter(participant.lastSeenAt)
          ? mediaAt
          : participant.lastSeenAt;
      if (now.difference(aliveAt) > kGroupCallLivenessTimeout) {
        participants.remove(participant.nodeId.hex);
        changed = true;
      }
    }
    if (changed) {
      _set(live.copyWith(participants: participants));
      await _syncMedia();
    }
  }

  Future<void> _reannounce() async {
    final call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      channelId: call.channelId,
      callId: call.callId,
      type: GroupCallSignalType.announce,
      // Announce remains the non-empty room capability for a peer that missed
      // join. Existing peers treat it as presence-only; heartbeat carries the
      // current (possibly all-off) posture every five seconds.
      media: call.media,
    );
  }

  void _scheduleChannelEpochReannounces(String callId, int? channelEpoch) {
    _cancelChannelEpochReannounces();
    for (final delay in _channelEpochReannounceDelays) {
      if (delay.isNegative) continue;
      _channelEpochReannounceTimers.add(
        Timer(delay, () {
          final call = _current;
          if (call == null ||
              !call.isLive ||
              call.callId != callId ||
              call.channelEpoch != channelEpoch) {
            return;
          }
          unawaited(_reannounce());
        }),
      );
    }
  }

  void _cancelChannelEpochReannounces() {
    for (final timer in _channelEpochReannounceTimers) {
      timer.cancel();
    }
    _channelEpochReannounceTimers.clear();
  }

  void _armRingTimer() {
    _cancelRingTimer();
    _ringTimer = Timer(kGroupCallRingTimeout, () {
      final call = _current;
      if (call != null && call.status == GroupCallStatus.ringing) {
        _end(CallEndReason.timeout);
      }
    });
  }

  void _cancelRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  /// Is [call] still the call this service is on?
  ///
  /// The mutators below read `_current` at entry, await the group state and
  /// the channel admission, and then act — publishing, broadcasting, ending.
  /// Between those two moments the room can change or the service can be torn
  /// down, and every one of them used to act anyway: `join` could publish a
  /// room the service had left, and the two end paths checked permission on
  /// call A and then ended whatever call was current (report18 XV18-H1).
  bool _stillOn(GroupCall call) {
    final live = _current;
    return !_disposed &&
        live != null &&
        // ENDED IS NOT STILL ON. `_end` leaves the same call in `_current`
        // with `status: ended` — the banner and the "who was in it" survive on
        // purpose — and this compared only the three ids, so a continuation
        // parked across an await came back to a call that was over and was
        // told it was current. It then started the heartbeat and the
        // re-announce timers and asked for media for a call nobody is in
        // (report21 XV20-L1). The two admin paths below reach `_end` through
        // it, which without this ran the whole teardown a second time.
        live.isLive &&
        live.callId == call.callId &&
        live.groupId == call.groupId &&
        live.channelId == call.channelId;
  }

  void _set(GroupCall call) {
    // Nothing is published after teardown, or a late continuation puts the
    // call back and undoes the boundary in [dispose].
    if (_disposed) return;
    _current = call;
    if (!_changes.isClosed) _changes.add(call);
  }

  Future<void> _stopMediaAndReleaseSlot() async {
    try {
      await _media?.stop();
    } catch (_) {
      // Teardown is best-effort, but the global slot must never leak.
    } finally {
      _releaseSlot();
    }
  }

  void _end(CallEndReason reason, {bool roomOver = false}) {
    final call = _current;
    if (call == null) return;
    if (roomOver) {
      // The room itself is finished (admin end / membership lost): bury the
      // call id and drop the banner.
      _rememberEndedCall(call.groupId, call.callId);
      _forgetRoom(call.groupId, call.channelId);
    } else {
      // WE left the room (decline / missed / hangup) but it keeps going for
      // the others: never ring this call id again, keep the banner offer.
      _suppressRing(call.callId);
    }
    _cancelRingTimer();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reannounceTimer?.cancel();
    _reannounceTimer = null;
    _cancelChannelEpochReannounces();
    if (_media == null) {
      _releaseSlot();
    } else {
      unawaited(_stopMediaAndReleaseSlot());
    }
    _set(
      call.copyWith(
        status: GroupCallStatus.ended,
        endedAt: _now(),
        endReason: reason,
      ),
    );
  }

  void _recordRoom(GroupCallSignal signal) {
    final media = signal.media;
    if (media == null || media.isEmpty) return;
    _pruneRooms();
    _knownRooms[_roomKey(signal.groupId, signal.channelId)] = ActiveGroupRoom(
      groupId: signal.groupId,
      channelId: signal.channelId,
      channelEpoch: signal.channelEpoch,
      callId: signal.callId,
      initiator: signal.author,
      membershipEpoch: signal.membershipEpoch,
      media: media,
      lastAnnounceAt: _now(),
    );
    roomsRevision.value++;
  }

  String _roomKey(NodeId groupId, NodeId? channelId) =>
      '${groupId.hex}:${channelId?.hex ?? "legacy"}';

  void _forgetRoom(NodeId groupId, NodeId? channelId) {
    if (_knownRooms.remove(_roomKey(groupId, channelId)) != null) {
      roomsRevision.value++;
    }
  }

  void _pruneRooms() {
    final now = _now();
    final before = _knownRooms.length;
    _knownRooms.removeWhere(
      (_, room) => now.difference(room.lastAnnounceAt) > kGroupCallRoomTtl,
    );
    if (_knownRooms.length != before) roomsRevision.value++;
  }

  void _suppressRing(String callId) {
    while (_ringSuppressedCallIds.length > 256) {
      _ringSuppressedCallIds.remove(_ringSuppressedCallIds.first);
    }
    _ringSuppressedCallIds.add(callId);
  }

  /// The ongoing room to offer in [groupId]'s banner, or null. The room we
  /// are currently inside is excluded — the in-call UI owns that state.
  ActiveGroupRoom? activeRoomFor(NodeId groupId, {NodeId? channelId}) {
    _pruneRooms();
    final room = _knownRooms[_roomKey(groupId, channelId)];
    if (room == null) return null;
    final call = _current;
    if (call != null && call.isLive && call.callId == room.callId) return null;
    return room;
  }

  String _endedCallKey(NodeId groupId, String callId) =>
      '${groupId.hex}:$callId';

  void _pruneEndedCalls() {
    final now = _now();
    _endedCallTombstones.removeWhere(
      (_, endedAt) => now.difference(endedAt) > kGroupCallTombstoneTtl,
    );
    while (_endedCallTombstones.length > 256) {
      _endedCallTombstones.remove(_endedCallTombstones.keys.first);
    }
  }

  void _rememberEndedCall(NodeId groupId, String callId) {
    _pruneEndedCalls();
    _endedCallTombstones[_endedCallKey(groupId, callId)] = _now();
  }

  bool _isEndedCall(NodeId groupId, String callId) {
    _pruneEndedCalls();
    return _endedCallTombstones.containsKey(_endedCallKey(groupId, callId));
  }

  /// Torn down. Marked before anything else, and it clears the call.
  ///
  /// `startCall` awaits the group state and the voice-channel admission, then
  /// publishes, broadcasts an announce, arms the timers and starts media —
  /// with nothing between those awaits and those side effects. `dispose` stops
  /// the timers, the media and the slot, so the announce went out and the
  /// media started with no exclusive lease behind them, from an identity the
  /// app had already left (report18 XV18-H1). `join`, `endForEveryone` and the
  /// admin branch of `_onSignal` are the same shape.
  bool _disposed = false;

  /// This room's claim on the device's one media stack, while it holds one.
  ///
  /// Held rather than re-derived: the slot compares LEASES now, so a teardown
  /// arriving after its call is gone releases nothing instead of clearing its
  /// successor's claim (report19 XV19-H4).
  CallSlotLease? _slotLease;

  /// Take the slot for this room. False means somebody else has it.
  ///
  /// A null slot is the test wiring and always succeeds. Refuses outright once
  /// disposed: a continuation acquiring after teardown holds a lease nothing
  /// gives back, and every later call is refused.
  bool _takeSlot() {
    if (_disposed) return false;
    final slot = _callSlot;
    if (slot == null) return true;
    final lease = slot.acquire(CallSlotOwner.group);
    if (lease == null) return false;
    _slotLease = lease;
    return true;
  }

  /// Give up this room's claim, if it still holds one.
  void _releaseSlot() {
    final lease = _slotLease;
    _slotLease = null;
    _callSlot?.release(lease);
  }

  Future<void> dispose() async {
    _disposed = true;
    _current = null;
    _groups.changes.removeListener(_onGroupChanged);
    _cancelRingTimer();
    _heartbeatTimer?.cancel();
    _reannounceTimer?.cancel();
    _cancelChannelEpochReannounces();
    await _subscription?.cancel();
    await _screenShareStoppedSubscription?.cancel();
    await _stopMediaAndReleaseSlot();
    await _changes.close();
  }
}

final groupCallServiceProvider = Provider<GroupCallService?>((ref) {
  final groups = ref.watch(groupServiceProvider);
  if (groups == null) return null;
  final directCalls = ref.watch(callServiceProvider);
  final transport = ref.read(veilTransportProvider);
  final service = GroupCallService(
    groups,
    media:
        transport is VeilFlutterTransport &&
            VeilGroupCallMediaController.isSupportedPlatform
        ? VeilGroupCallMediaController(
            VeilGroupMediaChannelTransport(transport),
            roomMediaSecret: (call) => groups.groupCallMediaSecret(
              groupId: call.groupId,
              channelId: call.channelId,
              channelEpoch: call.channelEpoch,
              membershipEpoch: call.membershipEpoch,
              callId: call.callId,
            ),
          )
        : null,
    callSlot: ref.read(callSlotProvider),
    otherCallBusy: () => directCalls.current?.isLive ?? false,
  )..start();
  ref.onDispose(service.dispose);
  return service;
});

final currentGroupCallProvider = StreamProvider<GroupCall?>((ref) async* {
  final service = ref.watch(groupCallServiceProvider);
  if (service == null) {
    yield null;
    return;
  }
  yield service.current;
  yield* service.changes;
});
