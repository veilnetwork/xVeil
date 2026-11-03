import 'dart:async';
import 'dart:typed_data';

import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';
import 'package:xveil/state/ratchet_persistence.dart';

typedef NativeTiming = void Function(Map<String, Object?> values);

// Synthetic, process-local correlation only. Never contains a group/node ID.
const groupTimingFrameKey = #xveilStandGroupFrame;
const groupFileTimingOpKey = #xveilStandGroupFileOperation;
const authorizationTimingOpKey = #xveilStandAuthorizationOperation;
const authorizationFlushTimingKey = #xveilStandAuthorizationFlush;
const storageTimingOperationKey = #xveilStandStorageOperation;
const storageTimingContextKey = #xveilStandStorageContext;
const storageTimingContexts = {'ownDevices'};

// Exact test-only labels; an arbitrary Zone value cannot become a correlator.
final storageTimingOperations = Set<String>.unmodifiable({
  for (final operation in [
    'load',
    'loadBatch',
    'has',
    'hasBatch',
    'store',
    'storePair',
    'delete',
  ])
    for (final kind in ['header', 'segment', 'other']) 'file.$operation.$kind',
});

// A passive test adapter around the actual worker RPCs. Preserve both batch
// reads and rollback-anchor capabilities: dropping either would change the
// measured production path. Only counts, categories and timings are recorded.
class TimedNativeStore
    implements
        AsyncKvLogStore,
        AsyncLogBatchReader,
        AsyncLogGroupReader,
        CommitAnchorSource,
        AsyncKvBatchReader {
  TimedNativeStore(this.inner, this.clock, this.observe) {
    if (inner is! AsyncLogBatchReader ||
        inner is! AsyncLogGroupReader ||
        inner is! AsyncKvBatchReader ||
        inner is! CommitAnchorSource) {
      throw StateError(
        'native timing requires batch reads and rollback anchors',
      );
    }
  }
  final AsyncKvLogStore inner;
  final Stopwatch clock;
  final NativeTiming observe;

  Future<T> _time<T>(
    String operation,
    Future<T> Function() body, {
    List<int> namespaces = const [],
    int? operations,
  }) async {
    final start = clock.elapsedMicroseconds;
    final groupFrame = Zone.current[groupTimingFrameKey];
    final fileOperation = Zone.current[groupFileTimingOpKey];
    final authorizationOperation = Zone.current[authorizationTimingOpKey];
    final authorizationFlush = Zone.current[authorizationFlushTimingKey];
    final storageOperation = Zone.current[storageTimingOperationKey];
    final context = Zone.current[storageTimingContextKey];
    try {
      return await body();
    } finally {
      observe({
        'operation': operation,
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
        'namespaces': namespaces,
        'operations': ?operations,
        if (groupFrame is int) 'group_frame': groupFrame,
        if (fileOperation is int) 'file_operation': fileOperation,
        if (authorizationOperation is int)
          'authorization_operation': authorizationOperation,
        if (authorizationFlush is int)
          'authorization_flush': authorizationFlush,
        if (storageTimingOperations.contains(storageOperation))
          'storage_operation': storageOperation,
        if (storageTimingContexts.contains(context)) 'storage_context': context,
      });
    }
  }

  @override
  Future<int> commit(List<KvLogOp> ops) {
    final namespaces = {
      for (final op in ops)
        switch (op) {
          PutOp(:final namespace) ||
          DeleteOp(:final namespace) ||
          AppendLogOp(:final namespace) ||
          DeleteLogOp(:final namespace) => namespace,
        },
    }.toList()..sort();
    return _time(
      'kv.commit',
      () => inner.commit(ops),
      namespaces: namespaces,
      operations: ops.length,
    );
  }

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      _time('kv.get', () => inner.get(namespace, key), namespaces: [namespace]);
  @override
  Future<List<Uint8List?>> getBatch(int namespace, List<Uint8List> keys) =>
      _time(
        'kv.getBatch',
        () async {
          if (keys.length > AsyncKvBatchReader.maxKeys) {
            throw ArgumentError('metadata batch exceeds limit');
          }
          final requested = [for (final key in keys) Uint8List.fromList(key)];
          return (inner as AsyncKvBatchReader).getBatch(namespace, requested);
        },
        namespaces: [namespace],
        operations: keys.length,
      );
  @override
  Future<Uint8List?> readLog(int namespace, int logId) => _time(
    'kv.readLog',
    () => inner.readLog(namespace, logId),
    namespaces: [namespace],
  );
  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> ids) => _time(
    'kv.readLogBatch',
    () => (inner as AsyncLogBatchReader).readLogBatch(namespace, ids),
    namespaces: [namespace],
    operations: ids.length,
  );
  @override
  Future<List<Uint8List>?> readLogGroups(
    int namespace,
    List<LogReadGroup> groups,
  ) {
    // Snapshot before any wrapper or worker can yield.
    final requested = [
      for (final group in groups)
        (ids: List<int>.of(group.ids), maxBytes: group.maxBytes),
    ];
    return _time(
      'kv.readLogGroups',
      () => (inner as AsyncLogGroupReader).readLogGroups(namespace, requested),
      namespaces: [namespace],
      operations: requested.fold<int>(0, (n, group) => n + group.ids.length),
    );
  }

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _time(
    'kv.iterLogRange',
    () => inner.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    ),
    namespaces: [namespace],
  );
  @override
  Future<int> count(int namespace) =>
      _time('kv.count', () => inner.count(namespace), namespaces: [namespace]);
  @override
  Future<List<Uint8List>> kvKeys(int namespace) =>
      _time('kv.keys', () => inner.kvKeys(namespace), namespaces: [namespace]);
  @override
  Future<int> eraseNamespace(int namespace) => _time(
    'kv.erase',
    () => inner.eraseNamespace(namespace),
    namespaces: [namespace],
  );
  @override
  Future<void> scrub() => _time('kv.scrub', inner.scrub);
  @override
  Future<Uint8List> exportKeys() => inner.exportKeys();
  @override
  Future<SlotUtilization?> slotUtilization() =>
      _time('kv.slots', inner.slotUtilization);
  @override
  Future<String?> hardeningWarning() => inner.hardeningWarning();
  @override
  Future<void> acknowledgeHardeningWarning() =>
      inner.acknowledgeHardeningWarning();
  @override
  Future<int> commitSeq() =>
      _time('anchor.sequence', (inner as CommitAnchorSource).commitSeq);
  @override
  Future<List<int>> commitHistory() =>
      _time('anchor.history', (inner as CommitAnchorSource).commitHistory);
  @override
  Future<Map<int, String>> commitRoots() =>
      _time('anchor.roots', (inner as CommitAnchorSource).commitRoots);
  @override
  Future<void> close() => inner.close();
}

class TimedNativeRatchet extends RatchetPersistence {
  TimedNativeRatchet({
    required super.native,
    required super.storage,
    super.peerAuthorization,
    required this.clock,
    required this.observe,
  }) : super(coalesce: kRatchetFlushCoalesce);
  final Stopwatch clock;
  final NativeTiming observe;
  Future<T> _time<T>(String operation, Future<T> Function() body) async {
    final start = clock.elapsedMicroseconds;
    try {
      return await body();
    } finally {
      observe({
        'operation': operation,
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
      });
    }
  }

  @override
  Future<int> flush({String why = 'unknown', bool now = false}) =>
      _time('ratchet.flush.$why', () => super.flush(why: why, now: now));
  @override
  Future<void> reserveBeforePublish(NodeId peer) =>
      _time('ratchet.reserve', () => super.reserveBeforePublish(peer));
}
