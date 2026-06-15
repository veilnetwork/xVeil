import 'dart:typed_data';

/// Namespace tags inside a hidden-volume space. Byte 0 is RESERVED by the
/// library; these mirror the conventional layout from the integration guide.
class Ns {
  static const int settings = 1;
  static const int contacts = 2;
  static const int messageLog = 3;
  static const int media = 4;

  /// Append-log namespace for file-transfer chunk bytes (KV values are capped
  /// ~2KB, so large files live here as <=8KiB log records — deniable, in the
  /// container, not plaintext on disk).
  static const int fileChunks = 5;
}

/// A single write in an atomic [KvLogStore.commit] batch. Mirrors
/// hidden-volume's `WriteOp` so the real adapter maps 1:1 onto `ffi.HvWriteOp`.
sealed class KvLogOp {
  const KvLogOp();
}

class PutOp extends KvLogOp {
  const PutOp(this.namespace, this.key, this.value);
  final int namespace;
  final Uint8List key;
  final Uint8List value;
}

class DeleteOp extends KvLogOp {
  const DeleteOp(this.namespace, this.key);
  final int namespace;
  final Uint8List key;
}

class AppendLogOp extends KvLogOp {
  const AppendLogOp(this.namespace, this.logId, this.payload);
  final int namespace;
  final int logId;
  final Uint8List payload;
}

class KvLogEntry {
  const KvLogEntry(this.logId, this.payload);
  final int logId;
  final Uint8List payload;
}

/// Thin port over a single unlocked hidden-volume space (KV + append-log,
/// atomic batched commits). The production adapter wraps `HvSpace`; the fake
/// is pure in-memory. Note: hidden-volume exposes no KV key enumeration —
/// callers must derive listings from the iterable append-log.
abstract interface class KvLogStore {
  /// Apply a batch atomically; returns the new commit sequence.
  int commit(List<KvLogOp> ops);

  Uint8List? get(int namespace, Uint8List key);

  Uint8List? readLog(int namespace, int logId);

  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });

  int count(int namespace);

  /// Reclaim/overwrite data chunks orphaned by replaced or tombstoned log
  /// records (the edit/delete path) so the prior plaintext is no longer
  /// recoverable from the container. Maps to hidden-volume's
  /// `vacuum_data_batches`/`compact_known`; a no-op where unsupported.
  void scrub();

  void close();
}

/// Opens (or creates) the space for [password]. Returns null when no space
/// matches — the production opener maps hidden-volume's `AuthFailed` (which
/// deliberately conflates "wrong password" and "no such space") to null.
typedef SpaceOpener = KvLogStore? Function({
  required Uint8List password,
  required bool create,
});
