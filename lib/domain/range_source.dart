// The one streaming contract for large data (audit remediation 2: "source →
// verifier/decryptor → authorized sink"). Everything that used to move a whole
// `Uint8List` — REST downloads, folder sync, media playback — asks for ranges
// through this instead.
//
// It exists as its own type because the alternative kept reappearing: each
// layer grew its own "size plus a reader" record, and a blob crossing two of
// them was materialised at the seam to convert between them, which is the leak
// the streaming work removes.

import 'dart:typed_data';

/// A blob that can be read in ranges without ever existing whole in memory.
class RangeSource {
  const RangeSource({required this.size, required this.read, this.close});

  /// Full length of the blob, independent of any range actually read.
  final int size;

  /// Reads up to [length] bytes at [offset].
  ///
  /// Null means the blob stopped being readable — deleted, a missing record, a
  /// closed handle. Callers must treat that as failure rather than as an end
  /// of data: a short read that looks like a clean finish is how a truncated
  /// file gets mistaken for a complete one.
  final Future<Uint8List?> Function(int offset, int length) read;

  /// Releases whatever the source holds open. Null when it holds nothing.
  final Future<void> Function()? close;

  Future<void> dispose() async => close == null ? null : await close!();
}

/// Bytes moved per hop by the shared walkers. Bounds the peak at one chunk
/// rather than one file.
const int kRangeChunkBytes = 256 * 1024;

/// Raised when a source dies partway through a walk.
class RangeSourceUnreadable implements Exception {
  const RangeSourceUnreadable(this.offset);
  final int offset;
  @override
  String toString() => 'range source became unreadable at offset $offset';
}

/// Walk [total] bytes of [source] from [start] in hops of at most [chunkBytes].
///
/// The single traversal used by every sink, so they all inherit the same two
/// guarantees rather than each re-deriving them: no hop exceeds the bound, and
/// the walk yields EXACTLY [total] bytes even if a reader hands back more than
/// it was asked for. Over-delivery matters wherever a `Content-Length` has
/// already been promised.
///
/// Throws [RangeSourceUnreadable] rather than ending short.
Stream<Uint8List> rangeChunks(
  RangeSource source,
  int start,
  int total, {
  int chunkBytes = kRangeChunkBytes,
}) async* {
  var sent = 0;
  while (sent < total) {
    final want = total - sent;
    final chunk = await source.read(
      start + sent,
      want < chunkBytes ? want : chunkBytes,
    );
    if (chunk == null || chunk.isEmpty) throw RangeSourceUnreadable(start + sent);
    final take = chunk.length > want
        ? Uint8List.sublistView(chunk, 0, want)
        : chunk;
    yield take;
    sent += take.length;
  }
}

/// Raised when a caller that must buffer is handed something too big to hold.
class RangeSourceTooLarge implements Exception {
  const RangeSourceTooLarge(this.size, this.limit);
  final int size;
  final int limit;
  @override
  String toString() =>
      'source of $size bytes exceeds the $limit-byte buffering limit';
}

/// Read a source fully into memory, refusing anything over [limit].
///
/// The one sanctioned way back from a stream to a byte array, so the cap that
/// makes it safe lives in a single place instead of being re-decided (or
/// forgotten) per caller. Exists for consumers that genuinely cannot stream —
/// a whole-buffer demuxer, say — and fails loudly rather than letting them
/// quietly reinstate the unbounded read.
///
/// Returns null if the source went unreadable partway.
Future<Uint8List?> drainRangeSource(
  RangeSource source, {
  required int limit,
}) async {
  if (source.size > limit) throw RangeSourceTooLarge(source.size, limit);
  final out = BytesBuilder(copy: false);
  try {
    await for (final chunk in rangeChunks(source, 0, source.size)) {
      out.add(chunk);
    }
  } on RangeSourceUnreadable {
    return null;
  }
  return out.toBytes();
}

/// A source over bytes already in hand.
///
/// For callers that genuinely hold the whole thing and cannot stream. Do NOT
/// use it to wrap a whole-file read: that is the leak, relocated.
RangeSource bytesRangeSource(Uint8List bytes) => RangeSource(
  size: bytes.length,
  read: (offset, length) async {
    if (offset >= bytes.length) return Uint8List(0);
    final end = offset + length;
    return Uint8List.sublistView(
      bytes,
      offset,
      end > bytes.length ? bytes.length : end,
    );
  },
);
