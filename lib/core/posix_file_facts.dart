/// `lstat(2)` straight out of libc, because a security decision must never be
/// asked of a program that PATH picked (audit C-01).
///
/// The VPN launch guard used to read owner and mode by running `stat`. That is
/// a bare command name: anything the user can drop into a PATH component
/// answers it, and the answer decided whether xVeil would hand itself to
/// `pkexec`. A fake `stat` claiming "root-owned, 0755" was enough to turn
/// same-user code execution into root.
///
/// libc is already in the process and cannot be substituted through the
/// environment, so the facts come from there instead. Two extra guarantees
/// this buys over the subprocess:
///
///   * `lstat` does NOT follow the last symlink, so the guard can tell "the
///     link" from "what it points at" and check each in its own right.
///   * the inode and device come back too, which is what lets a caller prove
///     that the directory it is about to delete is still the one it created
///     (audit C-02).
///
/// Fail-closed: anything unexpected — a libc without the symbol, an ABI whose
/// `struct stat` layout is not in the table below, a mismatch against Dart's
/// own answer — returns null. A caller that cannot read the facts must refuse,
/// never assume.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What `lstat(2)` said about one path.
class PosixFileFacts {
  const PosixFileFacts({
    required this.deviceId,
    required this.inode,
    required this.uid,
    required this.gid,
    required this.mode,
  });

  /// Device the entry lives on. With [inode] it is the identity of the object:
  /// a path that now resolves to a different (device, inode) pair is a
  /// different object, whatever its name says.
  final int deviceId;
  final int inode;
  final int uid;
  final int gid;

  /// The full `st_mode`, file-type bits included.
  final int mode;

  static const _typeMask = 0xF000;

  bool get isSymlink => mode & _typeMask == 0xA000;
  bool get isDirectory => mode & _typeMask == 0x4000;
  bool get isRegularFile => mode & _typeMask == 0x8000;

  /// Permission bits only.
  int get permissions => mode & 0xFFF;

  /// Writable by group or by other — on POSIX one bit that means both "create
  /// entries here" and "delete what is here".
  bool get groupOrOtherWritable => mode & 0x12 != 0; // 0o020 | 0o002

  /// The sticky bit. On a DIRECTORY it takes the "delete what is here" half of
  /// [groupOrOtherWritable] back: only an entry's owner may rename or remove
  /// it. That is the whole reason a world-writable `/tmp` is usable at all, and
  /// a caller asking "can somebody else swap this directory out from under me"
  /// has to read it, or it will refuse every path under `/tmp` on Linux.
  bool get isSticky => mode & 0x200 != 0; // 0o1000

  bool sameObjectAs(PosixFileFacts other) =>
      deviceId == other.deviceId && inode == other.inode;

  @override
  String toString() =>
      'PosixFileFacts(dev=$deviceId ino=$inode uid=$uid gid=$gid '
      'mode=${mode.toRadixString(8)})';
}

/// Where `st_dev`/`st_ino`/`st_mode`/`st_uid`/`st_gid` sit in `struct stat`.
///
/// Guessing this wrong would produce confident nonsense rather than an error,
/// so every read is cross-checked against Dart's own `stat` before it is
/// believed — see [posixLstat].
class _StatLayout {
  const _StatLayout({
    required this.bufferBytes,
    required this.devOffset,
    required this.devIs64,
    required this.inoOffset,
    required this.modeOffset,
    required this.modeIs16,
    required this.uidOffset,
    required this.gidOffset,
  });

  final int bufferBytes;
  final int devOffset;
  final bool devIs64;
  final int inoOffset;
  final int modeOffset;
  final bool modeIs16;
  final int uidOffset;
  final int gidOffset;
}

/// Darwin (`__DARWIN_64_BIT_INO_T`, the only variant 64-bit builds get).
const _darwin = _StatLayout(
  bufferBytes: 256,
  devOffset: 0,
  devIs64: false,
  inoOffset: 8,
  modeOffset: 4,
  modeIs16: true,
  uidOffset: 16,
  gidOffset: 20,
);

/// glibc/bionic on x86_64, where `st_nlink` sits before `st_mode`.
const _linuxX64 = _StatLayout(
  bufferBytes: 256,
  devOffset: 0,
  devIs64: true,
  inoOffset: 8,
  modeOffset: 24,
  modeIs16: false,
  uidOffset: 28,
  gidOffset: 32,
);

/// The kernel's generic 64-bit layout: aarch64, riscv64.
const _linuxGeneric64 = _StatLayout(
  bufferBytes: 256,
  devOffset: 0,
  devIs64: true,
  inoOffset: 8,
  modeOffset: 16,
  modeIs16: false,
  uidOffset: 24,
  gidOffset: 28,
);

/// 32-bit ARM `struct stat64`: the 64-bit inode is parked at the end.
const _linuxArm32 = _StatLayout(
  bufferBytes: 256,
  devOffset: 0,
  devIs64: true,
  inoOffset: 96,
  modeOffset: 16,
  modeIs16: false,
  uidOffset: 24,
  gidOffset: 28,
);

_StatLayout? _layoutForHost() => switch (Abi.current()) {
  Abi.macosArm64 || Abi.macosX64 || Abi.iosArm64 || Abi.iosX64 => _darwin,
  Abi.linuxX64 || Abi.androidX64 => _linuxX64,
  Abi.linuxArm64 ||
  Abi.androidArm64 ||
  Abi.linuxRiscv64 => _linuxGeneric64,
  Abi.androidArm || Abi.linuxArm => _linuxArm32,
  _ => null,
};

typedef _PathIntNative = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _PathIntDart = int Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _ChmodNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);
typedef _MkdirNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _MkdirDart = int Function(Pointer<Utf8>, int);

/// `open(2)` declared with TWO arguments on purpose. The C function is
/// variadic, and its third parameter is read only when `O_CREAT` is in the
/// flags — which nothing here passes. Declaring the extra argument would mean
/// promising a variadic call convention that AArch64 does not implement the way
/// a fixed signature describes.
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _FdIntNative = Int32 Function(Int32);
typedef _FdIntDart = int Function(int);
typedef _KillNative = Int32 Function(Int32, Int32);
typedef _KillDart = int Function(int, int);

/// `__error()` / `__errno_location()` — the function that hands back a pointer
/// to THIS thread's `errno`. There is no global symbol to read: on every
/// platform here `errno` is a macro over one of these.
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

class _Libc {
  _Libc(
    this.layout,
    this.lstat,
    this.chmod,
    this.mkdir,
    this.geteuid,
    this.open,
    this.fsync,
    this.close,
    this.kill,
    this.errnoLocation,
  );

  final _StatLayout layout;
  final _PathIntDart lstat;
  final _ChmodDart? chmod;
  final _MkdirDart? mkdir;
  final int Function()? geteuid;
  final _OpenDart? open;
  final _FdIntDart? fsync;
  final _FdIntDart? close;
  final _KillDart? kill;
  final _ErrnoLocationDart? errnoLocation;
}

_Libc? _libc;
bool _libcResolved = false;

_Libc? _resolveLibc() {
  if (_libcResolved) return _libc;
  _libcResolved = true;
  if (Platform.isWindows) return null;
  final layout = _layoutForHost();
  if (layout == null) return null;
  final process = DynamicLibrary.process();
  _PathIntDart? lstat;
  // `lstat$INODE64` is what 64-bit-inode Darwin exports on x86_64; arm64 and
  // Linux export the plain name.
  for (final name in const ['lstat\$INODE64', 'lstat']) {
    try {
      lstat = process
          .lookup<NativeFunction<_PathIntNative>>(name)
          .asFunction<_PathIntDart>();
      break;
    } on ArgumentError {
      continue;
    }
  }
  if (lstat == null) return null;

  _ChmodDart? chmod;
  try {
    chmod = process
        .lookup<NativeFunction<_ChmodNative>>('chmod')
        .asFunction<_ChmodDart>();
  } on ArgumentError {
    chmod = null;
  }
  _MkdirDart? mkdir;
  try {
    mkdir = process
        .lookup<NativeFunction<_MkdirNative>>('mkdir')
        .asFunction<_MkdirDart>();
  } on ArgumentError {
    mkdir = null;
  }
  int Function()? geteuid;
  try {
    geteuid = process
        .lookup<NativeFunction<Uint32 Function()>>('geteuid')
        .asFunction<int Function()>();
  } on ArgumentError {
    geteuid = null;
  }
  _OpenDart? open;
  try {
    open = process
        .lookup<NativeFunction<_OpenNative>>('open')
        .asFunction<_OpenDart>();
  } on ArgumentError {
    open = null;
  }
  _FdIntDart? fsync;
  try {
    fsync = process
        .lookup<NativeFunction<_FdIntNative>>('fsync')
        .asFunction<_FdIntDart>();
  } on ArgumentError {
    fsync = null;
  }
  _FdIntDart? close;
  try {
    close = process
        .lookup<NativeFunction<_FdIntNative>>('close')
        .asFunction<_FdIntDart>();
  } on ArgumentError {
    close = null;
  }
  _KillDart? kill;
  try {
    kill = process
        .lookup<NativeFunction<_KillNative>>('kill')
        .asFunction<_KillDart>();
  } on ArgumentError {
    kill = null;
  }
  _ErrnoLocationDart? errnoLocation;
  // Darwin calls it `__error`, glibc `__errno_location`, bionic `__errno`.
  for (final name in const ['__error', '__errno_location', '__errno']) {
    try {
      errnoLocation = process
          .lookup<NativeFunction<_ErrnoLocationNative>>(name)
          .asFunction<_ErrnoLocationDart>();
      break;
    } on ArgumentError {
      continue;
    }
  }
  return _libc = _Libc(
    layout,
    lstat,
    chmod,
    mkdir,
    geteuid,
    open,
    fsync,
    close,
    kill,
    errnoLocation,
  );
}

/// Whether this host can answer any of the questions below.
bool get posixFactsAvailable => _resolveLibc() != null;

PosixFileFacts? _rawLstat(_Libc libc, String path) {
  final layout = libc.layout;
  final pathPtr = path.toNativeUtf8();
  final buffer = calloc<Uint8>(layout.bufferBytes);
  try {
    if (libc.lstat(pathPtr, buffer) != 0) return null;
    int u32(int offset) => (buffer + offset).cast<Uint32>().value;
    int u64(int offset) => (buffer + offset).cast<Uint64>().value;
    return PosixFileFacts(
      deviceId: layout.devIs64
          ? u64(layout.devOffset)
          : (buffer + layout.devOffset).cast<Int32>().value,
      inode: u64(layout.inoOffset),
      mode: layout.modeIs16
          ? (buffer + layout.modeOffset).cast<Uint16>().value
          : u32(layout.modeOffset),
      uid: u32(layout.uidOffset),
      gid: u32(layout.gidOffset),
    );
  } finally {
    calloc.free(buffer);
    calloc.free(pathPtr);
  }
}

/// `lstat(2)` for [path] — the link itself, never what it points at.
///
/// Null when the host has no usable libc/ABI, when the call failed, or when
/// the parsed answer disagrees with what Dart's own `stat` sees. That last one
/// is the guard against a wrong [_StatLayout]: the two readings come from
/// different code paths, so a layout that is off by a field cannot pass both.
PosixFileFacts? posixLstat(String path) {
  final libc = _resolveLibc();
  if (libc == null) return null;
  final facts = _rawLstat(libc, path);
  if (facts == null) return null;

  final FileSystemEntityType dartType;
  try {
    dartType = FileSystemEntity.typeSync(path, followLinks: false);
  } on FileSystemException {
    return null;
  }
  if (facts.isSymlink != (dartType == FileSystemEntityType.link)) return null;
  if (facts.isDirectory != (dartType == FileSystemEntityType.directory)) {
    return null;
  }
  if (!facts.isSymlink) {
    // Dart's `stat` follows links, so this is only comparable off the link
    // path — where it is the same object and therefore the same mode. A
    // mismatch means the layout is wrong (or the path was swapped mid-check);
    // either way the answer is not usable.
    try {
      if (FileStat.statSync(path).mode != facts.mode) return null;
    } on FileSystemException {
      return null;
    }
  }
  return facts;
}

/// `chmod(2)`. Null when unavailable; otherwise 0 on success.
///
/// The point is not speed. `Process.run('chmod', …)` resolves the command
/// through PATH, which is the same substitutable oracle C-01 was about.
int? posixChmod(String path, int mode) {
  final libc = _resolveLibc();
  final chmod = libc?.chmod;
  if (chmod == null) return null;
  final pathPtr = path.toNativeUtf8();
  try {
    return chmod(pathPtr, mode);
  } finally {
    calloc.free(pathPtr);
  }
}

/// `mkdir(2)` — creates with [mode] and FAILS if the path already exists.
///
/// Dart's `Directory.create` is happy to return an existing directory, so it
/// cannot express "this must be mine, freshly made". Null when unavailable;
/// otherwise 0 on success and -1 on any failure (including EEXIST).
int? posixMkdir(String path, int mode) {
  final libc = _resolveLibc();
  final mkdir = libc?.mkdir;
  if (mkdir == null) return null;
  final pathPtr = path.toNativeUtf8();
  try {
    return mkdir(pathPtr, mode);
  } finally {
    calloc.free(pathPtr);
  }
}

/// The effective uid of this process, or null when it cannot be read.
int? posixEuid() => _resolveLibc()?.geteuid?.call();

const _eperm = 1; // EPERM — same number on Linux and Darwin
const _esrch = 3; // ESRCH

/// Whether a process with [processId] exists — `kill(2)` with signal 0.
///
/// Signal 0 sends nothing; it runs the permission and existence checks and
/// stops. That is the POSIX way to ask "is this pid still there", and asking it
/// through libc rather than through `Process.run('kill', …)` matters three
/// times over:
///
///   * `kill` is a bare command name resolved through PATH — the substitutable
///     oracle audit C-01 was about, here deciding whether a directory gets
///     deleted;
///   * iOS and (increasingly) Android cannot start a subprocess AT ALL:
///     `Process.run` throws `Starting new processes is not supported on iOS`,
///     so every answer on those platforms was really an exception handler's
///     guess;
///   * Windows has no `kill` binary, so the subprocess version answered
///     "cannot tell" there on every single call, forever.
///
/// Three-valued on purpose. True and false are answers; **null means this host
/// could not be asked**, and a caller must decide what to do about that rather
/// than be handed a guess dressed up as a fact:
///
///   * `kill` returning 0 — the process exists and we may signal it: ALIVE.
///   * `ESRCH` — no such process: DEAD. This is the only proof of death POSIX
///     offers, and it is why the errno read is not optional; a bare `-1` is
///     ambiguous.
///   * `EPERM` — it exists, it just is not ours to signal: ALIVE.
///   * anything else, no libc binding, no `errno` symbol: null.
///
/// [processId] must be positive. Zero and negatives address process GROUPS in
/// `kill(2)`, which is a different question than the one this asks, so they
/// come back null rather than quietly answering about the caller's own group.
bool? posixProcessAlive(int processId) {
  if (processId <= 0) return null;
  final libc = _resolveLibc();
  final kill = libc?.kill;
  final errnoLocation = libc?.errnoLocation;
  if (kill == null || errnoLocation == null) return null;
  // Resolve the (thread-local) errno slot BEFORE the call, so nothing runs
  // between `kill` setting errno and this reading it.
  final errno = errnoLocation();
  errno.value = 0;
  if (kill(processId, 0) == 0) return true;
  return switch (errno.value) {
    _esrch => false,
    _eperm => true,
    _ => null,
  };
}

/// `fsync(2)` on the DIRECTORY at [path].
///
/// Flushing a file makes its CONTENT durable; it says nothing about the name
/// that points at it. A write-then-rename whose rename is still only in the
/// page cache can be lost across a power failure while the data it wrote
/// survives — leaving the temporary file on disk and the real name gone. The
/// directory is the object that has to be synced for the rename to stick.
///
/// Dart exposes no handle to a directory, so this opens one (`O_RDONLY`, which
/// is legal on a directory on both Linux and Darwin), syncs and closes it.
/// Null when the host has no usable binding; otherwise 0 on success.
int? posixFsyncDir(String path) {
  final libc = _resolveLibc();
  final open = libc?.open;
  final fsync = libc?.fsync;
  final close = libc?.close;
  if (open == null || fsync == null || close == null) return null;
  final pathPtr = path.toNativeUtf8();
  try {
    final fd = open(pathPtr, 0); // O_RDONLY, and never O_CREAT
    if (fd < 0) return -1;
    try {
      return fsync(fd);
    } finally {
      close(fd);
    }
  } finally {
    calloc.free(pathPtr);
  }
}
