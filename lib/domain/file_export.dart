import 'dart:io';
import 'dart:math';

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
/// Through a sibling temp WHERE ONE CAN BE OPENED, and straight to [file]
/// where one cannot.
///
/// Both halves are the result of something going wrong. On a sandboxed macOS
/// build the save panel grants a read-write exception for the selected path
/// ONLY, so opening `<name>.part` fails with "Operation not permitted" and
/// every export silently failed — found on a release build after it worked in
/// every debug one. Writing direct fixed that and cost something else:
/// `openWrite` truncates on open, so choosing an existing document and having
/// the copy fail destroyed the document (report16 XV-03).
///
/// So the sibling is tried first and the direct write is the fallback, which
/// is exactly the case the sandbox leaves. In the fallback an existing target
/// cannot be protected — it is gone at open — and the person did confirm
/// replacing it in the panel that granted the path.
///
/// The sibling's name is RANDOM, and the open is awaited.
///
/// It used to be `<target>.xveil-part`, a name anybody could compute:
///
///  * two exports of the same target raced each other — the first rename moved
///    the file out from under the second, which went on writing into an
///    unlinked inode and then renamed nothing over the target;
///  * `openWrite` follows a symlink and truncates what it finds, so a link
///    placed at that predictable name pointed the export at any file this
///    process can write, and the export destroyed it before writing a byte.
///
/// A random suffix answers both: nobody can pre-place a link at a name that
/// does not exist yet, and two exports of one target no longer share a path.
///
/// And the open is awaited rather than assumed. `openWrite` returns an `IOSink`
/// without opening anything; the failure arrives later, through the sink, so
/// the `try` around it caught nothing and the sandbox fallback this function
/// exists for never ran (report17 XV17-M1).
///
/// [openSink] exists so a test can make `close` fail. That branch matters —
/// `close` is what flushes, so it is a plausible place for the write to go
/// wrong, and without catching it the exception leaves the `finally` and the
/// cleanup below never runs — and it cannot be reached otherwise: on POSIX,
/// taking the file or its directory away underneath an open sink does not
/// disturb the write at all.
/// Eight hex characters of randomness for the sibling's name.
///
/// Not secret — it only has to be unpredictable enough that nobody can place a
/// symlink there in advance, and distinct enough that two exports of the same
/// target do not collide.
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
  // The sibling, when the filesystem allows one. Named beside the target so it
  // lands on the same device and the rename below is atomic rather than a
  // copy — and with a random suffix, so the name cannot be computed by anybody
  // who might want to be there first.
  final sibling = File('${file.path}.xveil-part-${_suffix()}');
  IOSink sink;
  File writing;
  var replacing = false;
  try {
    sink = open(sibling);
    // AWAITED. `openWrite` hands back a sink without having opened anything:
    // the real refusal — the sandbox that granted one path only — arrives
    // through the sink afterwards, so a `try` around the call above caught
    // nothing and the fallback below never ran. `flush` on a fresh sink is
    // what makes the open happen now, where it can be caught.
    await sink.flush();
    writing = sibling;
    replacing = true;
  } on FileSystemException {
    // A sandbox that granted one path, or a directory that is not ours to add
    // to. Direct is all that is left.
    sink = open(file);
    writing = file;
  }
  var written = 0;
  var complete = false;
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
      // Only what THIS call opened. In the sibling case that leaves the
      // person's existing document exactly as it was.
      try {
        await writing.delete();
      } catch (_) {}
    }
  }
  if (complete && replacing) {
    // The target appears whole or not at all: a rename over an existing file
    // replaces it in one step, so there is no moment where it is half a
    // document.
    try {
      await sibling.rename(file.path);
    } catch (_) {
      try {
        await sibling.delete();
      } catch (_) {}
      return false;
    }
  }
  return complete;
}
