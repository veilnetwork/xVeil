import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/error_journal.dart';
import '../../core/log.dart';
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
const int _kFileChunkGcHighWater = 12000;

/// ...and only RE-ARM that trigger once the live count falls back below this.
///
/// The high mark alone never releases (audit XV-20). Past it a store whose
/// chunks are all live reclaims nothing, the condition stays true, and the
/// pre-write check — a full `count()` leaf walk, plus a whole-settings scan
/// with a JSON decode per key and a paged walk of the ENTIRE chunk log — is
/// then paid for every further chunk, forever, with ~3000 records left before
/// the index refuses writes outright (that refusal has been observed live; see
/// the settings-GC note in `messaging_core.start`).
///
/// The trigger is also not "a big upload": a blob over [kMaxStoredFileBytes]
/// routes to the on-disk tier and never reaches here. What reaches it is ~45 MB
/// of SMALL files — [_kFileChunkGcHighWater] records of [_kStoreRecord] bytes.
const int _kFileChunkGcLowWater = 10000;

/// A sweep that frees fewer ids than this found nothing worth the two scans.
const int _kFileChunkGcMinYield = 64;

/// After such a sweep, skip the check entirely until this many further chunk
/// records have been appended. `file_next_log` is the odometer: it only ever
/// counts up, so no separate counter is needed to measure the interval.
///
/// DELIBERATELY WIDER than the hysteresis band (2000). At exactly the band's
/// width this brake could never fire — climbing from the low mark back to the
/// high one already costs 2000 appends — so it would be a comment rather than a
/// mechanism. At twice the band a re-armed store must earn its next full scan,
/// and the cost of the delay is bounded: the trigger is re-evaluated at most
/// [_kMaxStoredChunks] records later, so the worst case at the moment a sweep
/// finally runs is ~14000 live records, still short of the index ceiling.
const int _kFileChunkGcBackoffChunks = 4000;

/// KV key of the durable chunk accounting — inside the VOLUME, next to the data
/// it describes, because it IS state metadata (how full this container's chunk
/// index is), and that belongs nowhere an observer outside the container can
/// read it.
const String _kChunkGcKey = 'file_chunk_gc';

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

/// Reported into the error journal — never thrown — the one time a sweep proves
/// the chunk index is genuinely full: every record in it is referenced by live
/// metadata, so nothing can be reclaimed and the container is a few thousand
/// records from refusing writes. Reported ONCE per fill (the flag clears as
/// soon as room reappears) so the ceiling is visible instead of arriving as a
/// silent slowdown followed by a hard `IndexFull`.
class FileChunkIndexFull implements Exception {
  const FileChunkIndexFull(this.liveChunks);

  final int liveChunks;

  @override
  String toString() =>
      'FileChunkIndexFull: $liveChunks live file-chunk records and the orphan '
      'sweep reclaimed nothing — the in-volume file store is full';
}

void _reportChunkIndexFull(int liveChunks) {
  devLog(
    () =>
        'xVeil[storage]: file-chunk index FULL — $liveChunks live records, '
        'orphan sweep reclaimed nothing; further stores will hit IndexFull',
  );
  errorJournal.record(
    kind: 'storage-file-chunks-full',
    error: FileChunkIndexFull(liveChunks),
    atMs: DateTime.now().millisecondsSinceEpoch,
  );
}

/// Durable accounting for the chunk-index garbage collector — one small JSON
/// value under [_kChunkGcKey].
///
/// Replaces a `count(Ns.fileChunks)` on the write path. That call walks every
/// leaf of the namespace with no cache (the store's own docs say it is "rarely
/// on a UI hot path"), and it sat on the hottest one there is: once per stored
/// chunk.
class _ChunkGcState {
  const _ChunkGcState({
    required this.live,
    required this.armed,
    required this.retryAt,
    required this.reportedFull,
  });

  /// Seed for a store that has no accounting yet — one written before this
  /// bookkeeping existed, or one whose namespace was just erased. Costs the
  /// single full `count()` that used to be paid per chunk.
  const _ChunkGcState.seed(this.live)
    : armed = true,
      retryAt = 0,
      reportedFull = false;

  /// Estimated live chunk records. Exact for every write this class makes, and
  /// reset to the TRUTH by every sweep — so the one drift source (a caller
  /// folding [AsyncFileStore.deleteFileOps] into its own commit) can only leave
  /// it reading HIGH, which sweeps one time too early rather than too late.
  final int live;

  /// May a sweep start at the high-water mark? Cleared by a sweep that leaves
  /// the store above [_kFileChunkGcLowWater]; this is the hysteresis, and
  /// without it the durable counter alone changes nothing — the condition
  /// simply keeps reporting true from a cheaper source.
  final bool armed;

  /// `file_next_log` value below which no sweep runs at all (the post-sweep
  /// back-off).
  final int retryAt;

  /// Whether the "index is full" report has already been made for this fill.
  final bool reportedFull;

  static _ChunkGcState? decode(Uint8List? raw) {
    if (raw == null) return null;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return null; // corrupt bookkeeping re-seeds; it is a hint, not data
    }
    if (json is! Map<String, dynamic>) return null;
    final live = json['live'];
    if (live is! int || live < 0) return null;
    final retryAt = json['retryAt'];
    return _ChunkGcState(
      live: live,
      armed: json['armed'] != false,
      retryAt: retryAt is int && retryAt > 0 ? retryAt : 0,
      reportedFull: json['full'] == true,
    );
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'live': live,
        'armed': armed,
        'retryAt': retryAt,
        'full': reportedFull,
      }),
    ),
  );

  bool shouldSweep(int incoming, int nextLogId) =>
      armed &&
      nextLogId >= retryAt &&
      live + incoming >= _kFileChunkGcHighWater;

  /// After a commit that appended [appended] records and deleted [deleted] —
  /// folded INTO that commit, so a crash can't leave the count behind the log.
  _ChunkGcState afterWrite({int appended = 0, int deleted = 0}) {
    final next = live + appended - deleted;
    final roomAgain = next < _kFileChunkGcLowWater;
    return _ChunkGcState(
      live: next < 0 ? 0 : next,
      armed: armed || roomAgain,
      retryAt: retryAt,
      reportedFull: reportedFull && !roomAgain,
    );
  }

  /// After a sweep that reclaimed [removed] ids and left [liveNow] behind.
  _ChunkGcState afterSweep({
    required int removed,
    required int liveNow,
    required int nextLogId,
  }) {
    final roomAgain = liveNow < _kFileChunkGcLowWater;
    final lowYield = removed < _kFileChunkGcMinYield;
    return _ChunkGcState(
      live: liveNow,
      armed: roomAgain,
      retryAt: lowYield ? nextLogId + _kFileChunkGcBackoffChunks : 0,
      reportedFull: reportedFull || (lowYield && !roomAgain),
    );
  }

  /// True when this state is the first to conclude the index is full.
  bool newlyFull(_ChunkGcState prior) => reportedFull && !prior.reportedFull;
}

/// One sweep's outcome: what it reclaimed, and the exact live count it saw.
typedef _SweepResult = ({int removed, int live});

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
    final nextBase = chunks.isEmpty ? null : _nextLogId();
    var gc = _gcState();
    if (nextBase != null && gc.shouldSweep(chunks.length, nextBase)) {
      gc = _sweepAndAccount(gc, nextBase).state;
    }
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
      // The accounting rides IN the append commit: chunks written before a
      // crash occupy index slots whether or not the metadata was published, so
      // a counter updated only at the end would under-count exactly the
      // orphans this collector exists to find.
      gc = gc.afterWrite(appended: end - start);
      _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, ids[i], chunks[i].data),
        PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
      ]);
    }
    gc = gc.afterWrite(deleted: priorIds.length);
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
      PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
    ]);
    return fileId;
  }

  /// The durable chunk accounting, seeded from a single full [KvLogStore.count]
  /// the first time (a store written before this bookkeeping existed).
  _ChunkGcState _gcState() =>
      _ChunkGcState.decode(_store.get(Ns.settings, _k(_kChunkGcKey))) ??
      _ChunkGcState.seed(_store.count(Ns.fileChunks));

  ({_ChunkGcState state, int removed}) _sweepAndAccount(
    _ChunkGcState prior,
    int nextLogId,
  ) {
    final swept = _reclaim();
    final next = prior.afterSweep(
      removed: swept.removed,
      liveNow: swept.live,
      nextLogId: nextLogId,
    );
    _store.commit([PutOp(Ns.settings, _k(_kChunkGcKey), next.encode())]);
    if (next.newlyFull(prior)) _reportChunkIndexFull(next.live);
    return (state: next, removed: swept.removed);
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
    if (ops.isEmpty) return;
    final gc = _gcState().afterWrite(
      deleted: ops.whereType<DeleteLogOp>().length,
    );
    _store.commit([
      ...ops,
      PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
    ]);
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
  ///
  /// Also refreshes the durable accounting to the exact live count this scan
  /// saw — the one place the estimate is reconciled with the truth.
  int reclaimOrphanedFileChunkIds() =>
      _sweepAndAccount(_gcState(), _nextLogId()).removed;

  _SweepResult _reclaim() {
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
    var seen = 0;
    int? start;
    while (true) {
      final page = _store.iterLogRange(
        namespace: Ns.fileChunks,
        start: start,
        limit: _kLogScanPage,
      );
      if (page.isEmpty) break;
      seen += page.length;
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
    // Every record was visited exactly once, so this is the exact live count —
    // free, and the only reconciliation the estimate ever needs.
    return (removed: removed, live: seen - removed);
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
    final nextBase = chunks.isEmpty ? null : await _nextLogId();
    var gc = await _gcState();
    if (nextBase != null && gc.shouldSweep(chunks.length, nextBase)) {
      gc = (await _sweepAndAccount(gc, nextBase)).state;
    }
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
      gc = gc.afterWrite(appended: end - start);
      await _store.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, ids[i], chunks[i].data),
        PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
      ]);
    }
    gc = gc.afterWrite(
      deleted:
          priorIds.length + priorPurge.whereType<DeleteLogOp>().length,
    );
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
      PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
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
    final base = await _nextLogId();
    var gc = await _gcState();
    if (gc.shouldSweep(chunks.length, base)) {
      gc = (await _sweepAndAccount(gc, base)).state;
    }
    for (var s = 0; s < chunks.length; s += _kChunksPerCommit) {
      final e = s + _kChunksPerCommit < chunks.length
          ? s + _kChunksPerCommit
          : chunks.length;
      gc = gc.afterWrite(appended: e - s);
      await _store.commit([
        for (var i = s; i < e; i++)
          AppendLogOp(Ns.fileChunks, base + i, chunks[i].data),
        PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
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
      PutOp(Ns.settings, _k(_kChunkGcKey), gc.encode()),
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

  /// The durable chunk accounting, seeded from a single full
  /// [AsyncKvLogStore.count] the first time (a store written before this
  /// bookkeeping existed, or one whose namespace was just erased).
  Future<_ChunkGcState> _gcState() async =>
      _ChunkGcState.decode(await _store.get(Ns.settings, _k(_kChunkGcKey))) ??
      _ChunkGcState.seed(await _store.count(Ns.fileChunks));

  /// Drop the accounting — for a wholesale namespace erase, after which the
  /// stored count describes records that no longer exist. The next write
  /// re-seeds it.
  Future<void> forgetChunkAccounting() async {
    await _store.commit([DeleteOp(Ns.settings, _k(_kChunkGcKey))]);
  }

  /// In-flight sweep, per BACKING STORE rather than per instance: callers build
  /// a throwaway [AsyncFileStore] around the space for every single call, so an
  /// instance field would guard nothing. Weak (an [Expando]) so a closed space
  /// is still collectable.
  static final Expando<Future<({_ChunkGcState state, int removed})>>
  _sweepInFlight = Expando('fileChunkSweep');

  /// Sweep, reconcile the accounting, and report a genuinely full index once.
  /// Single-flight: a second caller joins the running scan instead of starting
  /// a competing full walk of the settings namespace and the whole chunk log.
  Future<({_ChunkGcState state, int removed})> _sweepAndAccount(
    _ChunkGcState prior,
    int nextLogId,
  ) {
    final running = _sweepInFlight[_store];
    if (running != null) return running;
    final started = _runSweep(prior, nextLogId);
    _sweepInFlight[_store] = started;
    unawaited(
      started.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_sweepInFlight[_store], started)) {
          _sweepInFlight[_store] = null;
        }
      }),
    );
    return started;
  }

  Future<({_ChunkGcState state, int removed})> _runSweep(
    _ChunkGcState prior,
    int nextLogId,
  ) async {
    final swept = await _reclaim();
    final next = prior.afterSweep(
      removed: swept.removed,
      liveNow: swept.live,
      nextLogId: nextLogId,
    );
    await _store.commit([PutOp(Ns.settings, _k(_kChunkGcKey), next.encode())]);
    if (next.newlyFull(prior)) _reportChunkIndexFull(next.live);
    return (state: next, removed: swept.removed);
  }

  /// Async twin of [FileStore.reclaimOrphanedFileChunkIds].
  Future<int> reclaimOrphanedFileChunkIds() async =>
      (await _sweepAndAccount(await _gcState(), await _nextLogId())).removed;

  Future<_SweepResult> _reclaim() async {
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
    var seen = 0;
    int? start;
    while (true) {
      final page = await _store.iterLogRange(
        namespace: Ns.fileChunks,
        start: start,
        limit: _kLogScanPage,
      );
      if (page.isEmpty) break;
      seen += page.length;
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
    return (removed: removed, live: seen - removed);
  }
}
