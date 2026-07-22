import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service.dart';

final _self = NodeId.fromHex('a' * 64);
final _initiator = NodeId.fromHex('c' * 64);
final _groupId = NodeId.fromHex('b' * 64);

/// Owner = the remote initiator, self = plain member — the shape of "someone
/// else started a call in our group".
GroupState _twoMemberState() => foldControlLog(
  owner: _initiator,
  entries: [
    ControlEntry(
      author: _initiator,
      seq: 1,
      prevHash: '',
      op: ControlOp.addMember,
      target: _self,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(64),
    ),
  ],
  verify: (_) => true,
).state;

class _FakeGroups implements GroupService {
  final List<GroupCallSignalType> sent = [];
  final _incoming = StreamController<GroupCallSignal>.broadcast();

  @override
  // ignore: overridden_fields — the real service exposes a field too.
  final GroupChangeSignal changes = GroupChangeSignal();

  @override
  NodeId get selfId => _self;

  @override
  Stream<GroupCallSignal> get groupCallIncoming => _incoming.stream;

  void push(GroupCallSignal signal) => _incoming.add(signal);

  @override
  Future<GroupState?> stateOf(NodeId groupId) async => _twoMemberState();

  @override
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) async {
    sent.add(type);
    return _signal(type, callId: callId, author: _self, media: media);
  }

  Future<void> close() async {
    await _incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GroupCallSignal _signal(
  GroupCallSignalType type, {
  required String callId,
  required NodeId author,
  CallMedia? media,
  CallEndReason? reason,
  int sentAtMs = 1000,
}) => GroupCallSignal(
  groupId: _groupId,
  callId: callId,
  author: author,
  membershipEpoch: 1,
  type: type,
  sentAtMs: sentAtMs,
  nonce: 'aabbccddeeff001122334455',
  signature: Uint8List(64),
  authorPubKey: Uint8List(32),
  media: media,
  reason: reason,
);

void main() {
  test('a declined ring leaves a joinable room and never re-rings', () async {
    final fake = _FakeGroups();
    var now = DateTime(2026, 1, 1, 12);
    final svc = GroupCallService(fake, now: () => now)..start();

    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-1',
        author: _initiator,
        media: const CallMedia(audio: true, video: true),
      ),
    );
    await pumpEventQueue();
    expect(svc.current?.status, GroupCallStatus.ringing);
    // While the local call owns this room the banner stays out of the way.
    expect(svc.activeRoomFor(_groupId), isNull);

    await svc.decline();
    expect(svc.current?.status, GroupCallStatus.ended);
    final room = svc.activeRoomFor(_groupId);
    expect(room, isNotNull, reason: 'the room keeps going without us');
    expect(room!.callId, 'room-1');

    // The next periodic announce refreshes the banner but must NOT ring.
    now = now.add(const Duration(seconds: 60));
    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-1',
        author: _initiator,
        media: const CallMedia(audio: true, video: true),
      ),
    );
    await pumpEventQueue();
    expect(svc.current?.status, GroupCallStatus.ended, reason: 'no re-ring');
    expect(svc.activeRoomFor(_groupId)?.lastAnnounceAt, now);

    await svc.dispose();
    await fake.close();
  });

  test('joinRoom adopts the announced room and joins it', () async {
    final fake = _FakeGroups();
    final svc = GroupCallService(fake)..start();

    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-2',
        author: _initiator,
        media: const CallMedia(audio: true),
      ),
    );
    await pumpEventQueue();
    await svc.decline();

    final ok = await svc.joinRoom(_groupId);
    expect(ok, isTrue);
    expect(svc.current?.status, GroupCallStatus.connecting);
    expect(svc.current?.callId, 'room-2');
    expect(fake.sent, contains(GroupCallSignalType.join));
    // Inside the room now — the banner offer disappears.
    expect(svc.activeRoomFor(_groupId), isNull);

    await svc.dispose();
    await fake.close();
  });

  test('an authenticated admin end buries the room for good', () async {
    final fake = _FakeGroups();
    final svc = GroupCallService(fake)..start();

    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-3',
        author: _initiator,
        media: const CallMedia(audio: true),
      ),
    );
    await pumpEventQueue();
    await svc.decline();
    expect(svc.activeRoomFor(_groupId), isNotNull);

    fake.push(
      _signal(
        GroupCallSignalType.end,
        callId: 'room-3',
        author: _initiator,
        reason: CallEndReason.hangup,
      ),
    );
    await pumpEventQueue();
    expect(svc.activeRoomFor(_groupId), isNull, reason: 'room is over');

    // A straggling out-of-order announce cannot resurrect the banner.
    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-3',
        author: _initiator,
        media: const CallMedia(audio: true),
      ),
    );
    await pumpEventQueue();
    expect(svc.activeRoomFor(_groupId), isNull);
    expect(svc.current?.status, GroupCallStatus.ended, reason: 'no ring');

    await svc.dispose();
    await fake.close();
  });

  test('a room expires when its announces stop arriving', () async {
    final fake = _FakeGroups();
    var now = DateTime(2026, 1, 1, 12);
    final svc = GroupCallService(fake, now: () => now)..start();

    fake.push(
      _signal(
        GroupCallSignalType.announce,
        callId: 'room-4',
        author: _initiator,
        media: const CallMedia(audio: true),
      ),
    );
    await pumpEventQueue();
    await svc.decline();
    expect(svc.activeRoomFor(_groupId), isNotNull);

    now = now.add(const Duration(minutes: 3));
    expect(
      svc.activeRoomFor(_groupId),
      isNull,
      reason: 'no announce within the room TTL — the call is over',
    );

    await svc.dispose();
    await fake.close();
  });
}
