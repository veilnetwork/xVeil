import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/log.dart';
import 'node/veil_library.dart' show verifiedVeilLibrary;
import 'serve_source.dart';

/// Open a file BENEATH a granted root, without trusting the name it was
/// reached by.
///
/// ## Why this is not `File(path).open()`
///
/// The API checks that a path lies inside a root a person granted, and then
/// something opens it. Between the check and the open the name is still only a
/// name: `dart:io` has no `openat`, no `O_NOFOLLOW` and no `fstat`, so nothing
/// here can bind the name that was checked to the object that was opened. The
/// nearest thing Dart can do — stamp `(device, inode)` either side of the open
/// and refuse on a change — is what [veilOpenPinnedSource] does, and an
/// adversary who swaps the name twice, A → B → A between two adjacent `lstat`
/// calls, defeats it with matching stamps.
///
/// `veil_fs_open_beneath` walks the path a component at a time from a
/// descriptor on the root, refusing a symlink rather than following it and
/// refusing `..` rather than resolving it. What comes back reads from that
/// descriptor, so a rename after the fact reaches nothing.
///
/// ## Which hosts have it
///
/// All of them that this app ships to. POSIX walks with `openat(O_NOFOLLOW)`;
/// Windows walks with `NtCreateFile` against a RootDirectory handle and
/// `OBJ_DONT_REPARSE`, which is the same guarantee spelled in the NT layer — a
/// junction or a symlink on the way is refused rather than followed. Verified
/// on a Windows ARM machine, junction included.
///
/// `supported: false` is left for a host that is neither, and for a build whose
/// library predates these symbols. It is NOT the same as a refusal, and the
/// caller must not treat it as one: see [VeilBeneathOpen].
typedef _OpenBeneathNative =
    Pointer<Void> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _OpenBeneathDart =
    Pointer<Void> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );

typedef _ReadNative =
    IntPtr Function(
      Pointer<Void>,
      Uint64,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _ReadDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );

typedef _CreateNative =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _CreateDart =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _WriteNative =
    IntPtr Function(
      Pointer<Void>,
      Uint64,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _WriteDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );

typedef _SyncNative = Bool Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _SyncDart = bool Function(Pointer<Void>, Pointer<Pointer<Utf8>>);

typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);

/// Whether the strong open is available in this process at all.
///
/// Answered by looking the symbol up, not by guessing from the platform: a
/// build that ships an older library has the same problem as a platform that
/// cannot do it, and both want the fallback.
bool veilOpenBeneathAvailable({DynamicLibrary? lib}) {
  try {
    final dl = lib ?? verifiedVeilLibrary();
    dl.lookup<NativeFunction<_OpenBeneathNative>>('veil_fs_open_beneath');
    return true;
  } catch (_) {
    return false;
  }
}

/// What [veilOpenBeneath] answers.
///
/// `supported` is the whole reason this is a record rather than a nullable
/// source. A REFUSAL and an INABILITY look the same from the outside and must
/// not be treated the same: falling back to a weaker open on a refusal serves
/// the very file the walk just rejected, which is how the first version of the
/// wiring here handed a caller a symlink out of the granted root. A test
/// caught it immediately; nothing else would have.
typedef VeilBeneathOpen = ({VeilOpenedSource? source, bool supported});

/// Open [relative] beneath [root] through the native walk.
Future<VeilBeneathOpen> veilOpenBeneath(
  String root,
  String relative, {
  DynamicLibrary? lib,
}) async {
  const unsupported = (source: null, supported: false);
  final DynamicLibrary dl;
  try {
    dl = lib ?? verifiedVeilLibrary();
  } catch (_) {
    return unsupported;
  }
  final _OpenBeneathDart open;
  final _ReadDart read;
  final _CloseDart close;
  final _FreeStrDart freeStr;
  try {
    open = dl.lookupFunction<_OpenBeneathNative, _OpenBeneathDart>(
      'veil_fs_open_beneath',
    );
    read = dl.lookupFunction<_ReadNative, _ReadDart>('veil_fs_read');
    close = dl.lookupFunction<_CloseNative, _CloseDart>('veil_fs_close');
    freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
  } catch (_) {
    // A library without these symbols is a host that cannot do the walk, not
    // one that refused this path.
    return unsupported;
  }

  final rootC = root.toNativeUtf8();
  final relC = relative.toNativeUtf8();
  final lenOut = calloc<Uint64>();
  final errOut = calloc<Pointer<Utf8>>();
  Pointer<Void> handle;
  int size;
  try {
    handle = open(rootC, relC, lenOut, errOut);
    if (handle == nullptr) {
      var supported = true;
      final err = errOut.value;
      if (err != nullptr) {
        final msg = err.toDartString();
        // The one refusal that is really an inability: a host with no `openat`
        // says so, and the caller may then use its own weaker check. Every
        // other message is a refusal ABOUT THIS PATH and is final.
        supported = !msg.contains('POSIX-only');
        // The reason is diagnostic only. It names a component, which is a path
        // fragment, so it goes to the log the build already gates rather than
        // to a caller that might surface it.
        devLog(() => 'xVeil[fs]: refused $relative beneath $root: $msg');
        freeStr(err);
      }
      return (source: null, supported: supported);
    }
    size = lenOut.value;
  } finally {
    calloc.free(rootC);
    calloc.free(relC);
    calloc.free(lenOut);
    calloc.free(errOut);
  }

  var closed = false;
  Future<void> gate = Future<void>.value();

  Future<Uint8List> readRange(int offset, int length) {
    final r = gate.then((_) async {
      if (closed) throw StateError('source closed');
      final buf = calloc<Uint8>(length);
      final err = calloc<Pointer<Utf8>>();
      try {
        final n = read(handle, offset, buf, length, err);
        if (n < 0) {
          final e = err.value;
          final msg = e == nullptr ? 'read failed' : e.toDartString();
          if (e != nullptr) freeStr(e);
          throw FileSystemException(msg, '<descriptor>');
        }
        return Uint8List.fromList(buf.asTypedList(n));
      } finally {
        calloc.free(buf);
        calloc.free(err);
      }
    });
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<void> closeIt() async {
    if (closed) return;
    closed = true;
    // After whatever is in flight, so a read never touches a freed handle.
    await gate.catchError((_) {});
    close(handle);
  }

  return (
    source: (size: size, read: readRange, close: closeIt),
    supported: true,
  );
}

/// A file being written through a descriptor: the same three calls a
/// `RandomAccessFile` sink offers the download loop, and nothing else.
typedef VeilCreatedSink = ({
  Future<void> Function(List<int> chunk) writeFrom,
  Future<void> Function() flush,
  Future<void> Function() close,
});

/// What [veilCreateBeneath] answers. `supported` for the same reason
/// [VeilBeneathOpen] carries it: a refusal is not an inability.
typedef VeilBeneathCreate = ({VeilCreatedSink? sink, bool supported});

/// Create [relative] beneath [root] for writing, following no symlink and
/// refusing a name that already exists.
///
/// The write half of the same gap. Folder sync checks a mirrored path is
/// inside its root and then opens it, and `File.open` follows a link — so a
/// component turned into a symlink between the check and the open sent the
/// download outside the mirrored tree, truncating whatever it aimed at.
Future<VeilBeneathCreate> veilCreateBeneath(
  String root,
  String relative, {
  DynamicLibrary? lib,
}) async {
  const unsupported = (sink: null, supported: false);
  final DynamicLibrary dl;
  try {
    dl = lib ?? verifiedVeilLibrary();
  } catch (_) {
    return unsupported;
  }
  final _CreateDart create;
  final _WriteDart write;
  final _SyncDart sync;
  final _CloseDart close;
  final _FreeStrDart freeStr;
  try {
    create = dl.lookupFunction<_CreateNative, _CreateDart>(
      'veil_fs_create_beneath',
    );
    write = dl.lookupFunction<_WriteNative, _WriteDart>('veil_fs_write');
    sync = dl.lookupFunction<_SyncNative, _SyncDart>('veil_fs_sync');
    close = dl.lookupFunction<_CloseNative, _CloseDart>('veil_fs_close');
    freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
  } catch (_) {
    return unsupported;
  }

  final rootC = root.toNativeUtf8();
  final relC = relative.toNativeUtf8();
  final errOut = calloc<Pointer<Utf8>>();
  Pointer<Void> handle;
  try {
    handle = create(rootC, relC, errOut);
    if (handle == nullptr) {
      var supported = true;
      final err = errOut.value;
      if (err != nullptr) {
        final msg = err.toDartString();
        supported = !msg.contains('POSIX-only');
        devLog(() => 'xVeil[fs]: refused creating $relative beneath $root: $msg');
        freeStr(err);
      }
      return (sink: null, supported: supported);
    }
  } finally {
    calloc.free(rootC);
    calloc.free(relC);
    calloc.free(errOut);
  }

  var offset = 0;
  var closed = false;

  Future<void> writeChunk(List<int> chunk) async {
    if (closed) throw StateError('sink closed');
    if (chunk.isEmpty) return;
    final buf = calloc<Uint8>(chunk.length);
    final err = calloc<Pointer<Utf8>>();
    try {
      buf.asTypedList(chunk.length).setAll(0, chunk);
      var done = 0;
      while (done < chunk.length) {
        final n = write(
          handle,
          offset + done,
          buf + done,
          chunk.length - done,
          err,
        );
        if (n <= 0) {
          final e = err.value;
          final msg = e == nullptr ? 'write failed' : e.toDartString();
          if (e != nullptr) freeStr(e);
          throw FileSystemException(msg, '<descriptor>');
        }
        done += n;
      }
      offset += chunk.length;
    } finally {
      calloc.free(buf);
      calloc.free(err);
    }
  }

  /// Put what was written on the DISK.
  ///
  /// This used to be empty, with a comment saying every write had already
  /// reached the kernel — true, and not what a flush is for. The caller writes
  /// a scratch file, flushes, and renames it over the real name; without a
  /// barrier in between, a power loss can leave the new NAME pointing at
  /// contents that were never written, which is exactly what the rename dance
  /// exists to prevent. The Dart sink this replaced called
  /// `RandomAccessFile.flush`, which does sync — so the barrier was not
  /// missing by design, it was dropped in the move to descriptors
  /// (report24 XV24-04).
  Future<void> flushIt() async {
    if (closed) return;
    final err = calloc<Pointer<Utf8>>();
    try {
      if (sync(handle, err)) return;
      final message = err.value == nullptr
          ? 'sync refused'
          : err.value.toDartString();
      if (err.value != nullptr) freeStr(err.value);
      // Raised, not swallowed: the caller renames after this, and a rename
      // over unwritten contents is the failure being prevented.
      throw FileSystemException('veil_fs_sync failed', message);
    } finally {
      calloc.free(err);
    }
  }

  Future<void> closeIt() async {
    if (closed) return;
    closed = true;
    close(handle);
  }

  return (
    sink: (writeFrom: writeChunk, flush: flushIt, close: closeIt),
    supported: true,
  );
}
