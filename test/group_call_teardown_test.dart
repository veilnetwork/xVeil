import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service.dart';

/// Minimal [GroupService] stand-in: only the members [GroupCallService]
/// touches are real (selfId, changes, groupCallIncoming, stateOf,
/// broadcastGroupCallSignal); everything else routes to noSuchMethod.
class _FakeGroups implements GroupService {
  _FakeGroups(this._selfId);

  final NodeId _selfId;
  final List<GroupCallSignalType> sent = [];

  /// When set, [broadcastGroupCallSignal] records the signal only after the
  /// gate completes — models the slow per-member durable fan-out.
  Completer<void>? sendGate;

  final _incoming = StreamController<GroupCallSignal>.broadcast();

  @override
  // ignore: overridden_fields — the real service exposes a field too.
  final GroupChangeSignal changes = GroupChangeSignal();

  @override
  NodeId get selfId => _selfId;

  @override
  Stream<GroupCallSignal> get groupCallIncoming => _incoming.stream;

  @override
  Future<GroupState?> stateOf(NodeId groupId) async =>
      GroupState.genesis(_selfId);

  @override
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) async {
    final gate = sendGate;
    if (gate != null) await gate.future;
    sent.add(type);
    return GroupCallSignal(
      groupId: groupId,
      callId: callId,
      author: _selfId,
      membershipEpoch: 1,
      type: type,
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
      nonce: 'aabbccddeeff001122334455',
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
      media: media,
      reason: reason,
    );
  }

  Future<void> close() async {
    await _incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final groupId = NodeId.fromHex('b' * 64);

  Future<GroupCallService> liveRoom(_FakeGroups fake) async {
    final svc = GroupCallService(fake)..start();
    final ok = await svc.startCall(groupId, const CallMedia(audio: true));
    expect(ok, isTrue);
    expect(svc.current?.isLive, isTrue);
    return svc;
  }

  test('leave clears the room before the fan-out broadcast lands', () async {
    final fake = _FakeGroups(NodeId.fromHex('a' * 64));
    final svc = await liveRoom(fake);

    // The leave broadcast is one durable enqueue PER MEMBER — the local
    // teardown must not be gated on it.
    fake.sendGate = Completer<void>();
    await svc.leave().timeout(const Duration(milliseconds: 200));
    expect(svc.current?.status, GroupCallStatus.ended);
    expect(
      fake.sent.where((t) => t == GroupCallSignalType.leave),
      isEmpty,
      reason: 'leave is still in flight behind the gate',
    );

    fake.sendGate!.complete();
    await pumpEventQueue();
    expect(fake.sent.last, GroupCallSignalType.leave);
    await svc.dispose();
    await fake.close();
  });

  test('admin end-for-everyone clears the room before the broadcast '
      'lands', () async {
    final fake = _FakeGroups(NodeId.fromHex('a' * 64));
    final svc = await liveRoom(fake);

    fake.sendGate = Completer<void>();
    final ok = await svc.endForEveryone().timeout(
      const Duration(milliseconds: 200),
    );
    expect(ok, isTrue, reason: 'genesis owner outranks admin');
    expect(svc.current?.status, GroupCallStatus.ended);
    expect(fake.sent.where((t) => t == GroupCallSignalType.end), isEmpty);

    fake.sendGate!.complete();
    await pumpEventQueue();
    expect(fake.sent.last, GroupCallSignalType.end);
    await svc.dispose();
    await fake.close();
  });
}
