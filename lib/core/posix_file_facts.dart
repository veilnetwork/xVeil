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

class _Libc {
  _Libc(this.layout, this.lstat, this.chmod, this.mkdir, this.geteuid);

  final _StatLayout layout;
  final _PathIntDart lstat;
  final _ChmodDart? chmod;
  final _MkdirDart? mkdir;
  final int Function()? geteuid;
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
  return _libc = _Libc(layout, lstat, chmod, mkdir, geteuid);
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
