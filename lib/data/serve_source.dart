import 'dart:io';
import 'dart:typed_data';

/// A byte source the SENDER serves a large file from directly (the original file
/// on disk) — read + close closures over a [RandomAccessFile]. Reads are
/// SERIALIZED through an internal gate: the serve loop issues many reads and a
/// single-cursor RandomAccessFile throws "An async operation is currently
/// pending" under concurrent setPosition+read. The structural record matches
/// MessagingService's internal serve-source type, so it plugs straight in.
typedef VeilServeSource = ({
  Future<Uint8List> Function(int offset, int length) read,
  Future<void> Function() close,
});

/// Open [path] as a serialized serve source, or null if it can't be opened (the
/// file was moved/deleted, or a mobile cache/SAF path expired) — in which case
/// the offer can't be re-served and the sender must re-send.
Future<VeilServeSource?> veilSourceOpener(String path) async {
  final RandomAccessFile raf;
  try {
    raf = await File(path).open();
  } catch (_) {
    return null;
  }
  Future<void> gate = Future<void>.value();
  Future<Uint8List> read(int offset, int length) {
    final r = gate.then((_) => _readFully(raf, offset, length));
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  return (read: read, close: raf.close);
}

/// A plaintext WRITE sink over a destination file — offset writes + close,
/// plus an optional [read] for RESUME verification (read a piece back and
/// hash-check it so a restart skips already-written pieces). [read] is null on
/// a fresh (truncating) open — there is nothing prior to trust.
typedef VeilPlainFileSink = ({
  Future<void> Function(int offset, Uint8List bytes) write,
  Future<void> Function() close,
  Future<Uint8List?> Function(int offset, int length)? read,
});

/// (Re)open [path] as a write sink for a plain-file download.
///
/// [resume]=false (default): TRUNCATE any prior content and start clean — a
/// fresh user-initiated download. No [read] (nothing to verify).
///
/// [resume]=true: do NOT truncate — keep the bytes a previous run wrote so the
/// swarm can hash-verify each piece off disk and skip the ones already present
/// (byte-level resume across a restart). Exposes [read] backed by a second
/// read-only handle (Dart's write handle can't also read). Best-effort: a
/// missing file just yields an empty one and every piece re-pulls.
///
/// Null when the destination can't be opened — e.g. a sandboxed macOS release
/// after a restart, where the NSSavePanel grant for the picked path is gone.
/// Writes are serialized through a gate for the same single-cursor reason as
/// [veilSourceOpener].
Future<VeilPlainFileSink?> veilPlainFileSinkOpener(
  String path, {
  bool resume = false,
}) async {
  final RandomAccessFile raf;
  RandomAccessFile? readRaf;
  try {
    await File(path).parent.create(recursive: true);
    // append = write + create + NO truncate (preserves prior bytes); write =
    // truncate. Reads need a separate handle — a write handle is write-only.
    raf = await File(path).open(mode: resume ? FileMode.append : FileMode.write);
    if (resume) {
      try {
        readRaf = await File(path).open(mode: FileMode.read);
      } catch (_) {
        readRaf = null; // no reader → resume simply re-pulls every piece
      }
    }
  } catch (_) {
    return null;
  }
  Future<void> gate = Future<void>.value();
  var closed = false;
  Future<void> write(int offset, Uint8List bytes) {
    final r = gate.then((_) async {
      if (closed) return;
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
    });
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<Uint8List?> Function(int offset, int length)? readFn;
  if (readRaf != null) {
    final rr = readRaf;
    readFn = (int offset, int length) async {
      // Serialize reads on the write gate too, so a concurrent write's
      // setPosition can't interleave with a read's (shared file, and the read
      // handle is independent — the gate is the single cursor of record).
      Uint8List? out;
      final r = gate.then((_) async {
        if (closed) return;
        try {
          out = await _readFully(rr, offset, length);
        } catch (_) {
          out = null;
        }
      });
      gate = r.then((_) {}, onError: (_) {});
      await r;
      return out;
    };
  }

  Future<void> close() {
    final r = gate.then((_) async {
      if (closed) return;
      closed = true;
      await raf.close();
      if (readRaf != null) {
        try {
          await readRaf.close();
        } catch (_) {}
      }
    });
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  return (write: write, close: close, read: readFn);
}

/// Read EXACTLY [length] bytes at [offset], looping until satisfied or EOF
/// ([RandomAccessFile.read] may return fewer than asked on some platforms).
Future<Uint8List> _readFully(
    RandomAccessFile raf, int offset, int length) async {
  await raf.setPosition(offset);
  final out = BytesBuilder(copy: false);
  var remaining = length;
  while (remaining > 0) {
    final chunk = await raf.read(remaining);
    if (chunk.isEmpty) break; // EOF (source shorter than declared)
    out.add(chunk);
    remaining -= chunk.length;
  }
  return out.toBytes();
}
