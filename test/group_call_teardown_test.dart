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

  /// One-shot: the NEXT admission read waits on it and then answers
  /// "excluded". Consumed on entry, so everything after it — including a new
  /// room started while the first read is parked — is answered normally.
  ///
  /// That one-shot shape is the whole fixture: an exclusion verdict has to be
  /// in flight about the OLD room while the NEW one is admitted.
  Completer<void>? excludeOnceGate;

  /// One-shot: the NEXT admission read waits on it and then answers NORMALLY.
  ///
  /// The exclusion gate above models a verdict about a room that is gone. This
  /// one models the ordinary case — a reconcile parked mid-read while the
  /// person carries on using the call.
  Completer<void>? admitOnceGate;

  /// What the admission reports as the channel epoch. Changing it is what
  /// gives a reconcile something to publish — otherwise it finds nothing
  /// different and writes nothing, and a test built on it proves nothing.
  int? channelEpoch;

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
  Future<({int? channelEpoch, Set<NodeId> recipients})?>
  currentVoiceChannelAdmission(NodeId groupId, NodeId? channelId) async {
    final gate = excludeOnceGate;
    if (gate != null) {
      excludeOnceGate = null;
      await gate.future;
      return (channelEpoch: null, recipients: <NodeId>{});
    }
    final admit = admitOnceGate;
    if (admit != null) {
      admitOnceGate = null;
      await admit.future;
    }
    return channelId == null
        ? (channelEpoch: channelEpoch, recipients: {_selfId})
        : null;
  }

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

/// A media engine whose screen-share switch can be held open, so the window
/// between the native call and the state publish is observable.
class _GatedMedia extends GroupCallMediaController {
  Completer<void>? shareGate;

  /// How many times media was actually asked to start.
  int starts = 0;

  @override
  Future<bool> start(GroupCall call) async {
    starts++;
    return true;
  }
  @override
  Future<void> update(GroupCall call) async {}
  @override
  Future<void> stop() async {}

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    await shareGate?.future;
    return true;
  }
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

  test(
    'a screen share that lands after the room ended does not revive it',
    () async {
      // Everything in `setScreenShareEnabled` awaits the native engine, and the
      // room can end while that runs. The call it publishes afterwards used to
      // be the snapshot taken BEFORE the await, so an ended room came back live
      // — carrying its own callId, with no timers and no media behind it.
      final fake = _FakeGroups(NodeId.fromHex('a' * 64));
      final media = _GatedMedia();
      final svc = GroupCallService(fake, media: media)..start();
      addTearDown(svc.dispose);
      expect(
        await svc.startCall(groupId, const CallMedia(audio: true, video: true)),
        isTrue,
      );

      media.shareGate = Completer<void>();
      final sharing = svc.setScreenShareEnabled(true);

      // The room ends while the engine is still switching.
      await svc.leave();
      expect(svc.current?.status, GroupCallStatus.ended);

      media.shareGate!.complete();
      await sharing;
      await pumpEventQueue();

      expect(
        svc.current?.status,
        GroupCallStatus.ended,
        reason: 'a late share must not put the ended room back on screen',
      );
      expect(
        svc.current?.screenOn,
        isNot(isTrue),
        reason: 'and must not report sharing from a room nobody is in',
      );
    },
  );

  test('a reconcile that was parked does not undo a mic toggle', () async {
    // The membership reads are awaited, and the verdict is published as
    // `snapshot.copyWith(...)` — the WHOLE snapshot, taken before the awaits.
    // So anything the person changed while they ran is written back to what it
    // was: a mic muted mid-reconcile comes back on, and the peers are told so
    // by the reannounce that follows (report14 X14-M7).
    final fake = _FakeGroups(NodeId.fromHex('a' * 64));
    final svc = await liveRoom(fake);
    addTearDown(svc.dispose);
    expect(svc.current?.micOn, isTrue, reason: 'the room starts with audio');

    // A reconcile starts and parks in its admission read — and it has
    // something to publish when it comes back, or the assertion below is
    // about a pass that writes nothing.
    fake.channelEpoch = 7;
    final admitted = Completer<void>();
    fake.admitOnceGate = admitted;
    fake.changes.value++;
    await pumpEventQueue();

    // The person mutes while it is parked.
    await svc.setMicEnabled(false);
    expect(svc.current?.micOn, isFalse);

    admitted.complete();
    await pumpEventQueue();

    expect(
      svc.current?.micOn,
      isFalse,
      reason:
          'the reconcile owns membership, not the microphone — publishing '
          'its own stale snapshot un-mutes a person who muted',
    );
    expect(
      svc.current?.isLive,
      isTrue,
      reason: 'and it must still be the same live room',
    );
    expect(
      svc.current?.channelEpoch,
      7,
      reason:
          'the reconcile DID publish — without that this test is about a '
          'pass that writes nothing',
    );
  });

  test(
    'an exclusion decided about the old room does not end the new one',

    () async {
      // Both membership reads are awaited, and a room can end and another begin
      // while they run. The exclusion branch ended whatever room was current
      // when its verdict landed — the participant update two lines below it has
      // always checked that it is still talking about the same call.
      final fake = _FakeGroups(NodeId.fromHex('a' * 64));
      final svc = GroupCallService(fake)..start();
      addTearDown(svc.dispose);
      expect(
        await svc.startCall(groupId, const CallMedia(audio: true)),
        isTrue,
      );
      final first = svc.current!.callId;

      // A reconcile starts against the first room and parks in its admission
      // read, which will answer "you are not in this room".
      // Held here, not read back from the fake: the fake CONSUMES the field the
      // moment it parks, so `fake.excludeOnceGate` is null by the time the test
      // wants to release it — and the first version of this fixture quietly
      // released nothing.
      final verdict = Completer<void>();
      fake.excludeOnceGate = verdict;
      fake.changes.value++;
      await pumpEventQueue();

      // That room ends and a new one begins while the verdict is in flight. The
      // gate is one-shot, so this room is admitted normally.
      await svc.leave();
      expect(
        await svc.startCall(groupId, const CallMedia(audio: true)),
        isTrue,
        reason: 'the fixture needs a NEW live room for the verdict to land on',
      );

      verdict.complete();
      await pumpEventQueue();

      expect(
        svc.current?.isLive,
        isTrue,
        reason: 'the new room must survive a verdict about the old one',
      );
      expect(svc.current?.callId, isNot(first));
    },
  );

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

  test(
    'a start that lands after the room ended does not arm it',
    () async {
      // report21 XV20-L1. `_end` leaves the same call in `current` with
      // `status: ended` — the banner and the record of who was in it survive
      // on purpose — and the "is this still my call" check compared only the
      // three ids. So a start parked on the announce broadcast came back to a
      // room that was over, was told it was current, and went on to arm the
      // heartbeat and re-announce timers and ask for media. The service is not
      // disposed here, which is what separates this from the teardown case
      // above: nothing else refuses on its behalf.
      final fake = _FakeGroups(NodeId.fromHex('a' * 64));
      final media = _GatedMedia();
      final svc = GroupCallService(fake, media: media)..start();
      addTearDown(svc.dispose);

      fake.sendGate = Completer<void>();
      final starting = svc.startCall(groupId, const CallMedia(audio: true));
      await pumpEventQueue();
      expect(
        media.starts,
        0,
        reason: 'premise: the start is parked on the announce broadcast',
      );

      // The user leaves while the announce is still in flight.
      await svc.leave().timeout(const Duration(milliseconds: 200));
      expect(svc.current?.status, GroupCallStatus.ended);

      fake.sendGate!.complete();
      expect(
        await starting,
        isFalse,
        reason: 'a start that came back to an ended room reported success',
      );
      await pumpEventQueue();

      expect(
        media.starts,
        0,
        reason: 'media was started for a room that had already ended',
      );
      expect(
        svc.current?.status,
        GroupCallStatus.ended,
        reason: 'the late continuation put the ended room back',
      );

      await fake.close();
    },
  );

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
