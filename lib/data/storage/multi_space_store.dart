import 'dart:typed_data';

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
