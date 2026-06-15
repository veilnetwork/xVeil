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

/// Collects [FileChunk]s (in any order, dedup-safe) and reassembles the
/// original bytes once every chunk has arrived.
class FileReassembler {
  final Map<int, Uint8List> _chunks = {};
  int? _total;

  /// Register a chunk. Out-of-order and duplicate chunks are fine; malformed
  /// chunks are ignored so a hostile sender cannot crash reassembly. Rejected:
  /// a non-positive total, an index outside `[0, total)`, or a total that
  /// disagrees with one already seen (which could otherwise let [isComplete]
  /// trip with a missing slot, then null-crash in [assemble]).
  void add(FileChunk chunk) {
    if (chunk.total < 1 || chunk.index < 0 || chunk.index >= chunk.total) return;
    final total = _total;
    if (total == null) {
      _total = chunk.total;
    } else if (total != chunk.total) {
      return;
    }
    _chunks[chunk.index] = chunk.data;
  }

  int get received => _chunks.length;
  int? get total => _total;

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
