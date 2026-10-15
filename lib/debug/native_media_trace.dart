import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _names = [
  'VEIL_MEDIA_DIAG_PATH',
  'VEIL_MEDIA_RTP_TRACE_LIMIT',
  'VEIL_MEDIA_PLAYOUT_TRACE',
];
Map<String, String?>? _original;

/// Used only by the authenticated debug hook, before any call owns the slot.
/// The native encoder/renderer read these options when they are constructed.
/// Null restores the environment that preceded this diagnostic session.
bool configureNativeMediaTrace(String? path) {
  if (Platform.isWindows) return false;
  final libc = DynamicLibrary.process();
  final get = libc
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)
      >('getenv');
  final set = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('setenv');
  final unset = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('unsetenv');

  String? read(String name) {
    final key = name.toNativeUtf8();
    try {
      final value = get(key);
      return value == nullptr ? null : value.toDartString();
    } finally {
      calloc.free(key);
    }
  }

  void write(String name, String? value) {
    final key = name.toNativeUtf8();
    final text = value?.toNativeUtf8();
    try {
      final rc = text == null ? unset(key) : set(key, text, 1);
      if (rc != 0) {
        throw StateError('Cannot configure native media trace: $name');
      }
    } finally {
      calloc.free(key);
      if (text != null) calloc.free(text);
    }
  }

  if (path == null) {
    final original = _original;
    if (original != null) {
      original.forEach(write);
      _original = null;
    }
    return true;
  }
  if (path.isEmpty || path.contains('\x00')) {
    throw ArgumentError.value(path, 'path', 'Expected a nonempty native path');
  }
  final previous = {for (final name in _names) name: read(name)};
  try {
    write(_names[0], path);
    write(_names[1], '32768');
    write(_names[2], '1');
    _original ??= previous;
  } catch (_) {
    previous.forEach(write);
    rethrow;
  }
  return true;
}
