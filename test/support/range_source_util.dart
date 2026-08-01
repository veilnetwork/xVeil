// Byte-oriented shims for the folder-sync range ports.
//
// Production moves files in ranges so a sync pass never holds one whole
// (P0-5). Tests still want to say "write these bytes" / "read it all back",
// and doing that through the real port keeps them honest: they exercise the
// same chunk walk production does instead of a byte-array method kept alive
// only for them.

import 'dart:typed_data';

import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_engine.dart';

/// A [RangeSource] over bytes already in hand.
RangeSource bytesSource(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  return RangeSource(
    size: data.length,
    read: (offset, length) async {
      if (offset >= data.length) return Uint8List(0);
      final end = offset + length;
      return Uint8List.sublistView(
        data,
        offset,
        end > data.length ? data.length : end,
      );
    },
  );
}

/// Drain a source fully. Null if it went unreadable partway.
Future<Uint8List?> drainSource(RangeSource source) async {
  final out = BytesBuilder(copy: false);
  while (out.length < source.size) {
    final chunk = await source.read(out.length, source.size - out.length);
    if (chunk == null || chunk.isEmpty) return null;
    out.add(chunk);
  }
  return out.toBytes();
}

/// `cloud.upload` spelled as bytes.
Future<RemoteFile> uploadBytes(
  FolderSyncCloud cloud, {
  required String path,
  required String? folderId,
  required String? existingItemId,
  required List<int> bytes,
}) {
  final source = bytesSource(bytes);
  return cloud.upload(
    path: path,
    folderId: folderId,
    existingItemId: existingItemId,
    size: source.size,
    readRange: (offset, length) async => (await source.read(offset, length))!,
  );
}

/// `cloud.openDownload` drained. Null when the content is not here yet.
Future<Uint8List?> downloadBytes(FolderSyncCloud cloud, String itemId) async {
  final source = await cloud.openDownload(itemId);
  if (source == null) return null;
  try {
    return await drainSource(source);
  } finally {
    await source.dispose();
  }
}

/// `disk.writeFrom` spelled as bytes.
Future<void> writeBytes(
  FolderSyncDisk disk,
  String root,
  String path,
  List<int> bytes,
) => disk.writeFrom(root, path, bytesSource(bytes));

/// `disk.openRead` drained, with the handle released.
Future<Uint8List?> readAllFrom(
  FolderSyncDisk disk,
  String root,
  String path,
) async {
  final source = await disk.openRead(root, path);
  if (source == null) return null;
  try {
    return await drainSource(source);
  } finally {
    await source.dispose();
  }
}
