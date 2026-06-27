import 'dart:typed_data';

/// One piece of a chunked file/media transfer. Files exceed a single overlay
/// datagram, so they are split into ordered chunks identified by a shared
/// [transferId] and reassembled on the receiver.
class FileChunk {
  const FileChunk({
    required this.transferId,
    required this.index,
    required this.total,
    required this.data,
  });

  final String transferId;

  /// 0-based position of this chunk.
  final int index;

  /// Total number of chunks in the transfer.
  final int total;

  final Uint8List data;
}

/// Split [data] into ordered chunks of at most [maxChunk] bytes. Empty input
/// yields a single empty chunk (so the receiver still sees one transfer).
List<FileChunk> chunkBytes(
  Uint8List data, {
  required String transferId,
  int maxChunk = 8192,
}) {
  if (maxChunk <= 0) throw ArgumentError.value(maxChunk, 'maxChunk', 'must be > 0');
  final total = data.isEmpty ? 1 : (data.length + maxChunk - 1) ~/ maxChunk;
  return [
    for (var i = 0; i < total; i++)
      FileChunk(
        transferId: transferId,
        index: i,
        total: total,
        data: Uint8List.sublistView(
          data,
          i * maxChunk,
          (i * maxChunk + maxChunk < data.length)
              ? i * maxChunk + maxChunk
              : data.length,
        ),
      ),
  ];
}

/// Hard ceiling on the declared chunk COUNT of an inbound transfer. The byte
/// budget enforced elsewhere ([FileReassembler.bufferedBytes]) bounds the
/// reassembled DATA, but NOT the per-chunk bookkeeping: a hostile sender could
/// declare (or stream) millions of tiny chunks and stay under the byte cap while
/// the chunk map's per-entry overhead (key + slice object) exhausts memory. This
/// caps the map's entry count. A legitimate 100 MiB transfer at ~6 KB/chunk is
/// ≈ 17.5k chunks, so 65 536 is comfortable headroom yet bounds the worst case.
const kMaxIncomingFileChunks = 1 << 16;

/// Collects [FileChunk]s (in any order, dedup-safe) and reassembles the
/// original bytes once every chunk has arrived.
class FileReassembler {
  FileReassembler({this.maxChunks = kMaxIncomingFileChunks});

  /// Upper bound on the declared [FileChunk.total] / number of buffered chunks.
  /// A transfer declaring more is rejected outright (memory-DoS guard).
  final int maxChunks;

  final Map<int, Uint8List> _chunks = {};
  int? _total;
  int _bytes = 0;

  /// Register a chunk. Out-of-order and duplicate chunks are fine; malformed
  /// chunks are ignored so a hostile sender cannot crash reassembly. Rejected:
  /// a non-positive total, a total above [maxChunks] (memory-DoS guard), an
  /// index outside `[0, total)`, or a total that disagrees with one already seen
  /// (which could otherwise let [isComplete] trip with a missing slot, then
  /// null-crash in [assemble]).
  void add(FileChunk chunk) {
    if (chunk.total < 1 ||
        chunk.total > maxChunks ||
        chunk.index < 0 ||
        chunk.index >= chunk.total) {
      return;
    }
    final total = _total;
    if (total == null) {
      _total = chunk.total;
    } else if (total != chunk.total) {
      return;
    }
    final prev = _chunks[chunk.index];
    if (prev != null) _bytes -= prev.length; // dedup: replace, don't double-count
    _chunks[chunk.index] = chunk.data;
    _bytes += chunk.data.length;
  }

  int get received => _chunks.length;
  int? get total => _total;

  /// The chunk indices in `[0, count)` not yet received — the resumable-transfer
  /// re-request set (a gap-fill [WireKind.fileNack]). [count] is the declared
  /// total (from a chunk's `total` or the transfer meta).
  List<int> missingIndices(int count) =>
      [for (var i = 0; i < count; i++) if (!_chunks.containsKey(i)) i];

  /// Bytes currently buffered (after dedup) — lets a caller abort a transfer
  /// that grows past a memory budget before it completes.
  int get bufferedBytes => _bytes;

  bool get isComplete => _total != null && _chunks.length == _total;

  /// Concatenate the chunks in order. Throws if not yet [isComplete].
  Uint8List assemble() {
    final total = _total;
    if (total == null || _chunks.length != total) {
      throw StateError('transfer incomplete: $received/${_total ?? '?'}');
    }
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      out.add(_chunks[i]!);
    }
    return out.toBytes();
  }
}
