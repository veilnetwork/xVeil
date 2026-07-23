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
  });

  final SpaceObservationType type;
  final SpaceObservationOutcome outcome;
  final SpaceObservationReason? reason;
  final int occurredAtMs;

  /// A non-sensitive count such as peers reached or objects backfilled.
  final int? amount;

  Map<String, Object> toJson() => {
    'type': type.name,
    'outcome': outcome.name,
    'occurredAt': occurredAtMs,
    'reason': ?reason?.name,
    'amount': ?amount,
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
    required this.recent,
  });

  final int startedAtMs;
  final int capturedAtMs;
  final int capacity;
  final int droppedRecent;
  final Map<String, int> counters;
  final Map<String, int> amounts;
  final List<SpaceObservation> recent;

  Map<String, Object> toJson() => {
    'v': 1,
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
  int _droppedRecent = 0;

  void record(
    SpaceObservationType type,
    SpaceObservationOutcome outcome, {
    SpaceObservationReason? reason,
    int? amount,
  }) {
    final boundedAmount = amount?.clamp(0, 0x7fffffff);
    final event = SpaceObservation(
      type: type,
      outcome: outcome,
      reason: reason,
      occurredAtMs: _nowMs(),
      amount: boundedAmount,
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
    if (_recent.length == capacity) {
      _recent.removeFirst();
      _droppedRecent++;
    }
    _recent.addLast(event);
  }

  SpaceObservabilitySnapshot snapshot() => SpaceObservabilitySnapshot(
    startedAtMs: _startedAtMs,
    capturedAtMs: _nowMs(),
    capacity: capacity,
    droppedRecent: _droppedRecent,
    counters: Map.unmodifiable(SplayTreeMap<String, int>.of(_counters)),
    amounts: Map.unmodifiable(SplayTreeMap<String, int>.of(_amounts)),
    recent: List.unmodifiable(_recent),
  );
}
