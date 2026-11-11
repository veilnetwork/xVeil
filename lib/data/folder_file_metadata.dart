import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../domain/folder_sync.dart';

/// Folder version stamps must use the publisher's millisecond precision.
/// dart:io's Windows stat truncates mtime to seconds, making an unchanged
/// destination fail the native publication check (or repeat on every scan).
/// This reads metadata only; the pinned native publisher still authorizes
/// replacement and compares the actual displaced object.
LocalFile? readFolderFileMetadata(File file, String relativePath) {
  if (Platform.isWindows) return _windows.read(file, relativePath);
  final stat = file.statSync();
  if (stat.type != FileSystemEntityType.file) return null;
  return LocalFile(
    path: relativePath,
    size: stat.size,
    modifiedAtMs: stat.modified.millisecondsSinceEpoch,
  );
}

final _windows = _WindowsMetadata();

final class _UnicodeString extends Struct {
  @Uint16()
  external int length;
  @Uint16()
  external int capacity;
  external Pointer<Utf16> buffer;
}

final class _ObjectAttributes extends Struct {
  @Uint32()
  external int length;
  external Pointer<Void> root;
  external Pointer<_UnicodeString> name;
  @Uint32()
  external int flags;
  external Pointer<Void> securityDescriptor;
  external Pointer<Void> securityQuality;
}

// FILE_NETWORK_OPEN_INFORMATION, shared by the Windows NT filesystem API.
final class _FileInformation extends Struct {
  @Int64()
  external int created;
  @Int64()
  external int accessed;
  @Int64()
  external int modified;
  @Int64()
  external int changed;
  @Int64()
  external int allocated;
  @Int64()
  external int size;
  @Uint32()
  external int attributes;
}

class _WindowsMetadata {
  // The NT API returns its status directly. A separate GetLastError call may
  // lose thread-local state across a Dart VM/FFI transition. Keep this I/O call
  // non-leaf so a slow/network filesystem cannot block VM safepoints.
  late final _query = DynamicLibrary.open('ntdll.dll')
      .lookupFunction<
        Int32 Function(Pointer<_ObjectAttributes>, Pointer<_FileInformation>),
        int Function(Pointer<_ObjectAttributes>, Pointer<_FileInformation>)
      >('NtQueryFullAttributesFile');

  LocalFile? read(File file, String relativePath) {
    if (file.path.contains('\u0000')) {
      throw const FormatException('Invalid folder path');
    }
    // Convert an absolute DOS/UNC path to its NT spelling, preserving extended
    // paths and UTF-16. This grants no write or publication authority.
    final absolute = file.absolute.path.replaceAll('/', r'\');
    final path = absolute.startsWith('\\\\?\\')
        ? '\\??\\${absolute.substring(4)}'
        : absolute.startsWith('\\\\')
        ? '\\??\\UNC\\${absolute.substring(2)}'
        : '\\??\\$absolute';
    if (path.length > 32766) {
      throw const FormatException('Folder path is too long');
    }
    final name = path.toNativeUtf16();
    final unicode = calloc<_UnicodeString>();
    final attributes = calloc<_ObjectAttributes>();
    final data = calloc<_FileInformation>();
    try {
      unicode.ref
        ..length = path.length * 2
        ..capacity = (path.length + 1) * 2
        ..buffer = name;
      attributes.ref
        ..length = sizeOf<_ObjectAttributes>()
        ..name = unicode
        ..flags = 0x40; // OBJ_CASE_INSENSITIVE, normal Windows file semantics.
      final status = _query(attributes, data);
      if (status != 0) {
        final code = status & 0xffffffff;
        // STATUS_NO_SUCH_FILE / OBJECT_NAME_NOT_FOUND / OBJECT_PATH_NOT_FOUND.
        if (const {0xc000000f, 0xc0000034, 0xc000003a}.contains(code)) {
          return null;
        }
        throw FileSystemException(
          'Cannot read folder file metadata',
          '',
          OSError('Windows metadata query failed', status),
        );
      }
      final value = data.ref;
      // Never turn a directory or reparse object into an ordinary file stamp.
      if ((value.attributes & (0x10 | 0x400)) != 0) return null;
      if (value.size < 0 || value.modified < 0) {
        throw const FileSystemException('Invalid folder file metadata');
      }
      return LocalFile(
        path: relativePath,
        size: value.size,
        modifiedAtMs: value.modified ~/ 10000 - 11644473600000,
      );
    } finally {
      calloc.free(data);
      calloc.free(attributes);
      calloc.free(unicode);
      calloc.free(name);
    }
  }
}
