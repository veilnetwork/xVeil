import 'dart:typed_data';

import 'async_kv_log_store.dart';
import 'kv_log_store.dart';

/// Backing for several [KvLogStore] views over ONE container, open at once under
/// a single lock (mirrors `HvMultiSpace`). Each space is addressed by a small
/// [int] id from [openSpace]; a [MultiSpaceKvLogStore] binds one id and presents
/// the per-space [KvLogStore] surface. The real implementation wraps the native
/// `HvMultiSpace`; the fake is in-memory (for tests).
///
/// Unlike the single-lock [SpaceOpener] (one space open at a time), all views
/// here are usable simultaneously — the storage foundation for running several
/// identities at once.
abstract interface class MultiSpaceBacking {
  /// Host a space by its 64-byte `SpaceKeys`; returns its space id.
  int openSpace(Uint8List keys);

  int commit(int id, List<KvLogOp> ops);
  Uint8List? get(int id, int namespace, Uint8List key);
  Uint8List? readLog(int id, int namespace, int logId);
  List<KvLogEntry> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });
  int count(int id, int namespace);
  Uint8List exportKeys(int id);
  void scrub(int id);

  /// Release the container lock and free the underlying handle. Closes ALL
  /// hosted spaces at once (they share the one handle).
  void close();
}

/// A single space's [KvLogStore] view over a shared [MultiSpaceBacking]. Every
/// call delegates to the backing with this view's [_id], so N views operate on
/// one container/lock concurrently. [close] is a no-op on the shared backing —
/// the owner closes the backing (and thus all views) once.
class MultiSpaceKvLogStore implements KvLogStore {
  MultiSpaceKvLogStore(this._backing, this._id);

  final MultiSpaceBacking _backing;
  final int _id;

  @override
  int commit(List<KvLogOp> ops) => _backing.commit(_id, ops);

  @override
  Uint8List? get(int namespace, Uint8List key) =>
      _backing.get(_id, namespace, key);

  @override
  Uint8List? readLog(int namespace, int logId) =>
      _backing.readLog(_id, namespace, logId);

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) =>
      _backing.iterLogRange(_id,
          namespace: namespace, start: start, end: end, limit: limit);

  @override
  int count(int namespace) => _backing.count(_id, namespace);

  @override
  int eraseNamespace(int namespace) =>
      // Deleting an identity tears the all-online session down and erases via
      // the single-space path (HvKvLogStore), so this multi-space view never
      // erases. The native multi-space handle also exposes no per-id erase.
      throw UnsupportedError(
          'erase a space via the single-space path, not the multi-space view');

  @override
  void scrub() => _backing.scrub(_id);

  @override
  Uint8List exportKeys() => _backing.exportKeys(_id);

  @override
  void close() {
    // No-op: the shared backing (and its lock) is closed once by its owner, not
    // per view. Closing one identity's view must not drop the others.
  }
}

/// Async (off-UI-isolate) twin of [MultiSpaceBacking]: every call returns a
/// `Future`. The production impl ([WorkerMultiSpaceBacking]) owns the sync
/// `HvMultiSpaceBacking` inside ONE worker isolate and serves `(id, op)` over a
/// `SendPort`, so N always-online identities share one container handle WITHOUT
/// blocking the UI thread on the fsync'ing FFI.
abstract interface class AsyncMultiSpaceBacking {
  /// Host a space by its 64-byte `SpaceKeys`; returns its space id.
  Future<int> openSpace(Uint8List keys);

  Future<int> commit(int id, List<KvLogOp> ops);
  Future<Uint8List?> get(int id, int namespace, Uint8List key);
  Future<Uint8List?> readLog(int id, int namespace, int logId);
  Future<List<KvLogEntry>> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });
  Future<int> count(int id, int namespace);
  Future<Uint8List> exportKeys(int id);
  Future<void> scrub(int id);

  /// Release the container lock + free the handle (and tear the worker down).
  /// Closes ALL hosted spaces at once.
  Future<void> close();
}

/// A single space's [AsyncKvLogStore] view over a shared [AsyncMultiSpaceBacking]
/// — the async analogue of [MultiSpaceKvLogStore]. Every call routes to the
/// backing with this view's [_id], so N views share one worker/handle. [close]
/// is a no-op (the owner closes the backing once).
class AsyncMultiSpaceKvLogStore implements AsyncKvLogStore {
  AsyncMultiSpaceKvLogStore(this._backing, this._id);

  final AsyncMultiSpaceBacking _backing;
  final int _id;

  @override
  Future<int> commit(List<KvLogOp> ops) => _backing.commit(_id, ops);

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      _backing.get(_id, namespace, key);

  @override
  Future<Uint8List?> readLog(int namespace, int logId) =>
      _backing.readLog(_id, namespace, logId);

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) =>
      _backing.iterLogRange(_id,
          namespace: namespace, start: start, end: end, limit: limit);

  @override
  Future<int> count(int namespace) => _backing.count(_id, namespace);

  @override
  Future<int> eraseNamespace(int namespace) =>
      // Deleting an identity tears the all-online session down and erases via
      // the single-space path, so the multi-space view never erases (same
      // contract as [MultiSpaceKvLogStore]).
      throw UnsupportedError(
          'erase a space via the single-space path, not the multi-space view');

  @override
  Future<void> scrub() => _backing.scrub(_id);

  @override
  Future<Uint8List> exportKeys() => _backing.exportKeys(_id);

  @override
  Future<void> close() async {
    // No-op: the shared backing is closed once by its owner.
  }
}

/// Lifts a synchronous [MultiSpaceBacking] to [AsyncMultiSpaceBacking] WITHOUT a
/// worker — every call runs the sync op INLINE, wrapped in a resolved `Future`.
/// For the in-memory fake (nothing to offload) + tests; keeps them compiling
/// against the async surface with no behaviour change.
class SyncWrappedAsyncMultiSpaceBacking implements AsyncMultiSpaceBacking {
  SyncWrappedAsyncMultiSpaceBacking(this._inner);

  final MultiSpaceBacking _inner;

  @override
  Future<int> openSpace(Uint8List keys) async => _inner.openSpace(keys);
  @override
  Future<int> commit(int id, List<KvLogOp> ops) async => _inner.commit(id, ops);
  @override
  Future<Uint8List?> get(int id, int namespace, Uint8List key) async =>
      _inner.get(id, namespace, key);
  @override
  Future<Uint8List?> readLog(int id, int namespace, int logId) async =>
      _inner.readLog(id, namespace, logId);
  @override
  Future<List<KvLogEntry>> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async =>
      _inner.iterLogRange(id,
          namespace: namespace, start: start, end: end, limit: limit);
  @override
  Future<int> count(int id, int namespace) async => _inner.count(id, namespace);
  @override
  Future<Uint8List> exportKeys(int id) async => _inner.exportKeys(id);
  @override
  Future<void> scrub(int id) async => _inner.scrub(id);
  @override
  Future<void> close() async => _inner.close();
}
