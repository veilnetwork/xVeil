import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'legacy_compaction_source.dart';

// `meta`, not `flutter/foundation`: this file sits on the headless daemon's
// import graph, which a gate test keeps Flutter-free.
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';
import 'managed_catalog_store.dart';
import 'managed_directory_catalog.dart';
import 'managed_fs_contract.dart';
import 'managed_fs_platform.dart' show ManagedFsPlatform;
import 'managed_fs_windows.dart' as windows;
import 'managed_identity_catalog.dart';
import 'managed_identity_lease.dart';
import 'managed_reclaim_budget.dart';
import 'hidden_volume_storage.dart';
import 'compaction_roster_remap.dart';
import '../../domain/storage_locator.dart' show LegacyStorageLocator;
import 'managed_sqlite_connection.dart';
import '../../domain/identity_erase_review.dart';
import '../../core/storage_unlock_scope.dart';
import '../../domain/storage_protection.dart';
import '../../domain/storage_usage.dart';
import 'rollback_anchor.dart';
import 'storage_write_census.dart';
import 'worker_death.dart';
import 'profile_preferences_file.dart';
import '../../domain/profile_preferences_layout.dart';
import 'package:xveil/core/log.dart';

export 'kv_log_store.dart' show LogReadGroup;

part 'worker_managed_identity.dart';
part 'worker_managed_catalog.dart';
part 'worker_managed_erasure.dart';
part 'worker_profile_preferences.dart';
part 'worker_managed_legacy_compaction.dart';

/// Async, OFF-UI-isolate facade over a single unlocked hidden-volume space.
///
/// Every hidden-volume call (`open`, and each `get`/`commit`/`iterLogRange`/…)
/// is SYNCHRONOUS FFI that blocks whichever isolate runs it. On the Flutter UI
/// isolate that freezes the app for the call's duration — and on Android a >5s
/// main-thread block is a fatal ANR. This interface mirrors [KvLogStore] but
/// returns `Future`s; the production implementation ([WorkerKvLogStore]) runs
/// the real [KvLogStore] inside a dedicated long-lived WORKER ISOLATE and serves
/// each op over a [SendPort], so the UI isolate only ever awaits.
///
/// `HiddenVolumeStorage` already exposes a `Future`-returning public API and its
/// callers already `await`, so swapping its backing store from [KvLogStore] to
/// this changes nothing above it — it just stops blocking the UI thread.
abstract interface class AsyncKvLogStore {
  Future<int> commit(List<KvLogOp> ops);
  Future<Uint8List?> get(int namespace, Uint8List key);
  Future<Uint8List?> readLog(int namespace, int logId);
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });
  Future<int> count(int namespace);
  Future<List<Uint8List>> kvKeys(int namespace);
  Future<int> eraseNamespace(int namespace);
  Future<void> scrub();
  Future<Uint8List> exportKeys();

  /// See [KvLogStore.slotUtilization]. Null is "unknown", not "nothing dead".
  Future<SlotUtilization?> slotUtilization();

  /// See [KvLogStore.hardeningWarning].
  Future<String?> hardeningWarning();

  /// See [KvLogStore.acknowledgeHardeningWarning].
  Future<void> acknowledgeHardeningWarning();

  Future<void> close();
}

/// See [SyncInitializationNamespaceSource]. Inspection stays on the worker.
abstract interface class InitializationNamespaceSource {
  Future<int> initializationNamespaceLimit();
}

/// Optional witness for one actor's command queue. Every operation actually
/// queued to that actor increments it by one synchronously, before returning
/// its future. Completed commands do not reset it.
/// Wrappers must forward the same witness, or return null to disable sharing.
/// It is scoped to this store instance, not a durable database revision.
abstract interface class AsyncKvRequestFrontier {
  int? get requestFrontier;
}

/// Bounded exact-id reads in one worker request. Null at the first missing
/// record, without reading later ids. No extra records are fetched by range.
abstract interface class AsyncLogBatchReader {
  static const maxRecords = 64;
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> logIds);
}

/// Ordered exact-ID groups, concatenated independently with a byte ceiling.
/// Null at the first missing/over-ceiling record, before later records/groups.
/// The whole request is bounded just like a single ordinary log batch.
abstract interface class AsyncLogGroupReader {
  static const maxGroups = SyncLogGroupReader.maxGroups;
  static const maxRecords = SyncLogGroupReader.maxRecords;
  Future<List<Uint8List>?> readLogGroups(
    int namespace,
    List<LogReadGroup> groups,
  );
}

List<LogReadGroup> _snapshotLogGroups(List<LogReadGroup> groups) {
  if (groups.length > AsyncLogGroupReader.maxGroups) {
    throw ArgumentError('too many log read groups');
  }
  var remaining = AsyncLogGroupReader.maxRecords;
  final requested = <LogReadGroup>[];
  for (final group in groups) {
    if (group.maxBytes < 0 || group.ids.length > remaining) {
      throw ArgumentError('invalid bounded log read');
    }
    remaining -= group.ids.length;
    requested.add((ids: List<int>.of(group.ids), maxBytes: group.maxBytes));
  }
  return requested;
}

List<Uint8List>? _readLogGroups(
  KvLogStore store,
  int namespace,
  List<LogReadGroup> groups,
) {
  final requested = _snapshotLogGroups(groups);
  if (store is SyncLogGroupReader) {
    return (store as SyncLogGroupReader).readLogGroups(namespace, requested);
  }
  final result = <Uint8List>[];
  for (final group in requested) {
    final out = BytesBuilder(copy: false);
    for (final id in group.ids) {
      final bytes = store.readLog(namespace, id);
      if (bytes == null || bytes.length > group.maxBytes - out.length) {
        return null;
      }
      out.add(bytes);
    }
    result.add(out.takeBytes());
  }
  return result;
}

/// Ordered metadata reads in one worker request. Missing keys keep their null
/// positions; this does not enumerate a namespace or retain a read cache.
abstract interface class AsyncKvBatchReader {
  static const maxKeys = 64;
  Future<List<Uint8List?>> getBatch(int namespace, List<Uint8List> keys);
}

List<Uint8List> _snapshotReadKeys(List<Uint8List> keys) {
  if (keys.length > AsyncKvBatchReader.maxKeys) {
    throw ArgumentError.value(keys.length, 'keys', 'batch exceeds limit');
  }
  return [for (final key in keys) Uint8List.fromList(key)];
}

List<Uint8List>? _readLogBatch(
  KvLogStore store,
  int namespace,
  List<int> logIds,
) {
  if (logIds.length > AsyncLogBatchReader.maxRecords) {
    throw ArgumentError.value(logIds.length, 'logIds', 'batch exceeds limit');
  }
  final records = <Uint8List>[];
  for (final id in logIds) {
    final record = store.readLog(namespace, id);
    if (record == null) return null;
    records.add(record);
  }
  return records;
}

/// Adapts a SYNCHRONOUS [KvLogStore] to [AsyncKvLogStore] WITHOUT moving it off
/// the calling isolate — every call still runs the blocking FFI inline, just
/// wrapped in a resolved `Future`. Used for the in-memory fake (no FFI, nothing
/// to offload) and as the guarded INLINE fallback both container openers fall
/// back to when their worker proves defective. Both real openers — password and
/// keys — are worker-backed now (audit XV-14); this is the degraded path, not
/// the default one.
class SyncWrappedAsyncKvLogStore
    implements
        AsyncKvLogStore,
        CommitAnchorSource,
        InitializationNamespaceSource,
        AsyncLogBatchReader,
        AsyncLogGroupReader,
        AsyncKvBatchReader,
        StorageUsageSource {
  SyncWrappedAsyncKvLogStore(this._inner);

  final KvLogStore _inner;

  @override
  Future<StorageUsage?> storageUsage() async {
    final inner = _inner;
    return inner is StorageUsageSource
        ? await (inner as StorageUsageSource).storageUsage()
        : null;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    StorageWriteCensus.record(ops);
    return _inner.commit(ops);
  }

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async =>
      _inner.get(namespace, key);
  @override
  Future<List<Uint8List?>> getBatch(int namespace, List<Uint8List> keys) async {
    final requested = _snapshotReadKeys(keys);
    return [for (final key in requested) await get(namespace, key)];
  }

  @override
  Future<Uint8List?> readLog(int namespace, int logId) async =>
      _inner.readLog(namespace, logId);
  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> logIds) async {
    if (logIds.length > AsyncLogBatchReader.maxRecords) {
      throw ArgumentError.value(logIds.length, 'logIds', 'batch exceeds limit');
    }
    final records = <Uint8List>[];
    for (final id in logIds) {
      // Honor overridden reads in adapters too. The real worker executes its
      // synchronous loop inside one RPC instead of taking one hop per record.
      final record = await readLog(namespace, id);
      if (record == null) return null;
      records.add(record);
    }
    return records;
  }

  @override
  Future<List<Uint8List>?> readLogGroups(
    int namespace,
    List<LogReadGroup> groups,
  ) async {
    final requested = _snapshotLogGroups(groups);
    final result = <Uint8List>[];
    for (final group in requested) {
      final out = BytesBuilder(copy: false);
      for (final id in group.ids) {
        // Preserve overridden reads in inline adapters and test stores.
        final bytes = await readLog(namespace, id);
        if (bytes == null || bytes.length > group.maxBytes - out.length) {
          return null;
        }
        out.add(bytes);
      }
      result.add(out.takeBytes());
    }
    return result;
  }

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async => _inner.iterLogRange(
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  Future<int> count(int namespace) async => _inner.count(namespace);

  @override
  Future<List<Uint8List>> kvKeys(int namespace) async =>
      _inner.kvKeys(namespace);
  @override
  Future<int> eraseNamespace(int namespace) async =>
      _inner.eraseNamespace(namespace);
  @override
  Future<void> scrub() async => _inner.scrub();
  @override
  Future<Uint8List> exportKeys() async => _inner.exportKeys();
  @override
  Future<SlotUtilization?> slotUtilization() async => _inner.slotUtilization();

  @override
  Future<int> initializationNamespaceLimit() async {
    final inner = _inner;
    return inner is SyncInitializationNamespaceSource
        ? (inner as SyncInitializationNamespaceSource)
              .initializationNamespaceLimit()
        : 256;
  }

  // Only when the wrapped store actually has a container behind it. A wrapper
  // that answered for one that does not would hand the anchor a number nobody
  // committed (report8 M8-14).
  @override
  Future<int> commitSeq() async {
    final inner = _inner;
    return inner is SyncCommitAnchorSource
        ? (inner as SyncCommitAnchorSource).commitSeq()
        : -1;
  }

  @override
  Future<List<int>> commitHistory() async {
    final inner = _inner;
    return inner is SyncCommitAnchorSource
        ? (inner as SyncCommitAnchorSource).commitHistory()
        : const <int>[];
  }

  @override
  Future<Map<int, String>> commitRoots() async {
    final inner = _inner;
    return inner is SyncCommitAnchorSource
        ? (inner as SyncCommitAnchorSource).commitRoots()
        : const <int, String>{};
  }

  @override
  Future<String?> hardeningWarning() async => _inner.hardeningWarning();

  @override
  Future<void> acknowledgeHardeningWarning() async =>
      _inner.acknowledgeHardeningWarning();
  @override
  Future<void> close() async => _inner.close();
}

// ── Worker isolate protocol ─────────────────────────────────────────────────
// The worker OWNS the sync HvKvLogStore. It opens the space as its first act
// (so the Argon2 KDF + open-scan run off the UI isolate too) and then serves
// per-op requests. All message payloads are plain sendable data (ints, byte
// lists, the sealed KvLogOp/KvLogEntry value types).

/// What the worker opens as its first act. Two ways in, one worker:
/// a password-derived space, or a child space from its pre-derived `SpaceKeys`
/// (master mode). Both are the same synchronous FFI and both were blocking
/// whichever isolate ran them — the keys one was still running on the UI
/// isolate (audit XV-14).
sealed class _OpenConfig {
  const _OpenConfig({
    required this.path,
    required this.paddingPresetTag,
    required this.reply,
  });
  final String path;
  final int paddingPresetTag;
  final SendPort reply;
}

class _OpenByPassword extends _OpenConfig {
  const _OpenByPassword({
    required super.path,
    required super.paddingPresetTag,
    required super.reply,
    required this.password,
    required this.create,
  });
  final Uint8List password;
  final bool create;
}

class _OpenByKeys extends _OpenConfig {
  const _OpenByKeys({
    required super.path,
    required super.paddingPresetTag,
    required super.reply,
    required this.keys,
  });
  final Uint8List keys;
}

hv.PaddingPreset _paddingPresetFromTag(int tag) {
  for (final preset in hv.PaddingPreset.values) {
    if (preset.tag == tag) return preset;
  }
  return hv.PaddingPreset.bucket256KiB;
}

sealed class _Req {
  const _Req(this.reply);
  final SendPort reply;
}

final class _StorageUsageReq extends _Req {
  const _StorageUsageReq(super.reply);
}

class _CommitReq extends _Req {
  const _CommitReq(this.ops, super.reply);
  final List<KvLogOp> ops;
}

class _GetReq extends _Req {
  const _GetReq(this.namespace, this.key, super.reply);
  final int namespace;
  final Uint8List key;
}

class _GetBatchReq extends _Req {
  const _GetBatchReq(this.namespace, this.keys, super.reply);
  final int namespace;
  final List<Uint8List> keys;
}

class _ReadLogReq extends _Req {
  const _ReadLogReq(this.namespace, this.logId, super.reply);
  final int namespace;
  final int logId;
}

class _ReadLogBatchReq extends _Req {
  const _ReadLogBatchReq(this.namespace, this.logIds, super.reply);
  final int namespace;
  final List<int> logIds;
}

class _ReadLogGroupsReq extends _Req {
  const _ReadLogGroupsReq(this.namespace, this.groups, super.reply);
  final int namespace;
  final List<LogReadGroup> groups;
}

class _IterReq extends _Req {
  const _IterReq(
    this.namespace,
    this.start,
    this.end,
    this.limit,
    SendPort reply,
  ) : super(reply);
  final int namespace;
  final int? start;
  final int? end;
  final int limit;
}

class _KvKeysReq extends _Req {
  const _KvKeysReq(this.namespace, super.reply);
  final int namespace;
}

class _CountReq extends _Req {
  const _CountReq(this.namespace, super.reply);
  final int namespace;
}

class _EraseReq extends _Req {
  const _EraseReq(this.namespace, super.reply);
  final int namespace;
}

class _ScrubReq extends _Req {
  const _ScrubReq(super.reply);
}

class _ExportKeysReq extends _Req {
  const _ExportKeysReq(super.reply);
}

class _HardeningWarningReq extends _Req {
  const _HardeningWarningReq(super.reply);
}

class _AckHardeningReq extends _Req {
  const _AckHardeningReq(super.reply);
}

class _SlotUtilizationReq extends _Req {
  const _SlotUtilizationReq(super.reply);
}

/// The two anchor reads (report8 M8-14). Separate messages rather than one,
/// because a caller that only re-anchors after a commit needs the counter and
/// not the window.
class _InitializationLimitReq extends _Req {
  const _InitializationLimitReq(super.reply);
}

class _CommitSeqReq extends _Req {
  const _CommitSeqReq(super.reply);
}

class _CommitHistoryReq extends _Req {
  const _CommitHistoryReq(super.reply);
}

class _CommitRootsReq extends _Req {
  const _CommitRootsReq(super.reply);
}

class _CloseReq extends _Req {
  const _CloseReq(super.reply);
}

/// Replies. `_Ok(value)` carries the result; `_Null` is a distinct "open found
/// no matching space" (hidden-volume `AuthFailed`, which conflates
/// wrong-password and no-such-space — the deniability invariant); `_Err`
/// re-raises an [hv.HvException] on the caller side.
sealed class _Reply {
  const _Reply();
}

class _Ok extends _Reply {
  const _Ok(this.value);
  final Object? value;
}

class _Null extends _Reply {
  const _Null();
}

class _Err extends _Reply {
  const _Err(this.kind, this.message);
  final String kind;
  final String message;
}

void _workerEntry(_OpenConfig cfg) {
  if (cfg is _OpenManagedLegacyCompaction) {
    _managedLegacyCompactionEntry(cfg);
    return;
  }
  if (cfg is _OpenManagedErasure) {
    unawaited(_managedErasureEntry(cfg));
    return;
  }
  if (cfg is _OpenProfilePreferences) {
    _profilePreferencesEntry(cfg);
    return;
  }
  if (cfg is _OpenManagedCatalog) {
    _managedCatalogEntry(cfg);
    return;
  }
  // The hidden-volume symbols are process-global once the main isolate's
  // startup preload (hv_native.ensureHiddenVolumeLoaded) ran — a spawned
  // isolate shares the process image, so `DynamicLibrary.process()` resolves on
  // desktop; on Android the plugin opens by soname per isolate. Call the
  // idempotent loader anyway so the worker is self-sufficient.
  ensureHiddenVolumeLoaded();

  final KvLogStore store;
  void Function()? closeOwner;
  Future<ManagedReclaimReport> Function(bool force)? reclaimOwner;
  try {
    final preset = _paddingPresetFromTag(cfg.paddingPresetTag);
    final opened = switch (cfg) {
      _OpenByPassword(:final password, :final create) => hvSpaceOpener(
        cfg.path,
        paddingPreset: preset,
      )(password: password, create: create),
      _OpenByKeys(:final keys) => hvKeysSpaceOpener(
        cfg.path,
        paddingPreset: preset,
      )(keys),
      _OpenManagedIdentity() => _openManagedWorker(cfg),
      _OpenManagedLegacyCompaction() => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.mode,
      ),
      _OpenManagedErasure() => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.mode,
      ),
      _OpenProfilePreferences() => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.mode,
      ),
      _OpenManagedCatalog() => throw StateError(
        'catalog worker was not dispatched',
      ),
    };
    if (opened == null) {
      cfg.reply.send(const _Null()); // AuthFailed → no/ wrong space
      return;
    }
    if (opened is _ManagedWorkerOwner) {
      final failure = opened.failure;
      if (failure != null) {
        cfg.reply.send(
          _ManagedOpenFailed(failure, _serveManagedCleanup(opened.close)),
        );
        return;
      }
      store = opened.store!;
      closeOwner = opened.close;
      reclaimOwner = (force) => opened.store!.reclaim(force: force);
    } else {
      store = opened as KvLogStore;
    }
  } on hv.HvException catch (e) {
    cfg.reply.send(_workerErrorReply(e, managed: cfg is _OpenManagedIdentity));
    return;
  } catch (e) {
    cfg.reply.send(_workerErrorReply(e, managed: cfg is _OpenManagedIdentity));
    return;
  }

  cfg.reply.send(
    _Ok(
      _serveWorker(
        store,
        closeOwner: closeOwner,
        reclaim: reclaimOwner,
        managed: cfg is _OpenManagedIdentity,
      ),
    ),
  );
}

SendPort _serveWorker(
  KvLogStore store, {
  void Function()? closeOwner,
  Future<ManagedReclaimReport> Function(bool force)? reclaim,
  bool managed = false,
}) {
  final rx = ReceivePort();
  var closing = false;
  var mutationDebt = 0;
  var reclamationFailed = false;
  late final StreamSubscription<dynamic> subscription;
  void maintain(bool force, [SendPort? reply]) {
    // The file owner detaches payload handles across await points. Pause the
    // ACTUAL serving stream, so reads, writes and close keep their FIFO order
    // and cannot observe/tear down an in-progress native prepared operation.
    subscription.pause();
    unawaited(() async {
      try {
        final report = await reclaim!(force);
        if (report.changed || force) reclamationFailed = false;
        reply?.send(_Ok(report));
      } catch (error) {
        reclamationFailed = true;
        if (reply != null) {
          reply.send(_workerErrorReply(error, managed: true));
        } else {
          final kind = _managedFailureKind(error).name;
          devLog(() => 'xVeil[storage]: managed reclamation failed ($kind)');
        }
      } finally {
        subscription.resume();
      }
    }());
  }

  subscription = rx.listen((dynamic msg) {
    if (msg is! _Req) return;
    if (closing && msg is! _CloseReq) {
      msg.reply.send(
        managed
            ? const _ManagedWorkerErr(ManagedWorkerFailureKind.closed)
            : const _Err('Internal', 'storage worker is closing'),
      );
      return;
    }
    void run<T>(T Function() body) {
      try {
        msg.reply.send(_Ok(body()));
      } catch (e) {
        msg.reply.send(_workerErrorReply(e, managed: managed));
      }
    }

    switch (msg) {
      case _CatalogRecoverReferencesReq(:final password, :final keys):
        password?.fillRange(0, password.length, 0);
        keys?.fillRange(0, keys.length, 0);
        msg.reply.send(const _ManagedWorkerErr(ManagedWorkerFailureKind.mode));
      case _CatalogSnapshotReq() ||
          _RunManagedLegacyCompactionReq() ||
          _CatalogSelectReq() ||
          _CatalogEraseReq() ||
          _CatalogReviewEraseReq() ||
          _ErasureSnapshotReq() ||
          _ErasureRetirementSnapshotReq() ||
          _ErasurePersistWitnessReq() ||
          _ErasureRemoveReq() ||
          _ErasureAuxiliaryReq() ||
          _ErasureFinishReq() ||
          _PreferencesReadReq() ||
          _PreferencesReleaseGrantReq() ||
          _PreferencesWriteReq():
        msg.reply.send(const _ManagedWorkerErr(ManagedWorkerFailureKind.mode));
      case _CommitReq(:final ops):
        run(() {
          final committed = store.commit(ops);
          if (reclaim != null) {
            final count = ops.isEmpty ? 1 : ops.length;
            mutationDebt = count >= 128 - mutationDebt
                ? 128
                : mutationDebt + count;
          }
          return committed;
        });
      case _GetReq(:final namespace, :final key):
        run(() => store.get(namespace, key));
      case _GetBatchReq(:final namespace, :final keys):
        run(() {
          if (keys.length > AsyncKvBatchReader.maxKeys) {
            throw ArgumentError.value(
              keys.length,
              'keys',
              'batch exceeds limit',
            );
          }
          return [for (final key in keys) store.get(namespace, key)];
        });
      case _ReadLogReq(:final namespace, :final logId):
        run(() => store.readLog(namespace, logId));
      case _ReadLogBatchReq(:final namespace, :final logIds):
        run(() => _readLogBatch(store, namespace, logIds));
      case _ReadLogGroupsReq(:final namespace, :final groups):
        run(() => _readLogGroups(store, namespace, groups));
      case _IterReq(:final namespace, :final start, :final end, :final limit):
        run(
          () => store.iterLogRange(
            namespace: namespace,
            start: start,
            end: end,
            limit: limit,
          ),
        );
      case _CountReq(:final namespace):
        run(() => store.count(namespace));
      case _KvKeysReq(:final namespace):
        run(() => store.kvKeys(namespace));
      case _EraseReq(:final namespace):
        run(() {
          final count = store.eraseNamespace(namespace);
          if (reclaim != null && count > 0) mutationDebt = 128;
          return count;
        });
      case _ScrubReq():
        run<Object?>(() {
          store.scrub();
          if (reclaim != null) mutationDebt = 128;
          return null;
        });
      case _ExportKeysReq():
        run(() => store.exportKeys());
      case _SlotUtilizationReq():
        run(() => store.slotUtilization());
      // A store with no container behind it cannot answer, and must not
      // invent a number: an anchor built on a fabricated counter would call
      // an honest open a rollback. -1 and an empty window are the two
      // "cannot answer" values the caller checks for.
      case _InitializationLimitReq():
        run(
          () => store is SyncInitializationNamespaceSource
              ? (store as SyncInitializationNamespaceSource)
                    .initializationNamespaceLimit()
              : 256,
        );
      case _CommitSeqReq():
        run(
          () => store is SyncCommitAnchorSource
              ? (store as SyncCommitAnchorSource).commitSeq()
              : -1,
        );
      case _CommitHistoryReq():
        run(
          () => store is SyncCommitAnchorSource
              ? (store as SyncCommitAnchorSource).commitHistory()
              : const <int>[],
        );
      case _CommitRootsReq():
        run(
          () => store is SyncCommitAnchorSource
              ? (store as SyncCommitAnchorSource).commitRoots()
              : const <int, String>{},
        );
      case _HardeningWarningReq():
        run(() {
          final native = store.hardeningWarning();
          if (!reclamationFailed) return native;
          const warning = 'managed reclamation failed; retry maintenance';
          return native == null ? warning : '$native\n$warning';
        });
      case _AckHardeningReq():
        run(() {
          store.acknowledgeHardeningWarning();
          reclamationFailed = false;
          return null;
        });
      case _ManagedReclaimReq(:final force):
        if (reclaim == null) {
          msg.reply.send(
            const _ManagedWorkerErr(ManagedWorkerFailureKind.mode),
          );
        } else {
          mutationDebt = 0;
          maintain(force, msg.reply);
        }
      case _StorageUsageReq():
        // Preserve FIFO order with reads, maintenance and close while the
        // filesystem inventory yields. A caller abandoning its wait does not
        // cancel ownership or release the native lease underneath the walk.
        subscription.pause();
        unawaited(() async {
          try {
            msg.reply.send(
              _Ok(
                store is StorageUsageSource
                    ? await (store as StorageUsageSource).storageUsage()
                    : null,
              ),
            );
          } catch (error) {
            msg.reply.send(_workerErrorReply(error, managed: managed));
          } finally {
            subscription.resume();
          }
        }());
      case _CloseReq():
        closing = true;
        try {
          (closeOwner ?? store.close)();
          msg.reply.send(const _Ok(null));
          rx.close();
          Isolate.current.kill(priority: Isolate.immediate);
        } catch (e) {
          // Retain the owner and serving port: native close may be retryable.
          // Killing here strands any handles whose release failed.
          msg.reply.send(_workerErrorReply(e, managed: managed));
        }
    }
    if (!closing && reclaim != null && mutationDebt >= 128) {
      mutationDebt = 0;
      // The ordinary durable write reply above remains authoritative. A
      // maintenance failure is separate and reported as a bounded warning.
      maintain(false);
    }
  });
  return rx.sendPort;
}

/// Off-UI-isolate [AsyncKvLogStore] backed by a dedicated worker isolate that
/// owns the real [HvKvLogStore]. One instance == one worker == one container
/// handle. Drop with [close].
class WorkerKvLogStore
    implements
        AsyncKvLogStore,
        CommitAnchorSource,
        InitializationNamespaceSource,
        AsyncLogBatchReader,
        AsyncLogGroupReader,
        AsyncKvBatchReader,
        AsyncKvRequestFrontier,
        StorageUsageSource {
  WorkerKvLogStore._(this._isolate, this._toWorker, this._watch);

  /// Assemble a store over a worker that is ALREADY up.
  ///
  /// TEST SEAM ONLY. The hidden-volume library cannot be loaded in a test VM —
  /// a spawned worker dies on `dlsym` long before it opens anything — so the
  /// close contract below, the one the other two worker lifecycles in this
  /// project are now aligned to, would otherwise have no way to be exercised at
  /// all. Production builds its workers through [open] / [openWithKeys].
  ///
  /// Deliberately NOT annotated `@visibleForTesting`: that annotation lives in
  /// `package:flutter/foundation.dart`, and this file is reachable from the
  /// headless daemon's entry points — one Flutter import anywhere in that graph
  /// stops `dart build cli` compiling at all (see
  /// `test/headless_is_flutter_free_test.dart`).
  static WorkerKvLogStore overWorker({
    required Isolate isolate,
    required SendPort toWorker,
    required WorkerDeath watch,
  }) => WorkerKvLogStore._(isolate, toWorker, watch);

  /// How long [close] waits for the worker before giving up on the wait.
  /// Settable for TESTS ONLY — the wait is what is under test, and five real
  /// seconds per case is not a thing to spend. Unannotated for the same
  /// Flutter-free reason as [overWorker].
  static Duration closeTimeout = const Duration(seconds: 5);

  /// The background wait a timed-out close leaves behind, so a test can see it
  /// finish. Null until a close times out; production never reads it.
  Future<void>? _lateClose;

  @visibleForTesting
  Future<void>? get debugLateClose => _lateClose;

  final Isolate _isolate;
  final SendPort _toWorker;

  /// Completes with an error when the worker isolate dies (audit XV-07).
  ///
  /// Every RPC used to `await reply.first` with nothing watching the isolate,
  /// so a worker that crashed — an FFI fault, an uncaught error, an OOM kill —
  /// left that future pending FOREVER. The UI showed a spinner that no timeout
  /// would ever end, and every later call joined it. `errorsAreFatal: true`
  /// made the isolate die quietly; nothing was listening for the death.
  ///
  /// Racing each wait against this turns an invisible hang into an error the
  /// caller can report and recover from.
  final WorkerDeath _watch;
  bool _closed = false;
  bool _closeSucceeded = false;
  hv.HvException? _closeDeathError;
  Future<void>? _closeAttempt;
  Future<void>? _closeWait;
  Future<void>? _lateCloseSource;
  int _requestFrontier = 0;

  @override
  int get requestFrontier => _requestFrontier;

  /// Spawn a worker that opens (or, with [create], opens-or-adds) the space at
  /// [path] for [password]. Returns null when no space matches the password
  /// (hidden-volume `AuthFailed` — kept indistinguishable from wrong-password,
  /// the deniability invariant). Throws [hv.HvException] on any other failure.
  static Future<WorkerKvLogStore?> open({
    required String path,
    required Uint8List password,
    required bool create,
    required hv.PaddingPreset paddingPreset,
  }) => _spawn(
    (reply) => _OpenByPassword(
      path: path,
      paddingPresetTag: paddingPreset.tag,
      reply: reply,
      password: password,
      create: create,
    ),
  );

  /// Spawn a worker that opens the child space [keys] belongs to (master mode,
  /// no password). Same null/throw contract as [open].
  ///
  /// This path used to run INLINE on the caller — which in production is the
  /// Flutter UI isolate. `open_with_keys` skips the KDF but still opens the
  /// container and scans it, and that scan grows with the container: on a large
  /// one it is jank on desktop and a >5s main-thread block, i.e. a fatal ANR,
  /// on Android. Every caller (unlock into an identity, identity switch, roster
  /// edit) already awaited, so nothing above needed to change (audit XV-14).
  static Future<WorkerKvLogStore?> openWithKeys({
    required String path,
    required Uint8List keys,
    required hv.PaddingPreset paddingPreset,
  }) => _spawn(
    (reply) => _OpenByKeys(
      path: path,
      paddingPresetTag: paddingPreset.tag,
      reply: reply,
      keys: keys,
    ),
  );

  /// One supervised spawn for both open flavours. Deliberately shared: the
  /// death-watch wiring below is exactly the bug XV-07 was, and a second
  /// hand-rolled copy of it for the keys path is how that bug would come back.
  static Future<WorkerKvLogStore?> _spawn(
    _OpenConfig Function(SendPort reply) build,
  ) async {
    final boot = ReceivePort();
    // Watch the isolate BEFORE it can die (audit XV-07). Wired at spawn time
    // rather than after, because a worker that fails while opening the
    // container fails FAST — most often on the very first FFI call — and a
    // watcher attached afterwards would miss exactly that case.
    final death = WorkerDeath();
    final isolate = await Isolate.spawn<_OpenConfig>(
      _workerEntry,
      build(boot.sendPort),
      errorsAreFatal: true,
      onExit: death.exitPort.sendPort,
      onError: death.errorPort.sendPort,
    );
    Object? first;
    try {
      first = await death.race(boot.first);
    } catch (e) {
      boot.close();
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
      throw hv.HvException('Internal', 'storage worker died during open: $e');
    }
    boot.close();
    void abandon() {
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
    }

    switch (first) {
      case _Null():
        abandon();
        return null;
      case _Err(:final kind, :final message):
        abandon();
        throw hv.HvException(kind, message);
      case _ManagedWorkerErr(:final kind, :final preferencesOpenReason):
        abandon();
        throw ManagedWorkerFailure(
          kind,
          preferencesOpenReason: preferencesOpenReason,
        );
      case _ManagedOpenFailed(
        :final kind,
        :final cleanup,
        :final preferencesOpenReason,
      ):
        // This worker still owns a failed open's native resources. Transfer
        // its close capability instead of abandoning/killing the owner.
        throw _ManagedBootstrapCleanup(
          ManagedWorkerFailure(
            kind,
            preferencesOpenReason: preferencesOpenReason,
          ),
          WorkerKvLogStore._(isolate, cleanup, death),
        );
      case _Ok(:final value):
        return WorkerKvLogStore._(isolate, value as SendPort, death);
      default:
        abandon();
        throw StateError('worker sent an unexpected bootstrap reply');
    }
  }

  /// The reply a worker sends when an operation failed.
  ///
  /// TESTS ONLY, and it exists because `close` is the one call whose FAILURE
  /// could not be staged: every other path goes through [_call], which has
  /// always raised `_Err`, while close read any reply as success. A real
  /// worker answers this only when the container refuses to shut, which is not
  /// a state a test can arrange — so the stub worker sends it instead.
  ///
  /// Unannotated for the same Flutter-free reason as [overWorker].
  static Object debugFailureReply(String kind, String message) =>
      _Err(kind, message);

  @visibleForTesting
  static Object debugSuccessReply() => const _Ok(null);

  /// Runs the same command server with a disposable test store. The test must
  /// create that store inside its worker, never transfer native handles.
  @visibleForTesting
  static SendPort debugServeStore(
    KvLogStore store, {
    Future<ManagedReclaimReport> Function(bool force)? reclaim,
  }) => _serveWorker(store, reclaim: reclaim, managed: reclaim != null);

  Future<T> _call<T>(_Req Function(SendPort reply) build) async {
    if (_closed) throw StateError('WorkerKvLogStore is closed');
    _requestFrontier++;
    final reply = ReceivePort();
    try {
      _toWorker.send(build(reply.sendPort));
      // Raced against the worker's death (audit XV-07): without it a crashed
      // worker leaves this pending forever, and every later call joins it.
      final r = await _watch.race(reply.first);
      if (r is _Err) throw hv.HvException(r.kind, r.message);
      if (r is _ManagedWorkerErr) {
        throw ManagedWorkerFailure(
          r.kind,
          preferencesReadReason: r.preferencesReadReason,
        );
      }
      if (r is _LegacyCompactionErr) {
        throw ManagedLegacyCompactionFailure(
          r.kind,
          mayHaveApplied: r.mayHaveApplied,
          recovery: r.recovery,
          warning: r.warning,
        );
      }
      return (r as _Ok).value as T;
    } finally {
      reply.close();
    }
  }

  @override
  Future<StorageUsage?> storageUsage() =>
      _call((reply) => _StorageUsageReq(reply));

  @override
  Future<int> commit(List<KvLogOp> ops) {
    // Counted on THIS side of the isolate boundary: the tally is read back
    // through the debug hook, which runs here, not in the worker.
    StorageWriteCensus.record(ops);
    return _call<int>((reply) => _CommitReq(ops, reply));
  }

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      _call<Uint8List?>((reply) => _GetReq(namespace, key, reply));
  @override
  Future<List<Uint8List?>> getBatch(int namespace, List<Uint8List> keys) async {
    final requested = _snapshotReadKeys(keys);
    if (requested.isEmpty) return const <Uint8List?>[];
    return _call<List<Uint8List?>>(
      (reply) => _GetBatchReq(namespace, requested, reply),
    );
  }

  @override
  Future<Uint8List?> readLog(int namespace, int logId) =>
      _call<Uint8List?>((reply) => _ReadLogReq(namespace, logId, reply));
  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> logIds) async {
    if (logIds.length > AsyncLogBatchReader.maxRecords) {
      throw ArgumentError.value(logIds.length, 'logIds', 'batch exceeds limit');
    }
    if (logIds.isEmpty) return const <Uint8List>[];
    final requested = List<int>.of(logIds);
    return _call<List<Uint8List>?>(
      (reply) => _ReadLogBatchReq(namespace, requested, reply),
    );
  }

  @override
  Future<List<Uint8List>?> readLogGroups(
    int namespace,
    List<LogReadGroup> groups,
  ) async {
    final requested = _snapshotLogGroups(groups);
    if (requested.every((group) => group.ids.isEmpty)) {
      return [for (final _ in requested) Uint8List(0)];
    }
    return _call<List<Uint8List>?>(
      (reply) => _ReadLogGroupsReq(namespace, requested, reply),
    );
  }

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _call<List<KvLogEntry>>(
    (reply) => _IterReq(namespace, start, end, limit, reply),
  );
  @override
  Future<int> count(int namespace) =>
      _call<int>((reply) => _CountReq(namespace, reply));

  @override
  Future<List<Uint8List>> kvKeys(int namespace) =>
      _call<List<Uint8List>>((reply) => _KvKeysReq(namespace, reply));
  @override
  Future<int> eraseNamespace(int namespace) =>
      _call<int>((reply) => _EraseReq(namespace, reply));
  @override
  Future<void> scrub() => _call<void>((reply) => _ScrubReq(reply));
  @override
  Future<Uint8List> exportKeys() =>
      _call<Uint8List>((reply) => _ExportKeysReq(reply));

  @override
  Future<SlotUtilization?> slotUtilization() =>
      _call<SlotUtilization?>((reply) => _SlotUtilizationReq(reply));

  @override
  Future<int> initializationNamespaceLimit() =>
      _call<int>((reply) => _InitializationLimitReq(reply));
  @override
  Future<int> commitSeq() => _call<int>((reply) => _CommitSeqReq(reply));

  @override
  Future<List<int>> commitHistory() =>
      _call<List<int>>((reply) => _CommitHistoryReq(reply));

  @override
  Future<Map<int, String>> commitRoots() =>
      _call<Map<int, String>>((reply) => _CommitRootsReq(reply));

  @override
  Future<String?> hardeningWarning() =>
      _call<String?>((reply) => _HardeningWarningReq(reply));

  @override
  Future<void> acknowledgeHardeningWarning() =>
      _call<void>((reply) => _AckHardeningReq(reply));

  @override
  Future<void> close() {
    if (_closeSucceeded) return Future.value();
    final death = _closeDeathError;
    if (death != null) return Future.error(death);
    _closed = true; // reject new I/O from the first close request onward
    final waiting = _closeWait;
    if (waiting != null) return waiting;
    final attempt = _closeAttempt ??= _sendClose();
    late final Future<void> next;
    next = _waitForClose(attempt).whenComplete(() {
      if (identical(_closeWait, next)) _closeWait = null;
    });
    _closeWait = next;
    return next;
  }

  Future<void> _sendClose() async {
    _requestFrontier++;
    final reply = ReceivePort();
    try {
      final done = reply.first;
      _toWorker.send(_CloseReq(reply.sendPort));
      final Object? result;
      try {
        result = await _watch.race(done);
      } catch (error) {
        // Death cannot prove native release. Remember this terminal failure so
        // a later close cannot silently manufacture success for a dead owner.
        final failure = hv.HvException(
          'Internal',
          'storage worker died during close: $error',
        );
        _closeDeathError = failure;
        _watch.dispose();
        _isolate.kill(priority: Isolate.immediate);
        throw failure;
      }
      if (result is _Err) {
        // Keep the worker/watch alive for a fresh close attempt. Ordinary I/O
        // remains disabled; the worker's native owners are still authoritative.
        throw hv.HvException(result.kind, result.message);
      }
      if (result is _ManagedWorkerErr) {
        throw ManagedWorkerFailure(result.kind);
      }
      if (result is! _Ok) {
        throw hv.HvException(
          'Internal',
          'invalid storage close acknowledgement',
        );
      }
      _closeSucceeded = true;
      _watch.dispose();
      _isolate.kill(priority: Isolate.immediate);
    } finally {
      reply.close();
      _closeAttempt = null;
    }
  }

  Future<void> _waitForClose(Future<void> attempt) async {
    final completed = await attempt
        .then((_) => true)
        .timeout(closeTimeout, onTimeout: () => false);
    if (completed) return;
    // A timeout bounds the caller's wait, not the native operation's lifetime.
    // Retain the ONE attempt: retries join it rather than queueing another close
    // or killing a worker inside FFI. A later refusal remains retryable.
    if (!identical(_lateCloseSource, attempt)) {
      _lateCloseSource = attempt;
      _lateClose = attempt.then(
        (_) => devLog(
          () => 'xVeil[storage]: late worker close completed; handles released',
        ),
        onError: (Object error, StackTrace stack) {
          devLog(() => 'xVeil[storage]: late worker close failed: $error');
        },
      );
      unawaited(_lateClose!);
    }
    throw hv.HvException(
      'Busy',
      'storage worker did not close within ${closeTimeout.inMilliseconds}ms; '
          'native release is not confirmed',
    );
  }
}

/// Opens (or creates) the space for [password] OFF the UI isolate. The async
/// analogue of [SpaceOpener] — production wiring spawns a [WorkerKvLogStore].
typedef AsyncSpaceOpener =
    Future<AsyncKvLogStore?> Function({
      required Uint8List password,
      required bool create,
    });

/// Once the worker isolate is proven unable to open a space (e.g. a spawned
/// isolate that can't load the native lib — observed on Android), stop spawning
/// it for the rest of the process and open INLINE instead. Process-global so a
/// single failure flips every space to the safe path.
bool _workerOpenUsable = true;

/// Builds an [AsyncSpaceOpener] over the hidden-volume container at [path] whose
/// open + every operation run on a worker isolate (UI thread never blocks).
///
/// SELF-HEALING: if the worker itself fails to open (a THROW from
/// [WorkerKvLogStore.open] — a genuine wrong-password/no-space comes back as
/// `null`, NOT a throw), fall back to opening the space INLINE on the calling
/// isolate, where the native lib was already loaded at startup
/// (`ensureHiddenVolumeLoaded`). Off-isolate is forfeited for the rest of the
/// run, but the user can still UNLOCK — critical: a worker that can't load the
/// lib otherwise surfaces as "wrong password" and locks the user out.
AsyncSpaceOpener workerSpaceOpener(
  String path, {
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  return ({required Uint8List password, required bool create}) async {
    if (_workerOpenUsable) {
      try {
        return await WorkerKvLogStore.open(
          path: path,
          password: password,
          create: create,
          paddingPreset: paddingPreset,
        );
      } on hv.HvException catch (e) {
        devLog(
          () =>
              'xVeil[storage]: worker open FAILED (${e.kind}: ${e.message}) — '
              'trying INLINE open',
        );
        // A CONTAINER-level failure (Busy from a still-held flock, a corrupt
        // file) hits the inline path identically — it throws out of here to the
        // caller (which must surface it, not report "wrong password"), and the
        // worker path stays enabled for the next attempt. Only when the inline
        // open SUCCEEDS where the worker failed is the worker itself proven
        // defective (e.g. a spawned isolate that can't load the native lib —
        // observed on Android) — then disable it for the rest of the run.
        final inline = hvSpaceOpener(path, paddingPreset: paddingPreset)(
          password: password,
          create: create,
        );
        _workerOpenUsable = false;
        devLog(
          () =>
              'xVeil[storage]: INLINE open worked where the worker failed — '
              'off-isolate storage disabled for the rest of this run',
        );
        return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
      }
    }
    final inline = hvSpaceOpener(path, paddingPreset: paddingPreset)(
      password: password,
      create: create,
    );
    return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
  };
}

/// Async analogue of [KeysSpaceOpener] — opens a space directly from its
/// pre-derived 64-byte `SpaceKeys` (master mode), off the UI isolate.
typedef AsyncKeysSpaceOpener =
    Future<AsyncKvLogStore?> Function(Uint8List keys);

/// Lifts a synchronous [SpaceOpener] to an [AsyncSpaceOpener] by running it
/// INLINE (no worker) and wrapping the result in a [SyncWrappedAsyncKvLogStore].
/// For the in-memory fake (nothing to offload) and any path not yet given its
/// own worker.
AsyncSpaceOpener syncWrappedSpaceOpener(SpaceOpener inner) {
  return ({required Uint8List password, required bool create}) async {
    final s = inner(password: password, create: create);
    return s == null ? null : SyncWrappedAsyncKvLogStore(s);
  };
}

/// Lifts a synchronous [KeysSpaceOpener] to an [AsyncKeysSpaceOpener] by running
/// it INLINE on the calling isolate. For the in-memory fake, where there is
/// nothing to offload.
///
/// ⛔ Not for a real container. Inline means the caller is the isolate that
/// executes `open_with_keys`, and in production that caller is the UI isolate —
/// see [workerKeysSpaceOpener] (audit XV-14).
AsyncKeysSpaceOpener syncWrappedKeysOpener(KeysSpaceOpener inner) {
  return (Uint8List keys) async {
    final s = inner(keys);
    return s == null ? null : SyncWrappedAsyncKvLogStore(s);
  };
}

/// Builds an [AsyncKeysSpaceOpener] over the container at [path] whose open —
/// and every operation after it — runs on a worker isolate.
///
/// The keys/master path was the last real-container opener still lifted with
/// [syncWrappedKeysOpener], i.e. still opening on the UI isolate long after the
/// password path had moved off it. There was no constraint keeping it there:
/// every caller already awaits, and every flow closes the previous space before
/// opening the next (`_closeStaleStoreBeforeOpen`, and `IdentityManager` opens
/// master and child strictly one at a time), so the container's exclusive flock
/// is never wanted by two isolates at once (audit XV-14).
///
/// SELF-HEALING, and deliberately the same rule as [workerSpaceOpener]: a THROW
/// from the worker (not `null`, which is the "these keys match no space"
/// answer) is retried INLINE, and only an inline open that SUCCEEDS where the
/// worker failed proves the worker itself defective — then off-isolate is
/// forfeited for the rest of the run, for both openers, via the shared
/// [_workerOpenUsable]. A container-level failure (a still-held flock, a
/// corrupt file) fails the same way inline and propagates to the caller.
AsyncKeysSpaceOpener workerKeysSpaceOpener(
  String path, {
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  AsyncKvLogStore? inlineOpen(Uint8List keys) {
    final inline = hvKeysSpaceOpener(path, paddingPreset: paddingPreset)(keys);
    return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
  }

  return (Uint8List keys) async {
    if (_workerOpenUsable) {
      try {
        return await WorkerKvLogStore.openWithKeys(
          path: path,
          keys: keys,
          paddingPreset: paddingPreset,
        );
      } on hv.HvException catch (e) {
        devLog(
          () =>
              'xVeil[storage]: worker keys-open FAILED (${e.kind}: ${e.message})'
              ' — trying INLINE open',
        );
        final inline = inlineOpen(keys);
        _workerOpenUsable = false;
        devLog(
          () =>
              'xVeil[storage]: INLINE keys-open worked where the worker failed '
              '— off-isolate storage disabled for the rest of this run',
        );
        return inline;
      }
    }
    return inlineOpen(keys);
  };
}
