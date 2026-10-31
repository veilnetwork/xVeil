import 'dart:async';

import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

import 'timed_native_store.dart';

/// Passive stand adapter: all admission, storage and forwarding use super.
/// Nested storage RPCs inherit a synthetic frame number through their Zone.
class TimedGroupService extends GroupService {
  TimedGroupService(
    super.storage,
    super.signer, {
    required this.clock,
    required this.observe,
    super.send,
    super.sendSyncResponse,
    super.activePeers,
  });

  final Stopwatch clock;
  final NativeTiming observe;
  int _nextFrame = 0;

  Future<T> _time<T>(String operation, Future<T> Function() body) async {
    final start = clock.elapsedMicroseconds;
    final frame = Zone.current[groupTimingFrameKey];
    try {
      return await body();
    } finally {
      observe({
        'operation': operation,
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
        if (frame is int) 'group_frame': frame,
      });
    }
  }

  @override
  Future<bool> receiveGroupFrame(
    NodeId peer,
    String json, {
    bool fromStranger = false,
  }) => runZoned(
    () => _time(
      'group.receive',
      () => super.receiveGroupFrame(peer, json, fromStranger: fromStranger),
    ),
    zoneValues: {groupTimingFrameKey: ++_nextFrame},
  );

  @override
  Future<GroupBundle?> load(NodeId groupId) =>
      _time('group.load', () => super.load(groupId));

  @override
  Future<void> learnPeerDocuments(Object? raw) =>
      _time('group.documents', () => super.learnPeerDocuments(raw));

  @override
  Future<bool> ingestSnapshot(
    String bundleJson, {
    bool fromOwnDevice = false,
    NodeId? sender,
  }) => _time(
    'group.snapshot',
    () => super.ingestSnapshot(
      bundleJson,
      fromOwnDevice: fromOwnDevice,
      sender: sender,
    ),
  );

  @override
  Future<bool> allowStrangerGroupSync(NodeId peer, String gidHex) => _time(
    'group.admission',
    () => super.allowStrangerGroupSync(peer, gidHex),
  );
}
