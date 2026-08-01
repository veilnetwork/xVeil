import 'dart:convert';
import 'dart:typed_data';

import '../../domain/file_transfer.dart';
import 'async_kv_log_store.dart';
import 'kv_log_store.dart';

/// Storage chunk size: one [Ns.fileChunks] log record. The store seals each
/// record's batch into a single 4 KiB container chunk, whose usable payload
/// (after nonce/tag/header) is PAYLOAD_CAP ≈ 4040 bytes — and the batch is zstd-
/// compressed, but media is INCOMPRESSIBLE, so a record only fits if its RAW size
/// (plus ~36 bytes batch+zstd framing) stays under that. 3800 leaves a safe
/// margin. (The old 8000 silently broke every non-trivial file: an 8 KiB
/// incompressible record can't be placed in a 4 KiB chunk even after the store's
/// auto-split, which can't divide below one record → PayloadTooLarge.)
const int _kStoreRecord = 3800;

/// Append at most this many chunk records per commit. The store auto-splits a
/// commit's records into per-chunk DataBatches; keeping each commit modest bounds
/// the split recursion's work while staying well under MAX_RECORDS_PER_BATCH=1024.
const int _kChunksPerCommit = 64;

/// Start a conservative orphan scan before the Log namespace reaches the
/// hidden-volume two-level B+ index's empirical ~15K unique-id ceiling.
const int _kFileChunkGcThreshold = 12000;

const int _kLogScanPage = 512;
// Dart VM integers and the handwritten FFI binding use the non-negative i64
// range for log ids even though Rust stores them as u64.
const int _kMaxDartLogId = 0x7fffffffffffffff;

/// Constant-work byte compare for the idempotent re-store check (not
/// secret-dependent — just avoids allocating).
bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

typedef _RecordSegment = ({int base, int count});

/// Whole-file metadata v2 can name several contiguous record runs. Current
/// writers publish one fresh run per replacement; readers accept several runs
/// so stores written by the pre-DeleteLog development build remain readable.
List<_RecordSegment> _fileSegments(Map<String, dynamic> metadata) {
  final encoded = metadata['segments'];
  if (encoded is List) {
    final result = <_RecordSegment>[];
    var total = 0;
    for (final item in encoded) {
      if (item is! List || item.length != 2) {
        throw const FormatException('invalid file segments');
      }
      final base = item[0];
      final count = item[1];
      if (base is! int || count is! int || base < 1 || count < 1) {
        throw const FormatException('invalid file segment');
      }
      total += count;
      if (total > _kMaxStoredChunks) {
        throw const FormatException('too many file records');
      }
      result.add((base: base, count: count));
    }
    return result;
  }
  final base = metadata['base'];
  final count = metadata['count'];
  if (base is! int || count is! int || base < 1 || count < 0) {
    throw const FormatException('invalid legacy file run');
  }
  return count == 0 ? const [] : [(base: base, count: count)];
}

List<int> _recordIds(Iterable<_RecordSegment> segments) => [
  for (final segment in segments)
    for (var offset = 0; offset < segment.count; offset++)
      segment.base + offset,
];

List<List<int>> _encodeSegments(List<int> ids) {
  if (ids.isEmpty) return const [];
  final result = <List<int>>[];
  var base = ids.first;
  var prior = base;
  var count = 1;
  for (final id in ids.skip(1)) {
    if (id == prior + 1) {
      count++;
    } else {
      result.add([base, count]);
      base = id;
      count = 1;
    }
    prior = id;
  }
  result.add([base, count]);
  return result;
}

bool _startsWith(Uint8List value, List<int> prefix) {
  if (value.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (value[i] != prefix[i]) return false;
  }
  return true;
}

const _fileKeyPrefix = <int>[102, 105, 108, 101, 58]; // `file:`
const _pieceKeyPrefix = <int>[
  102,
  105,
  108,
  101,
  112,
  105,
  101,
  99,
  101,
  58,
]; // `filepiece:`

void _addPieceRecords(Set<int> active, Map<String, dynamic> metadata) {
  final base = metadata['base'];
  final count = metadata['count'];
  if (base is! int || count is! int || base < 1 || count < 0) {
    throw const FormatException('invalid streamed file piece run');
  }
  if (count > _kMaxStoredChunks) {
    throw const FormatException('too many streamed file piece records');
  }
  for (var offset = 0; offset < count; offset++) {
    active.add(base + offset);
  }
}

/// Max chunk records a stored file may occupy. A file must be deletable in ONE
/// atomic commit (delete every record id + drop metadata together so a blob
/// can't linger half-scrubbed), and a commit holds ≤ 1024 records
/// (MAX_RECORDS_PER_BATCH) — so cap just under that.
const int _kMaxStoredChunks = 1000;

/// Largest attachment that can be stored (and atomically deleted): ~3.6 MB. The
/// send path pre-checks this and surfaces a friendly error instead of letting
/// the storage layer throw [PayloadTooLarge] (uncaught → the attach silently
/// failed before). The ceiling is architectural: a 4 KiB container chunk holds
/// one ≤3800-byte record, and an atomic delete fits ≤1024 of them in one commit.
const int kMaxStoredFileBytes = _kMaxStoredChunks * _kStoreRecord; // 3_800_000

/// Deniable at-rest storage for files (received attachments, sent media) inside
/// the hidden-volume container — NOT plaintext on disk, which would defeat the
/// container's deniability.
///
/// A file is split into [_kStoreRecord]-byte records appended to the
/// [Ns.fileChunks] log; a small KV metadata entry `file:<id>` records the name,
/// size, and one or more contiguous record-id segments. Replacements write a
/// fresh run, then atomically publish it while removing the prior run.
///
/// The record size is bound by the on-disk format, NOT a generous KV cap: the
/// store seals each record into a 4 KiB container chunk (PAYLOAD_CAP ≈ 4040 B of
/// usable, zstd-compressed payload), and media is incompressible — so a record
/// must stay under ~4 KB raw or it can't be placed at all (the store's auto-split
/// can't divide below one record → PayloadTooLarge). The earlier 8 KiB chunk
/// silently broke every file over a few KB.
///
/// A multi-MiB blob is appended across SEVERAL commits ([_kChunksPerCommit] each),
/// with the metadata published LAST so the file becomes readable only once every
/// chunk is durable. The whole file must still be DELETABLE in one atomic commit
/// (delete every record id + drop metadata together, so a deleted blob never lingers),
/// and one commit holds at most 1024 records — so a stored file is capped at
/// [kMaxStoredFileBytes] (~3.6 MB); a larger attachment is rejected up-front.
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
    // Empty wire transfers still need one marker chunk, but empty at-rest files
    // need no Log record: metadata with `segments: []` is sufficient.
    final chunks = bytes.isEmpty
        ? const <FileChunk>[]
        : chunkBytes(bytes, transferId: fileId, maxChunk: _maxRecord);
    if (chunks.length > _kMaxStoredChunks) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'file exceeds $kMaxStoredFileBytes-byte cap',
      );
    }
    // Re-storing an id is common for crash-safe A/B materialized views. A
    // changed value gets a FRESH run: overwriting the old ids before publishing
    // metadata would corrupt the still-visible old version if the process
    // crashed mid-write. The final commit publishes the new metadata and
    // deletes every old id atomically; DeleteLog prevents index-capacity leaks.
    final metadataRaw = _store.get(Ns.settings, _k('file:$fileId'));
    final metadata = metadataRaw == null
        ? null
        : jsonDecode(utf8.decode(metadataRaw)) as Map<String, dynamic>;
    final prior = metadata == null ? null : loadFile(fileId);
    if (prior != null && _sameBytes(prior, bytes)) return fileId;
    final priorIds = metadata == null
        ? const <int>[]
        : _recordIds(_fileSegments(metadata));
    if (chunks.isNotEmpty &&
        _store.count(Ns.fileChunks) + chunks.length >= _kFileChunkGcThreshold) {
      reclaimOrphanedFileChunkIds();
    }
    final nextBase = chunks.isEmpty ? null : _nextLogId();
    final ids = nextBase == null
        ? const <int>[]
        : [
            for (var offset = 0; offset < chunks.length; offset++)
              nextBase + offset,
          ];
    for (var start = 0; start < chunks.length; start += _kChunksPerCommit) {
      final end = start + _kChunksPerCommit < chunks.length
          ? start + _kChunksPerCommit
          : chunks.length;
      _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, ids[i], chunks[i].data),
      ]);
    }
    _store.commit([
      for (final id in priorIds) DeleteLogOp(Ns.fileChunks, id),
      PutOp(
        Ns.settings,
        _k('file:$fileId'),
        _k(
          jsonEncode({
            'name': name,
            'size': bytes.length,
            'segments': _encodeSegments(ids),
          }),
        ),
      ),
      if (nextBase != null)
        PutOp(
          Ns.settings,
          _k('file_next_log'),
          _k('${nextBase + chunks.length}'),
        ),
    ]);
    return fileId;
  }

  /// The ops that purge a stored file: remove each record id from the Log index
  /// (the old DataBatch is reclaimed by a later vacuum/scrub for true erasure)
  /// and drop the metadata key. Empty if the id is unknown. Exposed so a caller
  /// can fold these into a LARGER atomic commit
  /// (e.g. delete a file message + its blob in one commit — no crash window
  /// where the chat row and the blob disagree).
  List<KvLogOp> deleteFileOps(String fileId) {
    final raw = _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return const [];
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return [
      for (final id in _recordIds(_fileSegments(m)))
        DeleteLogOp(Ns.fileChunks, id),
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
    final out = BytesBuilder(copy: false);
    for (final id in _recordIds(_fileSegments(m))) {
      final chunk = _store.readLog(Ns.fileChunks, id);
      if (chunk == null) return null;
      out.add(chunk);
    }
    return out.toBytes();
  }

  /// Release Log-index capacity consumed by crash-orphaned chunks and legacy
  /// empty-payload tombstones. The live set is derived from every whole-file
  /// and streamed-piece metadata record first; malformed metadata aborts before
  /// any mutation, so the collector fails closed rather than risking data loss.
  int reclaimOrphanedFileChunkIds() {
    final active = <int>{};
    for (final key in _store.kvKeys(Ns.settings)) {
      final isPiece = _startsWith(key, _pieceKeyPrefix);
      final isFile = _startsWith(key, _fileKeyPrefix);
      if (!isPiece && !isFile) continue;
      final raw = _store.get(Ns.settings, key);
      if (raw == null) continue;
      final metadata = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      if (isPiece) {
        _addPieceRecords(active, metadata);
      } else if (metadata['streamed'] != true) {
        active.addAll(_recordIds(_fileSegments(metadata)));
      }
    }

    var removed = 0;
    int? start;
    while (true) {
      final page = _store.iterLogRange(
        namespace: Ns.fileChunks,
        start: start,
        limit: _kLogScanPage,
      );
      if (page.isEmpty) break;
      final orphanIds = [
        for (final entry in page)
          if (!active.contains(entry.logId)) entry.logId,
      ];
      for (var offset = 0; offset < orphanIds.length; offset += _kLogScanPage) {
        final end = offset + _kLogScanPage < orphanIds.length
            ? offset + _kLogScanPage
            : orphanIds.length;
        _store.commit([
          for (final id in orphanIds.sublist(offset, end))
            DeleteLogOp(Ns.fileChunks, id),
        ]);
        removed += end - offset;
      }
      final last = page.last.logId;
      if (page.length < _kLogScanPage || last >= _kMaxDartLogId) break;
      start = last + 1;
    }
    return removed;
  }
}

/// Lightweight descriptor for a stored file (no bytes).
class FileMeta {
  const FileMeta({
    required this.fileId,
    required this.name,
    required this.size,
  });
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
  Future<String> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
  }) async {
    final chunks = bytes.isEmpty
        ? const <FileChunk>[]
        : chunkBytes(bytes, transferId: fileId, maxChunk: _maxRecord);
    if (chunks.length > _kMaxStoredChunks) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'file exceeds $kMaxStoredFileBytes-byte cap',
      );
    }
    // Same idempotent/fresh-run policy as the sync twin. When replacing a
    // streamed file, retain its old piece runs until the final metadata commit
    // so a crash during the new writes leaves the old version intact.
    final metadataRaw = await _store.get(Ns.settings, _k('file:$fileId'));
    var metadata = metadataRaw == null
        ? null
        : jsonDecode(utf8.decode(metadataRaw)) as Map<String, dynamic>;
    final prior = metadata == null ? null : await loadFile(fileId);
    if (prior != null && _sameBytes(prior, bytes)) return fileId;
    var priorPurge = const <KvLogOp>[];
    if (metadata?['streamed'] == true) {
      priorPurge = await deleteFileOps(fileId);
      metadata = null;
    }
    final priorIds = metadata == null
        ? const <int>[]
        : _recordIds(_fileSegments(metadata));
    if (chunks.isNotEmpty &&
        await _store.count(Ns.fileChunks) + chunks.length >=
            _kFileChunkGcThreshold) {
      await reclaimOrphanedFileChunkIds();
    }
    final nextBase = chunks.isEmpty ? null : await _nextLogId();
    final ids = nextBase == null
        ? const <int>[]
        : [
            for (var offset = 0; offset < chunks.length; offset++)
              nextBase + offset,
          ];
    for (var start = 0; start < chunks.length; start += _kChunksPerCommit) {
      final end = start + _kChunksPerCommit < chunks.length
          ? start + _kChunksPerCommit
          : chunks.length;
      await _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, ids[i], chunks[i].data),
      ]);
    }
    await _store.commit([
      ...priorPurge,
      for (final id in priorIds) DeleteLogOp(Ns.fileChunks, id),
      PutOp(
        Ns.settings,
        _k('file:$fileId'),
        _k(
          jsonEncode({
            'name': name,
            'size': bytes.length,
            'segments': _encodeSegments(ids),
          }),
        ),
      ),
      if (nextBase != null)
        PutOp(
          Ns.settings,
          _k('file_next_log'),
          _k('${nextBase + chunks.length}'),
        ),
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
    final ops = <KvLogOp>[];
    if (m['streamed'] == true) {
      // A STREAMED blob is a set of per-piece record-runs (see storeFilePiece) —
      // scrub each run + drop its piece-map entry, then the file metadata.
      final pieceCount = m['pieceCount'] as int? ?? 0;
      for (var p = 0; p < pieceCount; p++) {
        final pr = await _store.get(Ns.settings, _k('filepiece:$fileId:$p'));
        if (pr == null) continue;
        final pm = jsonDecode(utf8.decode(pr)) as Map<String, dynamic>;
        final pb = pm['base'] as int, pc = pm['count'] as int;
        for (var i = 0; i < pc; i++) {
          ops.add(DeleteLogOp(Ns.fileChunks, pb + i));
        }
        ops.add(DeleteOp(Ns.settings, _k('filepiece:$fileId:$p')));
      }
      ops.add(DeleteOp(Ns.settings, _k('file:$fileId')));
      return ops;
    }
    for (final id in _recordIds(_fileSegments(m))) {
      ops.add(DeleteLogOp(Ns.fileChunks, id));
    }
    ops.add(DeleteOp(Ns.settings, _k('file:$fileId')));
    return ops;
  }

  /// True iff a file is FULLY available: a whole-blob is present, a STREAMED file
  /// only once all its pieces are stored. A partially-downloaded streamed file
  /// answers false (it is still an offer being fetched).
  Future<bool> hasFile(String fileId) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return false;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    if (m['streamed'] == true) {
      return (m['stored'] as int? ?? 0) >= (m['pieceCount'] as int? ?? 1);
    }
    return true;
  }

  /// Store ONE piece of a STREAMED file incrementally (its own record-run, keyed
  /// by piece index), so the receiver never holds the whole file in RAM and the
  /// file size is bounded only by disk, not [kMaxStoredFileBytes]. Idempotent per
  /// (fileId, pieceIndex); the file becomes [hasFile]-complete once all
  /// [pieceCount] pieces are stored.
  Future<void> storeFilePiece(
    String fileId,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes, {
    String? name,
  }) async {
    if (await _store.get(Ns.settings, _k('filepiece:$fileId:$pieceIndex')) !=
        null) {
      return; // already have this piece
    }
    final chunks = chunkBytes(
      bytes,
      transferId: '$fileId:$pieceIndex',
      maxChunk: _maxRecord,
    );
    if (await _store.count(Ns.fileChunks) + chunks.length >=
        _kFileChunkGcThreshold) {
      await reclaimOrphanedFileChunkIds();
    }
    final base = await _nextLogId();
    for (var s = 0; s < chunks.length; s += _kChunksPerCommit) {
      final e = s + _kChunksPerCommit < chunks.length
          ? s + _kChunksPerCommit
          : chunks.length;
      await _store.commit([
        for (var i = s; i < e; i++)
          AppendLogOp(Ns.fileChunks, base + i, chunks[i].data),
      ]);
    }
    final metaRaw = await _store.get(Ns.settings, _k('file:$fileId'));
    final meta = metaRaw != null
        ? jsonDecode(utf8.decode(metaRaw)) as Map<String, dynamic>
        : <String, dynamic>{};
    final stored = (meta['stored'] as int? ?? 0) + 1;
    await _store.commit([
      PutOp(
        Ns.settings,
        _k('filepiece:$fileId:$pieceIndex'),
        _k(
          jsonEncode({
            'base': base,
            'count': chunks.length,
            'len': bytes.length,
          }),
        ),
      ),
      PutOp(
        Ns.settings,
        _k('file:$fileId'),
        _k(
          jsonEncode({
            'name': name ?? meta['name'],
            'size': totalSize,
            'pieceCount': pieceCount,
            'pieceSize': pieceSize,
            'streamed': true,
            'stored': stored,
          }),
        ),
      ),
      PutOp(Ns.settings, _k('file_next_log'), _k('${base + chunks.length}')),
    ]);
  }

  /// Read [length] bytes at [offset] of the stored file WITHOUT loading the whole
  /// thing — reads only the records covering the range (per-piece for a streamed
  /// file). Lets the sender serve a wire chunk straight from disk. Null if unknown
  /// / a needed record is missing.
  Future<Uint8List?> readFileRange(
    String fileId,
    int offset,
    int length,
  ) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    if (m['streamed'] != true) {
      return _readRecordIdsRange(
        _recordIds(_fileSegments(m)),
        m['size'] as int,
        offset,
        length,
      );
    }
    final pieceSize = m['pieceSize'] as int;
    final size = m['size'] as int;
    final out = BytesBuilder(copy: false);
    var pos = offset.clamp(0, size);
    final end = (offset + length).clamp(0, size);
    while (pos < end) {
      final pIdx = pos ~/ pieceSize;
      final pr = await _store.get(Ns.settings, _k('filepiece:$fileId:$pIdx'));
      if (pr == null) return null;
      final pm = jsonDecode(utf8.decode(pr)) as Map<String, dynamic>;
      final inPiece = pos - pIdx * pieceSize;
      final pLen = pm['len'] as int;
      final take = (end - pos) < (pLen - inPiece)
          ? (end - pos)
          : (pLen - inPiece);
      if (take <= 0) break;
      final got = await _readRecordRange(
        pm['base'] as int,
        pm['count'] as int,
        pLen,
        inPiece,
        take,
      );
      if (got == null) return null;
      out.add(got);
      pos += take;
    }
    return out.toBytes();
  }

  /// Read [length] bytes at [start] from a record-run `[base, base+count)` of
  /// logical length [runLen] (records are [_maxRecord] B, the last possibly short).
  Future<Uint8List?> _readRecordRange(
    int base,
    int count,
    int runLen,
    int start,
    int length,
  ) async {
    final out = BytesBuilder(copy: false);
    var pos = start.clamp(0, runLen);
    final end = (start + length).clamp(0, runLen);
    while (pos < end) {
      final recIdx = pos ~/ _maxRecord;
      if (recIdx >= count) break;
      final rec = await _store.readLog(Ns.fileChunks, base + recIdx);
      if (rec == null) return null;
      final inRec = pos % _maxRecord;
      final take = (end - pos) < (rec.length - inRec)
          ? (end - pos)
          : (rec.length - inRec);
      if (take <= 0) break;
      out.add(Uint8List.sublistView(rec, inRec, inRec + take));
      pos += take;
    }
    return out.toBytes();
  }

  Future<Uint8List?> _readRecordIdsRange(
    List<int> ids,
    int runLen,
    int start,
    int length,
  ) async {
    final out = BytesBuilder(copy: false);
    var pos = start.clamp(0, runLen);
    final end = (start + length).clamp(0, runLen);
    while (pos < end) {
      final recordIndex = pos ~/ _maxRecord;
      if (recordIndex >= ids.length) break;
      final record = await _store.readLog(Ns.fileChunks, ids[recordIndex]);
      if (record == null) return null;
      final inRecord = pos % _maxRecord;
      final take = (end - pos) < (record.length - inRecord)
          ? end - pos
          : record.length - inRecord;
      if (take <= 0) break;
      out.add(Uint8List.sublistView(record, inRecord, inRecord + take));
      pos += take;
    }
    return out.toBytes();
  }

  /// Byte length of a stored file, or null if unknown. Reads only the metadata
  /// record, so a caller can size a streamed response without touching a
  /// single chunk.
  Future<int?> fileSize(String fileId) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final size = m['size'];
    return size is int ? size : null;
  }

  /// Reassemble the whole stored file, or null if unknown / incomplete. For a
  /// large STREAMED file prefer [readFileRange] to avoid holding it all in RAM.
  Future<Uint8List?> loadFile(String fileId) async {
    final raw = await _store.get(Ns.settings, _k('file:$fileId'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    if (m['streamed'] == true) {
      return readFileRange(fileId, 0, m['size'] as int);
    }
    final out = BytesBuilder(copy: false);
    for (final id in _recordIds(_fileSegments(m))) {
      final chunk = await _store.readLog(Ns.fileChunks, id);
      if (chunk == null) return null;
      out.add(chunk);
    }
    return out.toBytes();
  }

  /// Async twin of [FileStore.reclaimOrphanedFileChunkIds].
  Future<int> reclaimOrphanedFileChunkIds() async {
    final active = <int>{};
    for (final key in await _store.kvKeys(Ns.settings)) {
      final isPiece = _startsWith(key, _pieceKeyPrefix);
      final isFile = _startsWith(key, _fileKeyPrefix);
      if (!isPiece && !isFile) continue;
      final raw = await _store.get(Ns.settings, key);
      if (raw == null) continue;
      final metadata = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      if (isPiece) {
        _addPieceRecords(active, metadata);
      } else if (metadata['streamed'] != true) {
        active.addAll(_recordIds(_fileSegments(metadata)));
      }
    }

    var removed = 0;
    int? start;
    while (true) {
      final page = await _store.iterLogRange(
        namespace: Ns.fileChunks,
        start: start,
        limit: _kLogScanPage,
      );
      if (page.isEmpty) break;
      final orphanIds = [
        for (final entry in page)
          if (!active.contains(entry.logId)) entry.logId,
      ];
      for (var offset = 0; offset < orphanIds.length; offset += _kLogScanPage) {
        final end = offset + _kLogScanPage < orphanIds.length
            ? offset + _kLogScanPage
            : orphanIds.length;
        await _store.commit([
          for (final id in orphanIds.sublist(offset, end))
            DeleteLogOp(Ns.fileChunks, id),
        ]);
        removed += end - offset;
      }
      final last = page.last.logId;
      if (page.length < _kLogScanPage || last >= _kMaxDartLogId) break;
      start = last + 1;
    }
    return removed;
  }
}
