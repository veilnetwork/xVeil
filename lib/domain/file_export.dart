import 'dart:io';
import 'dart:math';

import '../core/filesystem_errors.dart';

// Temporary names are distinct even when several exports share a destination.
String _suffix() {
  final random = Random.secure();
  return List.generate(
    4,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Future<bool> writeStreamedFile({
  required File file,
  required int size,
  required Future<List<int>?> Function(int offset, int want) read,
  int chunk = 4 * 1024 * 1024,
  IOSink Function(File file)? openSink,
}) async {
  final open = openSink ?? (f) => f.openWrite();
  final sibling = File('${file.path}.xveil-part-${_suffix()}');
  final sink = open(sibling);
  var written = 0;
  var complete = false;
  try {
    await sink.flush();
    while (written < size) {
      final want = (size - written) < chunk ? size - written : chunk;
      final part = await read(written, want);
      // Null or empty means the source stopped early. Not an error to throw —
      // the caller is told `false` and the file is gone either way.
      if (part == null || part.isEmpty) break;
      sink.add(part);
      written += part.length;
    }
    complete = written >= size;
  } finally {
    // `close` first: it flushes, and a delete before it can race the flush.
    FileSystemException? deniedClose;
    try {
      await sink.close();
    } on FileSystemException catch (error) {
      if (fileSystemAccessDenied(error)) deniedClose = error;
      complete = false;
    }
    if (!complete) {
      // Only what THIS call opened. In the sibling case that leaves the
      // person's existing document exactly as it was.
      try {
        await sibling.delete();
      } catch (_) {}
    }
    if (deniedClose != null) throw deniedClose;
  }
  if (complete) {
    // The target appears whole or not at all: a rename over an existing file
    // replaces it in one step, so there is no moment where it is half a
    // document.
    try {
      await sibling.rename(file.path);
    } on FileSystemException catch (error) {
      try {
        await sibling.delete();
      } on FileSystemException {
        /* Preserve the publication error. */
      }
      if (fileSystemAccessDenied(error)) rethrow;
      return false;
    }
  }
  return complete;
}
