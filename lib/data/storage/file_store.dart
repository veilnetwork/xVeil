import 'dart:convert';
import 'dart:typed_data';

import '../../domain/file_transfer.dart';
import 'async_kv_log_store.dart';
import 'kv_log_store.dart';

/// Storage chunk size: one [Ns.fileChunks] log record. The store caps a record
/// at 8 KiB; stay safely under.
const int _kStoreRecord = 8000;

/// Append at most this many chunk records per commit so the raw batch stays well
/// under the store's ~1 MiB MAX_RAW_BATCH_LEN (≈ 100 × 8 KiB = 800 KiB). A larger
/// blob is committed across several batches.
const int _kChunksPerCommit = 100;

/// Max chunk records a stored file may occupy. A file must be deletable in ONE
/// atomic commit (zero every chunk + drop metadata together so a deleted blob
/// can't linger half-scrubbed), and a commit holds ≤ 1024 records
/// (MAX_RECORDS_PER_BATCH) — so cap just under that.
const int _kMaxStoredChunks = 1000;

/// Largest attachment that can be stored (and atomically deleted): ~8 MB. The
/// send path pre-checks this and surfaces a friendly error instead of letting
/// the storage layer throw [PayloadTooLarge] (uncaught → the attach silently
/// failed before). The ceiling is architectural: 1024 records/commit × 8 KiB.
const int kMaxStoredFileBytes = _kMaxStoredChunks * _kStoreRecord; // 8_000_000

/// Deniable at-rest storage for files (received attachments, sent media) inside
/// the hidden-volume container — NOT plaintext on disk, which would defeat the
/// container's deniability.
///
/// A file is split into <=8KiB records appended to the [Ns.fileChunks] log
/// (the KV value cap is ~2KB, too small for media); a small KV metadata entry
/// `file:<id>` records the name, size, and the contiguous base log id + count.
/// hidden-volume exposes no KV key enumeration, so the base/count let us read
/// the chunks back without scanning.
///
/// A whole file's chunks do NOT fit in one commit: the store caps a single
/// commit (DataBatch) at ~1 MiB ([_maxRawBatchLen]) AND 1024 records, so a
/// multi-MiB blob is appended across SEVERAL commits ([_chunksPerCommit] each),
/// with the metadata published LAST so the file becomes readable only once every
/// chunk is durable. The whole file must still be DELETABLE in one atomic commit
/// (zero every chunk + drop metadata together, so a deleted blob never lingers),
/// and one commit holds at most 1024 records — so a stored file is capped at
/// [kMaxStoredFileBytes] (~8 MB); a larger attachment is rejected up-front.
class FileStore {
  FileStore(this._store);

  final KvLogStore _store;

  /// hidden-volume log records are capped at 8 KiB; stay safely under.
  static const int _maxRecord = _kStoreRecord;

  Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

  int _nextLogId() {
    final raw = _store.get(Ns.settings, _k('file_next_log'));
    return raw == null ? 1 : (int.tryParse(utf8.decode(raw)) ?? 1);
  }

  /// Persist [bytes] under [fileId]; returns [fileId]. The chunks are appended
  /// across one or more commits (a multi-MiB blob can't fit a single ~1 MiB
  /// commit), then the metadata + counter are published in a FINAL commit — so
  /// the file is readable only once every chunk is durable, and a crash mid-store
  /// leaves orphaned chunks with no metadata (loadFile sees nothing; a later
  /// vacuum reclaims them). Throws [ArgumentError] for a blob over
  /// [kMaxStoredFileBytes] (callers should pre-check and surface a friendly
  /// error rather than rely on this backstop).
  String storeFile(String fileId, Uint8List bytes, {String? name}) {
    final chunks = chunkBytes(bytes, transferId: fileId, maxChunk: _maxRecord);
    if (chunks.length > _kMaxStoredChunks) {
      throw ArgumentError.value(
          bytes.length, 'bytes', 'file exceeds $kMaxStoredFileBytes-byte cap');
    }
    final base = _nextLogId();
    for (var start = 0; start < chunks.length; start += _kChunksPerCommit) {
      final end = start + _kChunksPerCommit < chunks.length
          ? start + _kChunksPerCommit
          : chunks.length;
      _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, base + i, chunks[i].data),
      ]);
    }
    _store.commit([
      PutOp(
        Ns.settings,
        _k('file:$fileId'),
        _k(jsonEncode({
          'name': name,
          'size': bytes.length,
          'base': base,
          'count': chunks.length,
        })),
      ),
      PutOp(Ns.settings, _k('file_next_log'), _k('${base + chunks.length}')),
    ]);
    return fileId;
  }

  /// The ops that purge a stored file: overwrite each data record with an empty
  /// payload so the original chunk is orphaned (reclaimed by a later
  /// vacuum/scrub for true erasure) and drop the metadata key. Empty if the id
  /// is unknown. Exposed so a caller can fold these into a LARGER atomic commit
  /// (e.g. delete a file message + its blob in one commit — no crash window
  /// where the chat row and the blob disagree).
  List<KvLogOp> deleteFileOps(String fileId) {
    final raw = _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return const [];
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final base = m['base'] as int;
    final count = m['count'] as int;
    return [
      for (var i = 0; i < count; i++)
        AppendLogOp(Ns.fileChunks, base + i, Uint8List(0)),
      DeleteOp(Ns.settings, _k('file:$fileId')),
    ];
  }

  /// Purge a stored file in its own commit. No-op if the id is unknown.
  void deleteFile(String fileId) {
    final ops = deleteFileOps(fileId);
    if (ops.isNotEmpty) _store.commit(ops);
  }

  FileMeta? metadata(String fileId) {
    final raw = _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return FileMeta(
      fileId: fileId,
      name: m['name'] as String?,
      size: m['size'] as int,
    );
  }

  /// Reassemble the stored file, or null if unknown / a chunk is missing.
  Uint8List? loadFile(String fileId) {
    final raw = _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final base = m['base'] as int;
    final count = m['count'] as int;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      final chunk = _store.readLog(Ns.fileChunks, base + i);
      if (chunk == null) return null;
      out.add(chunk);
    }
    return out.toBytes();
  }
}

/// Lightweight descriptor for a stored file (no bytes).
class FileMeta {
  const FileMeta({required this.fileId, required this.name, required this.size});
  final String fileId;
  final String? name;
  final int size;
}

/// Off-UI-isolate twin of [FileStore] over an [AsyncKvLogStore]. Same on-disk
/// layout and ops; every store call is awaited so the blocking FFI runs on the
/// worker isolate. Used by [HiddenVolumeStorage] once its backing store is
/// async — the sync [FileStore] stays for the in-memory fake + unit tests.
class AsyncFileStore {
  AsyncFileStore(this._store);

  final AsyncKvLogStore _store;

  static const int _maxRecord = _kStoreRecord;

  Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

  Future<int> _nextLogId() async {
    final raw = await _store.get(Ns.settings, _k('file_next_log'));
    return raw == null ? 1 : (int.tryParse(utf8.decode(raw)) ?? 1);
  }

  /// Persist [bytes] under [fileId]; returns [fileId]. The chunks are appended
  /// across one or more commits (a multi-MiB blob can't fit a single ~1 MiB
  /// commit — that threw [PayloadTooLarge] before), then the metadata + counter
  /// are published in a FINAL commit so the file is readable only once every
  /// chunk is durable. Throws [ArgumentError] for a blob over
  /// [kMaxStoredFileBytes] (callers pre-check + surface a friendly error).
  Future<String> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    final chunks = chunkBytes(bytes, transferId: fileId, maxChunk: _maxRecord);
    if (chunks.length > _kMaxStoredChunks) {
      throw ArgumentError.value(
          bytes.length, 'bytes', 'file exceeds $kMaxStoredFileBytes-byte cap');
    }
    final base = await _nextLogId();
    for (var start = 0; start < chunks.length; start += _kChunksPerCommit) {
      final end = start + _kChunksPerCommit < chunks.length
          ? start + _kChunksPerCommit
          : chunks.length;
      await _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, base + i, chunks[i].data),
      ]);
    }
    await _store.commit([
      PutOp(
        Ns.settings,
        _k('file:$fileId'),
        _k(jsonEncode({
          'name': name,
          'size': bytes.length,
          'base': base,
          'count': chunks.length,
        })),
      ),
      PutOp(Ns.settings, _k('file_next_log'), _k('${base + chunks.length}')),
    ]);
    return fileId;
  }

  /// The ops that purge a stored file (see [FileStore.deleteFileOps]). Reads the
  /// metadata to find the chunk range; empty if the id is unknown. Exposed so a
  /// caller can fold these into a LARGER atomic commit.
  Future<List<KvLogOp>> deleteFileOps(String fileId) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return const [];
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final base = m['base'] as int;
    final count = m['count'] as int;
    return [
      for (var i = 0; i < count; i++)
        AppendLogOp(Ns.fileChunks, base + i, Uint8List(0)),
      DeleteOp(Ns.settings, _k('file:$fileId')),
    ];
  }

  /// Reassemble the stored file, or null if unknown / a chunk is missing.
  Future<Uint8List?> loadFile(String fileId) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final base = m['base'] as int;
    final count = m['count'] as int;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      final chunk = await _store.readLog(Ns.fileChunks, base + i);
      if (chunk == null) return null;
      out.add(chunk);
    }
    return out.toBytes();
  }
}
