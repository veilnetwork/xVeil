import 'dart:convert';
import 'dart:typed_data';

import '../../domain/file_transfer.dart';
import 'kv_log_store.dart';

/// Deniable at-rest storage for files (received attachments, sent media) inside
/// the hidden-volume container — NOT plaintext on disk, which would defeat the
/// container's deniability.
///
/// A file is split into <=8KiB records appended to the [Ns.fileChunks] log
/// (the KV value cap is ~2KB, too small for media); a small KV metadata entry
/// `file:<id>` records the name, size, and the contiguous base log id + count.
/// hidden-volume exposes no KV key enumeration, so the base/count let us read
/// the chunks back without scanning.
class FileStore {
  FileStore(this._store);

  final KvLogStore _store;

  /// hidden-volume log records are capped at 8 KiB; stay safely under.
  static const int _maxRecord = 8000;

  Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

  int _nextLogId() {
    final raw = _store.get(Ns.settings, _k('file_next_log'));
    return raw == null ? 1 : (int.tryParse(utf8.decode(raw)) ?? 1);
  }

  /// Persist [bytes] under [fileId]; returns [fileId]. Atomic (all chunks +
  /// metadata + counter in one commit).
  String storeFile(String fileId, Uint8List bytes, {String? name}) {
    final base = _nextLogId();
    final chunks = chunkBytes(bytes, transferId: fileId, maxChunk: _maxRecord);
    final ops = <KvLogOp>[
      for (var i = 0; i < chunks.length; i++)
        AppendLogOp(Ns.fileChunks, base + i, chunks[i].data),
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
    ];
    _store.commit(ops);
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
