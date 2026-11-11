import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
}

final class _Timeval extends Struct {
  @IntPtr()
  external int seconds;
  @IntPtr()
  external int microseconds;
}

/// dart:io's setter drops subseconds. Use the independent OS setter
/// so the fixture really contains a fractional timestamp before checking reads.
Future<void> setPreciseFileTime(File file, int modifiedMs) async {
  if (!Platform.isWindows) {
    final setTime = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<_Timeval>),
          int Function(Pointer<Utf8>, Pointer<_Timeval>)
        >('utimes');
    final path = file.absolute.path.toNativeUtf8();
    final times = calloc<_Timeval>(2);
    try {
      for (var i = 0; i < 2; i++) {
        times[i]
          ..seconds = modifiedMs ~/ 1000
          ..microseconds = (modifiedMs % 1000) * 1000;
      }
      if (setTime(path, times) != 0) {
        throw StateError('Cannot set timestamp fixture');
      }
    } finally {
      calloc.free(times);
      calloc.free(path);
    }
    return;
  }
  final kernel = DynamicLibrary.open('kernel32.dll');
  final open = kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  final setTime = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        )
      >('SetFileTime');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final path = file.absolute.path.toNativeUtf16();
  final time = calloc<_FileTime>();
  try {
    final ticks = (modifiedMs + 11644473600000) * 10000;
    time.ref
      ..low = ticks & 0xffffffff
      ..high = ticks >> 32;
    // Write attributes only, shared access, existing file, no leaf reparse.
    final handle = open(path, 0x100, 7, nullptr, 3, 0x200000, nullptr);
    if (handle == Pointer<Void>.fromAddress(-1)) {
      throw StateError('Cannot open timestamp fixture');
    }
    try {
      if (setTime(handle, nullptr, nullptr, time) == 0) {
        throw StateError('Cannot set timestamp fixture');
      }
    } finally {
      close(handle);
    }
  } finally {
    calloc.free(time);
    calloc.free(path);
  }
}
