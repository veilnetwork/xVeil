// Bridges the storage layer's range reader to the API layer's streaming
// response. One place, because every REST download used to spell the same
// mistake independently: ask the store for the WHOLE blob, then hand the byte
// array to the socket. Two copies of a multi-GB file in a phone's RAM is not a
// download, it is a crash — and it needs no attacker, just an ordinary large
// file and a read-only token.

import 'dart:typed_data';

import '../data/storage/storage.dart';
import 'api_server.dart';

/// Open a stored blob as a streamable [ApiBlobSource], or null when the file is
/// unknown or incomplete.
///
/// Reads only the size record up front; the bytes themselves are pulled by the
/// HTTP writer in bounded chunks, so peak memory is one chunk rather than one
/// file. [contentType] is what the response advertises.
Future<ApiBlobSource?> storedBlobSource(
  Storage storage,
  String fileId, {
  String contentType = 'application/octet-stream',
}) async {
  final size = await storage.fileSize(fileId);
  if (size == null) return null;
  return ApiBlobSource(
    size: size,
    contentType: contentType,
    read: (offset, length) => storage.readFileRange(fileId, offset, length),
  );
}

/// Thrown by [drainBlobSource] when a blob is too large to hold in RAM.
class BlobTooLargeToBuffer implements Exception {
  const BlobTooLargeToBuffer(this.size, this.limit);
  final int size;
  final int limit;
  @override
  String toString() =>
      'blob of $size bytes exceeds the $limit-byte buffering limit — stream it';
}

/// Read a source fully into memory, refusing anything over [limit].
///
/// The ONLY sanctioned way back from a stream to a byte array, so the cap that
/// makes it safe lives in one place instead of being re-decided (or forgotten)
/// per caller. A blob big enough to matter must be streamed; this exists for
/// the consumers that genuinely cannot, and it fails loudly rather than
/// letting them quietly reintroduce the unbounded read.
///
/// Returns null if the blob became unreadable partway.
Future<Uint8List?> drainBlobSource(
  ApiBlobSource source, {
  int limit = kMaxInlineBinaryResponseBytes,
}) async {
  if (source.size > limit) throw BlobTooLargeToBuffer(source.size, limit);
  final out = BytesBuilder(copy: false);
  try {
    await for (final chunk in blobChunks(source, 0, source.size)) {
      out.add(chunk);
    }
  } on BlobUnreadable {
    return null;
  }
  return out.toBytes();
}

/// An [ApiBlobSource] over bytes already resident in memory.
///
/// For callers that genuinely have the whole thing and cannot stream — a
/// generated document, a thumbnail — so they still travel the one response
/// path that speaks `Range`, rather than reintroducing a second, unbounded
/// one. Do NOT use it to wrap a whole-file read: that is the leak, moved.
ApiBlobSource inMemoryBlobSource(
  Uint8List bytes, {
  String contentType = 'application/octet-stream',
}) => ApiBlobSource(
  size: bytes.length,
  contentType: contentType,
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
