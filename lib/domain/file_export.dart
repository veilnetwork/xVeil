import 'dart:io';
import 'dart:math';

import '../core/filesystem_errors.dart';
import '../data/storage/managed_fs_platform.dart';

// Temporary names are distinct even when several exports share a destination.
String _suffix() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Future<bool> writeStreamedFile({
  required File file,
  required int size,
  required Future<List<int>?> Function(int offset, int want) read,
  int chunk = 4 * 1024 * 1024,
  IOSink Function(File file)? openSink,
  bool replaceExisting = true,
  File Function()? onDestinationOccupied,
}) async {
  const fs = ManagedFsPlatform();
  final open = openSink ?? (f) => f.openWrite();
  final sibling = File(
    '${file.parent.path}${Platform.pathSeparator}.xveil-part-${_suffix()}',
  );
  fs.reserveNewFile(sibling.path);
  var published = false;
  try {
    fs.restrictNewFile(sibling.path);
    final sink = open(sibling);
    var written = 0;
    var complete = false;
    try {
      await sink.flush();
      while (written < size) {
        final want = min(size - written, chunk);
        final part = await read(written, want);
        if (part == null || part.isEmpty) break;
        sink.add(part);
        written += part.length;
      }
      complete = written >= size;
    } finally {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        if (fileSystemAccessDenied(error)) rethrow;
        complete = false;
      }
    }
    if (!complete) return false;
    try {
      if (replaceExisting) {
        await sibling.rename(file.path);
        return published = true;
      }
      var destination = file;
      for (var attempt = 0; attempt < 16; attempt++) {
        if (fs.publishFileNoReplace(sibling.path, destination.path)) {
          return published = true;
        }
        if (onDestinationOccupied == null) return false;
        destination = onDestinationOccupied();
      }
    } on FileSystemException catch (error) {
      if (fileSystemAccessDenied(error)) rethrow;
    }
    return false;
  } finally {
    if (!published) {
      try {
        await sibling.delete();
      } on FileSystemException {
        // Preserve the original publication error.
      }
    }
  }
}
