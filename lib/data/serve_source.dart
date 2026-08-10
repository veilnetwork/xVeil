import 'dart:io';
import 'dart:typed_data';

import '../core/posix_file_facts.dart';

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

/// What a serve source's file looked like when it was last checked.
///
/// `(deviceId, inode)` is the OBJECT'S identity; `(size, mtimeMs)` is what it
/// contained. Both halves are needed and neither replaces the other — see
/// [veilSourceStamp].
typedef VeilSourceStamp = ({int deviceId, int inode, int size, int mtimeMs});

/// Identity + size + last-modified of [path], or null when it cannot be read.
///
/// A cache key for "is this still the file we verified". Null is not a failure —
/// an in-memory or otherwise non-filesystem source name simply has nothing to
/// stamp, and a caller must then re-check rather than trust a key that can never
/// change.
///
/// ## Why it is not size and mtime
///
/// It used to be exactly those two, with a comment admitting that both are
/// writable by anyone who can write the file. That is not a caveat, it is the
/// whole attack: `truncate` to the original length and `touch -r` against the
/// original file reproduces the stamp exactly, in two commands, with no timing
/// involved. And the stamp is what decides whether a cached "this content was
/// verified" verdict still applies — so forging it means a swapped file
/// inherits somebody else's verdict and is served without ever being hashed.
///
/// `(st_dev, st_ino)` is not writable. There is no call that says "give this
/// file that inode": an attacker who replaces the file gets whatever the
/// filesystem hands out, and a rename-over-the-name always yields a different
/// one. That comes from [posixLstat], which is already in the tree for exactly
/// this kind of question (audit C-02).
///
/// Both halves are kept, because each covers what the other misses:
///
///  * `lstat` does not follow the last symlink, so when [path] IS a link the
///    identity is the LINK's. Repointing a link means replacing it, which
///    changes that inode — but swapping the file the link points AT does not,
///    and size/mtime are what notice that;
///  * conversely a rewrite in place keeps the inode and moves size or mtime.
///
/// On Windows, and on any POSIX ABI whose `struct stat` layout [posixLstat]
/// does not know, the identity fields are 0 and the stamp degrades to exactly
/// what it was before — no weaker, and no pretence of being stronger.
Future<VeilSourceStamp?> veilSourceStamp(String path) async {
  try {
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    final facts = posixLstat(path);
    return (
      deviceId: facts?.deviceId ?? 0,
      inode: facts?.inode ?? 0,
      size: stat.size,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
    );
  } catch (_) {
    return null;
  }
}

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

/// A serve source that also carries the size it was opened with.
typedef VeilOpenedSource = ({
  int size,
  Future<Uint8List> Function(int offset, int length) read,
  Future<void> Function() close,
});

/// Open [path] ONCE for a send: the size and every byte come from the SAME
/// descriptor.
///
/// The send used to look the name up three times — `exists()`, then `length()`,
/// then `open()`. Between the second and the third, the name could be pointed
/// at another file, and the offer went out describing one file's SIZE while
/// hashing and serving another file's BYTES. That inconsistency is what made
/// the manifest look coherent to an honest receiver, which would then accept
/// the substituted bytes (audit X-02).
///
/// One `open` removes it: `length()` on the handle reads the inode this
/// descriptor holds, not whatever the name means by then, and every later read
/// goes through the same handle. A rename or a relink under the path no longer
/// changes what is being sent.
///
/// It does NOT close the remaining window, and there is no way from Dart to
/// close it: between the caller's authorization check and this open the name is
/// still just a name — no `openat`, no `O_NOFOLLOW`. Detection, by comparing
/// [veilSourceStamp] across the read, is what is on offer there.
///
/// Null when the file cannot be opened (moved, deleted, an expired mobile
/// cache/SAF path) — the caller reports that as a missing source.
Future<VeilOpenedSource?> veilOpenSourceForSend(String path) async {
  final RandomAccessFile raf;
  try {
    raf = await File(path).open();
  } catch (_) {
    return null;
  }
  final int size;
  try {
    size = await raf.length();
  } catch (_) {
    try {
      await raf.close();
    } catch (_) {}
    return null;
  }
  Future<void> gate = Future<void>.value();
  Future<Uint8List> read(int offset, int length) {
    final r = gate.then((_) => _readFully(raf, offset, length));
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  return (size: size, read: read, close: raf.close);
}

/// What [veilOpenPinnedSource] hands back: the open source, or the reason it
/// refused, plus the identity the name had when it was opened.
typedef VeilPinnedOpen = ({
  VeilOpenedSource? source,
  String? refusal,
  VeilSourceStamp? stamp,
});

/// Open [path] for a send and refuse if the NAME changed identity across the
/// open (audit X-01).
///
/// ## What was wrong with stamping after the open
///
/// Every send site took its first stamp AFTER opening and compared it only
/// once the send had finished. Both halves of that are the wrong way round:
///
///  * a swap that happened between the caller's authorization check and the
///    open is already reflected in that first stamp, so the comparison is of
///    the attacker's file against itself and can never fire;
///  * by the time the second stamp is taken the offer has been published, so
///    even a positive answer arrives after the peer has the content.
///
/// Bracketing the OPEN instead reverses both. If the name resolves to the same
/// `(deviceId, inode)` immediately before and immediately after the open, then
/// — barring a swap that also swapped back inside that window — the descriptor
/// this returns is the object the caller authorized, and the refusal happens
/// before anything is offered.
///
/// ## What it still does not prove
///
/// The window is narrowed, not closed. An adversary who can win the race
/// twice (A → B → A) across two adjacent `lstat` calls still gets the
/// substituted descriptor with matching stamps, and nothing in `dart:io` can
/// bind a name to an inode — no `openat`, no `O_NOFOLLOW`, no `fstat` on an
/// open handle. Closing it needs descriptor-relative access from native code,
/// which is the same remainder audit X-02 left behind.
///
/// On Windows and on any POSIX ABI [veilSourceStamp] cannot read identity
/// fields for, the stamp degrades to size + mtime and so does this check: it
/// then catches an ordinary rewrite and not a careful swap. That is weaker,
/// not absent, and it is the same degradation the stamp already documents.
///
/// [opener] exists for tests, which need to act between the two stamps.
Future<VeilPinnedOpen> veilOpenPinnedSource(
  String path, {
  Future<VeilOpenedSource?> Function(String path)? opener,
}) async {
  final before = await veilSourceStamp(path);
  final source = await (opener ?? veilOpenSourceForSend)(path);
  if (source == null) {
    return (source: null, refusal: 'source not found', stamp: null);
  }
  final after = await veilSourceStamp(path);
  // Null on either side means there was nothing to compare — a source name
  // that is not a filesystem path, or a stat that failed. Refusing on that
  // would break every non-file source; the caller is told by getting a null
  // stamp back that it holds no evidence.
  if (before != null && after != null && before != after) {
    try {
      await source.close();
    } catch (_) {}
    return (
      source: null,
      refusal:
          'the file at this path was replaced while it was being opened; '
          'nothing was sent',
      stamp: null,
    );
  }
  return (source: source, refusal: null, stamp: before);
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
