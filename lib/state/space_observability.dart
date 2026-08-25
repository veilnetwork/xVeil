import 'dart:collection';

/// Privacy-safe, bounded runtime observations for the Space service.
///
/// The enum is deliberately the complete label vocabulary. Observations have
/// no ids, message text, file names, keys, tokens or caller-provided strings,
/// so exposing a snapshot cannot accidentally turn diagnostics into another
/// metadata store.
enum SpaceObservationType {
  spaceCreated,
  spaceArchived,
  spaceDeleted,
  spaceRestored,
  memberChanged,
  memberBanned,
  aclDenied,
  postPublished,
  feedRead,
  recommendationShared,
  recommendationRevoked,
  keyRotated,
  contentCleanup,
  p2pSnapshotDelivery,
  p2pDeltaDelivery,
  p2pBackfill,
  p2pMissingObjects,
  p2pReceipt,
  p2pContentReceipt,
  revokedDeliveryPrevented,
}

enum SpaceObservationOutcome { succeeded, rejected, failed, noOp }

enum SpaceObservationReason {
  invalidInput,
  notFound,
  notMember,
  permissionDenied,
  invalidState,
  conflict,
  duplicate,
  rateLimited,
  alreadyMember,
  transportUnavailable,
  transportFailed,
  storageFailed,
  unavailable,
}

final class SpaceObservation {
  const SpaceObservation({
    required this.type,
    required this.outcome,
    required this.occurredAtMs,
    this.reason,
    this.amount,
    this.durationMs,
  });

  final SpaceObservationType type;
  final SpaceObservationOutcome outcome;
  final SpaceObservationReason? reason;
  final int occurredAtMs;

  /// A non-sensitive count such as peers reached or objects backfilled.
  final int? amount;

  /// Local elapsed time for one typed attempt, never a remote timestamp.
  final int? durationMs;

  Map<String, Object> toJson() => {
    'type': type.name,
    'outcome': outcome.name,
    'occurredAt': occurredAtMs,
    'reason': ?reason?.name,
    'amount': ?amount,
    'durationMs': ?durationMs,
  };
}

/// Identifier-free aggregate of the replication capacity this device can see.
///
/// A remote member contributes one slot per locally held Space. That makes
/// totals useful for capacity/health checks without exposing which peer is in
/// which Space. Live factors are explicitly estimates: transport liveness plus
/// current ACL does not prove that a peer has already converged every object.
///
/// Confirmed factors are narrower protocol confirmations, not cryptographic
/// proof of durable remote storage: a current member echoed a source-bound
/// one-time receipt and its authenticated sync vector then showed no objects
/// missing from the frontier it is authorized to receive. Proofs are RAM-only,
/// expire, and are invalidated by any subsequent local frontier change.
final class SpaceReplicationObservability {
  const SpaceReplicationObservability({
    required this.liveSourceAvailable,
    required this.spaces,
    required this.chatGroups,
    required this.chatGroupMembers,
    required this.chatGroupMembersActive,
    required this.eligibleRemoteSpreaders,
    required this.targetReplicationFactorTotal,
    this.confirmedProofTtlMs = 86400000,
    this.confirmedRemoteHolderSlots = 0,
    this.confirmedReplicationFactorTotal = 0,
    this.confirmedReplicationFactorMin = 0,
    this.confirmedReplicationFactorMax = 0,
    this.confirmedUnderReplicatedSpaces = 0,
    this.referencedContentBlobs = 0,
    this.locallyHeldContentBlobs = 0,
    this.targetContentHolderSlots = 0,
    this.confirmedRemoteContentHolderSlots = 0,
    this.confirmedContentHolderSlots = 0,
    this.confirmedContentDeficitSlots = 0,
    this.confirmedUnderReplicatedContentBlobs = 0,
    this.availableRemoteSpreaders,
    this.availableConfirmedRemoteHolderSlots,
    this.availableConfirmedRemoteContentHolderSlots,
    this.estimatedLiveReplicationFactorTotal,
    this.estimatedLiveReplicationFactorMin,
    this.estimatedLiveReplicationFactorMax,
    this.estimatedUnderReplicatedSpaces,
  });

  final bool liveSourceAvailable;
  final int spaces;
  /// Chat groups (not spaces, not the device group) with at least one other
  /// member, and the members across them.
  ///
  /// [chatGroupMembersActive] is how many of those this device currently holds
  /// a live connection to — null when the peer table could not be read. The
  /// RATIO is the question the sparse overlay turns on: selection prefers
  /// reachable members and can only choose among the ones it can see, so a low
  /// ratio measures what a liveness hint on the wire would buy, and a high one
  /// says it would buy nothing.
  final int chatGroups;
  final int chatGroupMembers;
  final int? chatGroupMembersActive;

  final int eligibleRemoteSpreaders;
  final int targetReplicationFactorTotal;
  final int confirmedProofTtlMs;
  final int confirmedRemoteHolderSlots;
  final int confirmedReplicationFactorTotal;
  final int confirmedReplicationFactorMin;
  final int confirmedReplicationFactorMax;
  final int confirmedUnderReplicatedSpaces;
  final int referencedContentBlobs;
  final int locallyHeldContentBlobs;
  final int targetContentHolderSlots;
  final int confirmedRemoteContentHolderSlots;
  final int confirmedContentHolderSlots;
  final int confirmedContentDeficitSlots;
  final int confirmedUnderReplicatedContentBlobs;
  final int? availableRemoteSpreaders;
  final int? availableConfirmedRemoteHolderSlots;
  final int? availableConfirmedRemoteContentHolderSlots;
  final int? estimatedLiveReplicationFactorTotal;
  final int? estimatedLiveReplicationFactorMin;
  final int? estimatedLiveReplicationFactorMax;
  final int? estimatedUnderReplicatedSpaces;

  Map<String, Object> toJson() => {
    'basis': 'activeAuthorizedMembers',
    'confirmedBasis': 'sourceBoundReceiptAndCaughtUpSyncVector',
    'confirmedScope': 'authorizedSyncFrontier',
    'confirmedRuntimeOnly': true,
    'confirmedProofTtlMs': confirmedProofTtlMs,
    'liveSourceAvailable': liveSourceAvailable,
    'spaces': spaces,
    'chatGroups': chatGroups,
    'chatGroupMembers': chatGroupMembers,
    // -1, not null: the map is `Object` valued and a reader that sees -1 knows
    // the peer table could not be read, which is a different fact from "none
    // of them are up".
    'chatGroupMembersActive': chatGroupMembersActive ?? -1,
    'eligibleRemoteSpreaders': eligibleRemoteSpreaders,
    'targetReplicationFactorTotal': targetReplicationFactorTotal,
    'confirmedRemoteHolderSlots': confirmedRemoteHolderSlots,
    'confirmedReplicationFactorTotal': confirmedReplicationFactorTotal,
    'confirmedReplicationFactorMin': confirmedReplicationFactorMin,
    'confirmedReplicationFactorMax': confirmedReplicationFactorMax,
    'confirmedUnderReplicatedSpaces': confirmedUnderReplicatedSpaces,
    'confirmedContentBasis': 'verifiedStoreAndSourceBoundRequestReceipt',
    'confirmedContentScope': 'referencedContentAddressedBlobs',
    'confirmedContentRuntimeOnly': true,
    'referencedContentBlobs': referencedContentBlobs,
    'locallyHeldContentBlobs': locallyHeldContentBlobs,
    'targetContentHolderSlots': targetContentHolderSlots,
    'confirmedRemoteContentHolderSlots': confirmedRemoteContentHolderSlots,
    'confirmedContentHolderSlots': confirmedContentHolderSlots,
    'confirmedContentDeficitSlots': confirmedContentDeficitSlots,
    'confirmedUnderReplicatedContentBlobs':
        confirmedUnderReplicatedContentBlobs,
    'availableRemoteSpreaders': ?availableRemoteSpreaders,
    'availableConfirmedRemoteHolderSlots': ?availableConfirmedRemoteHolderSlots,
    'availableConfirmedRemoteContentHolderSlots':
        ?availableConfirmedRemoteContentHolderSlots,
    'estimatedLiveReplicationFactorTotal': ?estimatedLiveReplicationFactorTotal,
    'estimatedLiveReplicationFactorMin': ?estimatedLiveReplicationFactorMin,
    'estimatedLiveReplicationFactorMax': ?estimatedLiveReplicationFactorMax,
    'estimatedUnderReplicatedSpaces': ?estimatedUnderReplicatedSpaces,
  };
}

final class SpaceObservabilitySnapshot {
  const SpaceObservabilitySnapshot({
    required this.startedAtMs,
    required this.capturedAtMs,
    required this.capacity,
    required this.droppedRecent,
    required this.counters,
    required this.amounts,
    required this.durationsMs,
    required this.recent,
    required this.replication,
  });

  final int startedAtMs;
  final int capturedAtMs;
  final int capacity;
  final int droppedRecent;
  final Map<String, int> counters;
  final Map<String, int> amounts;
  final Map<String, Map<String, int>> durationsMs;
  final List<SpaceObservation> recent;
  final SpaceReplicationObservability replication;

  Map<String, Object> toJson() => {
    'v': 2,
    'scope': 'runtime',
    'startedAt': startedAtMs,
    'capturedAt': capturedAtMs,
    'capacity': capacity,
    'droppedRecent': droppedRecent,
    'privacy': const {
      'containsIdentifiers': false,
      'containsContent': false,
      'containsSecrets': false,
      'arbitraryLabels': false,
    },
    'counters': counters,
    'amounts': amounts,
    'durationsMs': durationsMs,
    'replication': replication.toJson(),
    'recent': [for (final event in recent) event.toJson()],
  };
}

/// One identity-local, RAM-only observability surface.
///
/// Counters live for the runtime lifetime; recent events are capped. Nothing
/// is written to deniable storage or sent over the network.
final class SpaceObservability {
  SpaceObservability({this.capacity = 128, int Function()? nowMs})
    : assert(capacity > 0 && capacity <= 4096),
      _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
      _startedAtMs = (nowMs ?? (() => DateTime.now().millisecondsSinceEpoch))();

  final int capacity;
  final int Function() _nowMs;
  final int _startedAtMs;
  final ListQueue<SpaceObservation> _recent = ListQueue<SpaceObservation>();
  final Map<String, int> _counters = <String, int>{};
  final Map<String, int> _amounts = <String, int>{};
  final Map<String, int> _durationSamples = <String, int>{};
  final Map<String, int> _durationTotals = <String, int>{};
  final Map<String, int> _durationMax = <String, int>{};
  int _droppedRecent = 0;

  void record(
    SpaceObservationType type,
    SpaceObservationOutcome outcome, {
    SpaceObservationReason? reason,
    int? amount,
    Duration? duration,
  }) {
    final boundedAmount = amount?.clamp(0, 0x7fffffff);
    final boundedDurationMs = duration?.inMilliseconds.clamp(0, 0x7fffffff);
    final event = SpaceObservation(
      type: type,
      outcome: outcome,
      reason: reason,
      occurredAtMs: _nowMs(),
      amount: boundedAmount,
      durationMs: boundedDurationMs,
    );
    final outcomeKey = '${type.name}.${outcome.name}';
    _counters.update(outcomeKey, (value) => value + 1, ifAbsent: () => 1);
    if (reason != null) {
      final reasonKey = '${type.name}.reason.${reason.name}';
      _counters.update(reasonKey, (value) => value + 1, ifAbsent: () => 1);
    }
    if (boundedAmount != null) {
      _amounts.update(
        type.name,
        (value) => value + boundedAmount,
        ifAbsent: () => boundedAmount,
      );
    }
    if (boundedDurationMs != null) {
      final key = type.name;
      _durationSamples.update(key, (value) => value + 1, ifAbsent: () => 1);
      _durationTotals.update(
        key,
        (value) => value + boundedDurationMs,
        ifAbsent: () => boundedDurationMs,
      );
      _durationMax.update(
        key,
        (value) => value > boundedDurationMs ? value : boundedDurationMs,
        ifAbsent: () => boundedDurationMs,
      );
    }
    if (_recent.length == capacity) {
      _recent.removeFirst();
      _droppedRecent++;
    }
    _recent.addLast(event);
  }

  SpaceObservabilitySnapshot snapshot({
    SpaceReplicationObservability? replication,
  }) => SpaceObservabilitySnapshot(
    startedAtMs: _startedAtMs,
    capturedAtMs: _nowMs(),
    capacity: capacity,
    droppedRecent: _droppedRecent,
    counters: Map.unmodifiable(SplayTreeMap<String, int>.of(_counters)),
    amounts: Map.unmodifiable(SplayTreeMap<String, int>.of(_amounts)),
    durationsMs: Map.unmodifiable(
      SplayTreeMap<String, Map<String, int>>.of({
        for (final key in _durationSamples.keys)
          key: Map.unmodifiable({
            'samples': _durationSamples[key]!,
            'total': _durationTotals[key]!,
            'max': _durationMax[key]!,
          }),
      }),
    ),
    recent: List.unmodifiable(_recent),
    replication:
        replication ??
        const SpaceReplicationObservability(
          liveSourceAvailable: false,
          spaces: 0,
          chatGroups: 0,
          chatGroupMembers: 0,
          chatGroupMembersActive: null,
          eligibleRemoteSpreaders: 0,
          targetReplicationFactorTotal: 0,
        ),
  );
}
