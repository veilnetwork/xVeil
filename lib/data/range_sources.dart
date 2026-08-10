// Concrete [RangeSource]s for the two places large blobs actually live: a file
// on disk and the encrypted container.

import 'dart:io';
import 'dart:typed_data';

import '../domain/range_source.dart';
import 'storage/storage.dart';

/// Open a local file for reading in ranges. Null if it cannot be opened.
///
/// The caller must [RangeSource.dispose] it — the handle stays open for the
/// life of the source, which is the point: reopening per hop would turn a
/// seek-heavy player into a syscall storm.
///
/// ONE handle also means one seek cursor, and a range read is `setPosition`
/// then `read` — two awaits with a suspension between them. The media stream
/// server answers Range requests CONCURRENTLY, so a second reader's
/// `setPosition` used to land in that gap: both callers got bytes, one of
/// them from the other's offset, with nothing in the answer to say so. On
/// this platform the pair is refused outright instead, which the old `catch`
/// turned into a null range — a player told the file had stopped being
/// readable while nothing was wrong with it (report9 X-03). Reads are
/// serialized here so the sharing stays an optimisation and not a hazard.
///
/// The size comes from the descriptor, and after it is open: taken by NAME
/// beforehand it describes whatever the name meant then, while the bytes come
/// from whatever it meant a moment later — the shape audit X-02 removed from
/// the send path.
Future<RangeSource?> fileRangeSource(String path) async {
  final RandomAccessFile open;
  try {
    open = await File(path).open(mode: FileMode.read);
  } catch (_) {
    return null; // missing, a directory, or not ours to read
  }
  final int size;
  try {
    size = await open.length();
  } catch (_) {
    try {
      await open.close();
    } catch (_) {}
    return null;
  }

  // Each read waits for the previous one to finish with the cursor. The chain
  // absorbs failures so one unreadable range does not wedge every later one.
  Future<void> gate = Future<void>.value();
  Future<Uint8List?> read(int offset, int length) {
    final result = gate.then((_) async {
      try {
        await open.setPosition(offset);
        return await open.read(length);
      } catch (_) {
        return null;
      }
    });
    gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  return RangeSource(
    size: size,
    read: read,
    close: () async {
      try {
        await open.close();
      } catch (_) {}
    },
  );
}

/// Open a stored blob for reading in ranges. Null if unknown or incomplete.
///
/// Nothing is decrypted beyond the range asked for, and nothing lands on disk —
/// the plaintext exists only in the chunk currently in flight, which is what
/// lets a multi-GB attachment play on a phone without a copy of it in RAM and
/// without breaking the no-plaintext-on-disk canon.
Future<RangeSource?> storageRangeSource(Storage storage, String fileId) async {
  final size = await storage.fileSize(fileId);
  if (size == null) return null;
  return RangeSource(
    size: size,
    read: (offset, length) => storage.readFileRange(fileId, offset, length),
  );
}
