import 'dart:io';

/// Copy [size] bytes into [file], and leave nothing behind if it does not
/// finish.
///
/// One copy of a loop that existed three times: the chat save, the chat
/// download and the cloud export all stream a large item out of the encrypted
/// volume in chunks, and each of them got the ending slightly differently
/// wrong. What they share is the thing that matters — a file OUTSIDE the
/// volume, written under a name that says it is a whole document.
///
/// So the guarantee is stated once: either the file holds all [size] bytes, or
/// it does not exist. A short read and a thrown exception end the same way,
/// because a plausible-looking partial is worse than no file at all — somebody
/// opens it, sees the first half of their document, and has no way to know the
/// rest was never written.
///
/// Written STRAIGHT to [file], never to a `<name>.part` sibling. On a
/// sandboxed macOS build the save panel grants a read-write exception for the
/// selected path only, so opening a sibling fails with "Operation not
/// permitted" and every export silently failed — found on a release build
/// after it worked in every debug one.
///
/// [openSink] exists so a test can make `close` fail. That branch matters —
/// `close` is what flushes, so it is a plausible place for the write to go
/// wrong, and without catching it the exception leaves the `finally` and the
/// cleanup below never runs — and it cannot be reached otherwise: on POSIX,
/// taking the file or its directory away underneath an open sink does not
/// disturb the write at all.
Future<bool> writeStreamedFile({
  required File file,
  required int size,
  required Future<List<int>?> Function(int offset, int want) read,
  int chunk = 4 * 1024 * 1024,
  IOSink Function(File file)? openSink,
}) async {
  var written = 0;
  var complete = false;
  final sink = (openSink ?? (f) => f.openWrite())(file);
  try {
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
    try {
      await sink.close();
    } catch (_) {
      complete = false;
    }
    if (!complete) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
  return complete;
}
