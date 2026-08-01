// Concrete [RangeSource]s for the two places large blobs actually live: a file
// on disk and the encrypted container.

import 'dart:io';

import '../domain/range_source.dart';
import 'storage/storage.dart';

/// Open a local file for reading in ranges. Null if it is not there.
///
/// The caller must [RangeSource.dispose] it — the handle stays open for the
/// life of the source, which is the point: reopening per hop would turn a
/// seek-heavy player into a syscall storm.
Future<RangeSource?> fileRangeSource(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  RandomAccessFile? handle;
  try {
    final size = await file.length();
    handle = await file.open(mode: FileMode.read);
    final open = handle;
    return RangeSource(
      size: size,
      read: (offset, length) async {
        try {
          await open.setPosition(offset);
          return await open.read(length);
        } catch (_) {
          return null;
        }
      },
      close: () async {
        try {
          await open.close();
        } catch (_) {}
      },
    );
  } catch (_) {
    try {
      await handle?.close();
    } catch (_) {}
    return null;
  }
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
