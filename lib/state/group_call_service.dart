import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../domain/call_signal.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import 'call_service.dart';
import 'call_slot.dart';
import 'group_service.dart';

const _uuid = Uuid();
const Duration kGroupCallRingTimeout = Duration(seconds: 45);
const Duration kGroupCallHeartbeatInterval = Duration(seconds: 5);
const Duration kGroupCallLivenessTimeout = Duration(seconds: 20);
const Duration kGroupCallReannounceInterval = Duration(seconds: 60);

/// Native/media-plane boundary for an N-party room. The control FSM is useful
/// and fully testable independently, while the production implementation owns
/// one capture/mixer and a membership-synchronized set of peer channels.
abstract class GroupCallMediaController {
  Future<bool> start(GroupCall call);
  Future<void> update(GroupCall call);
  Future<void> stop();
  Future<void> setMicMuted(bool muted) async {}
  Future<void> setCameraEnabled(bool enabled) async {}
  Future<bool> setScreenShareEnabled(bool enabled) async => false;
  DateTime? lastMediaRxAt(NodeId peer) => null;
}

class GroupCallService {
  GroupCallService(
    this._groups, {
    GroupCallMediaController? media,
    CallSlot? callSlot,
    DateTime Function()? now,
    bool Function()? otherCallBusy,
  }) : // Named public `media:` parameter intentionally initializes private field.
       // ignore: prefer_initializing_formals
       _media = media,
       // ignore: prefer_initializing_formals
       _callSlot = callSlot,
       _now = now ?? DateTime.now,
       _otherCallBusy = otherCallBusy ?? (() => false);

  final GroupService _groups;
  final GroupCallMediaController? _media;
  final CallSlot? _callSlot;
  final DateTime Function() _now;
  final bool Function() _otherCallBusy;
  final StreamController<GroupCall?> _changes = StreamController.broadcast();

  StreamSubscription<GroupCallSignal>? _subscription;
  Timer? _ringTimer;
  Timer? _heartbeatTimer;
  Timer? _reannounceTimer;
  GroupCall? _current;
  bool _started = false;

  GroupCall? get current => _current;
  Stream<GroupCall?> get changes => _changes.stream;

  void start() {
    if (_started) return;
    _started = true;
    _groups.changes.addListener(_onGroupChanged);
    _subscription = _groups.groupCallIncoming.listen(
      (signal) => unawaited(_onSignal(signal)),
    );
  }

  void _onGroupChanged() => unawaited(_reconcileMembership());

  Future<void> _reconcileMembership() async {
    final call = _current;
    if (call == null || !call.isLive) return;
    final state = await _groups.stateOf(call.groupId);
    if (state == null || !state.isMember(_groups.selfId)) {
      _end(CallEndReason.error);
      return;
    }
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    participants.removeWhere((hex, _) => !state.members.containsKey(hex));
    final epochChanged = state.epoch != call.membershipEpoch;
    if ((participants.length != call.participants.length || epochChanged) &&
        _current?.callId == call.callId) {
      _set(
        call.copyWith(membershipEpoch: state.epoch, participants: participants),
      );
      await _syncMedia();
      if (epochChanged && call.isJoined(_groups.selfId)) {
        await _reannounce();
      }
    }
  }

  Future<bool> startCall(NodeId groupId, CallMedia media) async {
    if (media.isEmpty || (_current?.isLive ?? false) || _otherCallBusy()) {
      return false;
    }
    if (!(_callSlot?.acquire(CallSlotOwner.group) ?? true)) return false;
    final state = await _groups.stateOf(groupId);
    if (state == null || !state.isMember(_groups.selfId)) {
      _callSlot?.release(CallSlotOwner.group);
      return false;
    }
    final now = _now();
    final call = GroupCall(
      groupId: groupId,
      callId: _uuid.v4(),
      initiator: _groups.selfId,
      membershipEpoch: state.epoch,
      media: media,
      status: GroupCallStatus.connecting,
      startedAt: now,
      joinedAt: now,
      participants: {
        _groups.selfId.hex: GroupCallParticipant(
          nodeId: _groups.selfId,
          media: media,
          joinedAt: now,
          lastSeenAt: now,
        ),
      },
    );
    _set(call);
    final sent = await _groups.broadcastGroupCallSignal(
      groupId,
      callId: call.callId,
      type: GroupCallSignalType.announce,
      media: media,
    );
    if (sent == null) {
      _end(CallEndReason.error);
      return false;
    }
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
    if (state == null || !state.isMember(_groups.selfId)) {
      _end(CallEndReason.error);
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
          );
    final joined = call.copyWith(
      membershipEpoch: state.epoch,
      status: GroupCallStatus.connecting,
      joinedAt: now,
      participants: participants,
    );
    _set(joined);
    _cancelRingTimer();
    final sent = await _groups.broadcastGroupCallSignal(
      call.groupId,
      callId: call.callId,
      type: GroupCallSignalType.join,
      media: call.media,
    );
    if (sent == null) {
      _end(CallEndReason.error);
      return false;
    }
    _startTimers();
    unawaited(_startMedia(call.callId));
    return true;
  }

  Future<void> decline() async {
    final call = _current;
    if (call == null || call.status != GroupCallStatus.ringing) return;
    // Declining is local-only. Broadcasting it would disclose a recipient's
    // choice to the whole group while adding no room state.
    _end(CallEndReason.declined);
  }

  Future<void> leave() async {
    final call = _current;
    if (call == null || !call.isLive) return;
    if (call.isJoined(_groups.selfId)) {
      await _groups.broadcastGroupCallSignal(
        call.groupId,
        callId: call.callId,
        type: GroupCallSignalType.leave,
        reason: CallEndReason.hangup,
      );
    }
    _end(CallEndReason.hangup);
  }

  Future<bool> endForEveryone() async {
    final call = _current;
    if (call == null || !call.isLive) return false;
    final state = await _groups.stateOf(call.groupId);
    final role = state?.roleOf(_groups.selfId);
    if (role == null || role.rank < GroupRole.admin.rank) return false;
    final sent = await _groups.broadcastGroupCallSignal(
      call.groupId,
      callId: call.callId,
      type: GroupCallSignalType.end,
      reason: CallEndReason.hangup,
    );
    if (sent == null) return false;
    _end(CallEndReason.hangup);
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
    if (call == null ||
        !call.isLive ||
        !call.media.video ||
        call.cameraOn == enabled) {
      return;
    }
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
    _set(call.copyWith(screenOn: enabled));
    await _announceMedia();
  }

  Future<void> _announceMedia() async {
    var call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    final media = CallMedia(
      audio: call.micOn,
      video: call.media.video && call.cameraOn,
      screen: call.media.video && call.screenOn,
    );
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    final self = participants[_groups.selfId.hex];
    if (self != null) {
      participants[_groups.selfId.hex] = self.copyWith(
        media: media,
        lastSeenAt: _now(),
      );
      call = call.copyWith(participants: participants);
      _set(call);
    }
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      callId: call.callId,
      type: GroupCallSignalType.renegotiate,
      media: media,
    );
  }

  Future<void> _onSignal(GroupCallSignal signal) async {
    var call = _current;
    if (signal.type == GroupCallSignalType.announce) {
      if (call == null || !call.isLive) {
        if (_otherCallBusy()) return;
        if (!(_callSlot?.acquire(CallSlotOwner.group) ?? true)) return;
        final at = DateTime.fromMillisecondsSinceEpoch(signal.sentAtMs);
        final media = signal.media!;
        call = GroupCall(
          groupId: signal.groupId,
          callId: signal.callId,
          initiator: signal.author,
          membershipEpoch: signal.membershipEpoch,
          media: media,
          status: GroupCallStatus.ringing,
          startedAt: at,
          participants: {
            signal.author.hex: GroupCallParticipant(
              nodeId: signal.author,
              media: media,
              joinedAt: at,
              lastSeenAt: _now(),
            ),
          },
        );
        _set(call);
        _armRingTimer();
        return;
      }
      if (call.groupId != signal.groupId) return;
      if (call.callId != signal.callId) {
        // Simultaneous rooms converge on the lexicographically smaller id.
        if (signal.callId.compareTo(call.callId) >= 0) return;
        _end(CallEndReason.cancelled);
        await _onSignal(signal);
        return;
      }
      _touchParticipant(signal, joinedIfMissing: true);
      return;
    }
    if (call == null ||
        !call.isLive ||
        call.groupId != signal.groupId ||
        call.callId != signal.callId) {
      return;
    }
    switch (signal.type) {
      case GroupCallSignalType.join:
        _touchParticipant(signal, joinedIfMissing: true);
        await _syncMedia();
      case GroupCallSignalType.leave:
        _removeParticipant(signal.author);
      case GroupCallSignalType.end:
        final state = await _groups.stateOf(call.groupId);
        final role = state?.roleOf(signal.author);
        if (role != null && role.rank >= GroupRole.admin.rank) {
          _end(signal.reason ?? CallEndReason.hangup);
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
  }) {
    final call = _current;
    if (call == null) return;
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    final existing = participants[signal.author.hex];
    if (existing == null && !joinedIfMissing) return;
    final now = _now();
    participants[signal.author.hex] = existing == null
        ? GroupCallParticipant(
            nodeId: signal.author,
            media: signal.media ?? call.media,
            joinedAt: now,
            lastSeenAt: now,
          )
        : existing.copyWith(media: signal.media, lastSeenAt: now);
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
    _heartbeatTimer ??= Timer.periodic(kGroupCallHeartbeatInterval, (_) {
      unawaited(_heartbeat());
    });
    _reannounceTimer ??= Timer.periodic(kGroupCallReannounceInterval, (_) {
      unawaited(_reannounce());
    });
  }

  Future<void> _heartbeat() async {
    final call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      callId: call.callId,
      type: GroupCallSignalType.heartbeat,
    );
    final now = _now();
    final participants = Map<String, GroupCallParticipant>.from(
      call.participants,
    );
    var changed = false;
    for (final participant in call.participants.values) {
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
    if (changed && _current?.callId == call.callId) {
      _set(call.copyWith(participants: participants));
      await _syncMedia();
    }
  }

  Future<void> _reannounce() async {
    final call = _current;
    if (call == null || !call.isLive || !call.isJoined(_groups.selfId)) return;
    await _groups.broadcastGroupCallSignal(
      call.groupId,
      callId: call.callId,
      type: GroupCallSignalType.announce,
      media: call.media,
    );
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

  void _set(GroupCall call) {
    _current = call;
    if (!_changes.isClosed) _changes.add(call);
  }

  Future<void> _stopMediaAndReleaseSlot() async {
    try {
      await _media?.stop();
    } catch (_) {
      // Teardown is best-effort, but the global slot must never leak.
    } finally {
      _callSlot?.release(CallSlotOwner.group);
    }
  }

  void _end(CallEndReason reason) {
    final call = _current;
    if (call == null) return;
    _cancelRingTimer();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reannounceTimer?.cancel();
    _reannounceTimer = null;
    if (_media == null) {
      _callSlot?.release(CallSlotOwner.group);
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

  Future<void> dispose() async {
    _groups.changes.removeListener(_onGroupChanged);
    _cancelRingTimer();
    _heartbeatTimer?.cancel();
    _reannounceTimer?.cancel();
    await _subscription?.cancel();
    await _stopMediaAndReleaseSlot();
    await _changes.close();
  }
}

final groupCallServiceProvider = Provider<GroupCallService?>((ref) {
  final groups = ref.watch(groupServiceProvider);
  if (groups == null) return null;
  final directCalls = ref.watch(callServiceProvider);
  final service = GroupCallService(
    groups,
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
