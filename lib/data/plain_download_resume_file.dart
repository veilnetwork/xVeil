part of 'serve_source.dart';

String? _posixDownloadIdentity(PosixFileFacts? facts) =>
    facts != null && facts.isRegularFile
    ? '${facts.deviceId}:${facts.inode}'
    : null;

String? _windowsDownloadHandleIdentity(int handle) => using((arena) {
  final info = arena<win.BY_HANDLE_FILE_INFORMATION>();
  if (win.GetFileInformationByHandle(handle, info) == 0 ||
      info.ref.dwFileAttributes &
              (win.FILE_ATTRIBUTE_DIRECTORY |
                  win.FILE_ATTRIBUTE_REPARSE_POINT) !=
          0) {
    return null;
  }
  final file = info.ref;
  return '${file.dwVolumeSerialNumber}:${file.nFileIndexHigh}:${file.nFileIndexLow}';
});

int _openWindowsDownload(String path, int access) => using((arena) {
  return win.CreateFile(
    path.toNativeUtf16(allocator: arena),
    access,
    win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
    nullptr,
    win.OPEN_EXISTING,
    win.FILE_FLAG_OPEN_REPARSE_POINT,
    0,
  );
});

String? _windowsDownloadPathIdentity(String path) {
  final handle = _openWindowsDownload(path, win.FILE_READ_ATTRIBUTES);
  if (handle == win.INVALID_HANDLE_VALUE) return null;
  try {
    return _windowsDownloadHandleIdentity(handle);
  } finally {
    win.CloseHandle(handle);
  }
}

typedef _DownloadPositionedIo =
    int Function(Pointer<Uint8> buffer, int remaining, int offset);

VeilPlainFileSink? _openPlainDownloadForResume(String path, String expected) {
  try {
    if (plainDownloadDestinationIdentity(path) != expected) return null;
    final io = Platform.isWindows
        ? _openWindowsDownloadIo(path, expected)
        : _openPosixDownloadIo(path, expected);
    if (io == null) return null;
    var closed = false;

    return (
      write: (offset, bytes) async {
        if (closed || bytes.isEmpty) return;
        if (plainDownloadDestinationIdentity(path) != expected) {
          throw FileSystemException('Download destination changed', path);
        }
        using((arena) {
          final buffer = arena<Uint8>(bytes.length);
          buffer.asTypedList(bytes.length).setAll(0, bytes);
          var written = 0;
          while (written < bytes.length) {
            final count = io.write(
              buffer + written,
              bytes.length - written,
              offset + written,
            );
            if (count <= 0) {
              throw FileSystemException(
                'Could not write the download',
                path,
                io.error(),
              );
            }
            written += count;
          }
        });
      },
      read: (offset, length) async {
        if (closed || plainDownloadDestinationIdentity(path) != expected) {
          return null;
        }
        if (length == 0) return Uint8List(0);
        return using((arena) {
          final buffer = arena<Uint8>(length);
          var read = 0;
          while (read < length) {
            final count = io.read(buffer + read, length - read, offset + read);
            if (count < 0) return null;
            if (count == 0) break;
            read += count;
          }
          return Uint8List.fromList(buffer.asTypedList(read));
        });
      },
      close: () async {
        if (closed) return;
        closed = true;
        io.close();
      },
    );
  } on ArgumentError {
    return null;
  }
}

typedef _DownloadFileIo = ({
  _DownloadPositionedIo read,
  _DownloadPositionedIo write,
  OSError Function() error,
  void Function() close,
});

_DownloadFileIo? _openWindowsDownloadIo(String path, String expected) {
  final handle = _openWindowsDownload(
    path,
    win.GENERIC_READ | win.GENERIC_WRITE,
  );
  if (handle == win.INVALID_HANDLE_VALUE) return null;
  if (_windowsDownloadHandleIdentity(handle) != expected) {
    win.CloseHandle(handle);
    return null;
  }
  var error = 0;
  int at(Pointer<Uint8> buffer, int length, int offset, {required bool write}) {
    return using((arena) {
      final count = arena<Uint32>();
      if (win.SetFilePointerEx(handle, offset, nullptr, win.FILE_BEGIN) == 0 ||
          (write
                  ? win.WriteFile(handle, buffer, length, count, nullptr)
                  : win.ReadFile(handle, buffer, length, count, nullptr)) ==
              0) {
        error = win.GetLastError();
        return -1;
      }
      return count.value;
    });
  }

  return (
    read: (buffer, length, offset) => at(buffer, length, offset, write: false),
    write: (buffer, length, offset) => at(buffer, length, offset, write: true),
    error: () => OSError('Windows file I/O failed', error),
    close: () => win.CloseHandle(handle),
  );
}

_DownloadFileIo? _openPosixDownloadIo(String path, String expected) {
  if (!posixFactsAvailable) return null;
  final libc = DynamicLibrary.process();
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final largeOffsets = sizeOf<IntPtr>() == 4;
  final pread = libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, UintPtr, Int64),
        int Function(int, Pointer<Uint8>, int, int)
      >(largeOffsets ? 'pread64' : 'pread');
  final pwrite = libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, UintPtr, Int64),
        int Function(int, Pointer<Uint8>, int, int)
      >(largeOffsets ? 'pwrite64' : 'pwrite');
  final apple = Platform.isMacOS || Platform.isIOS;
  // O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, with no creation or truncation.
  final fd = using(
    (arena) =>
        open(path.toNativeUtf8(allocator: arena), apple ? 0x1000106 : 0xa0802),
  );
  if (fd < 0) return null;
  if (_posixDownloadIdentity(posixDescriptorFacts(fd)) != expected) {
    close(fd);
    return null;
  }
  return (
    read: (buffer, length, offset) => pread(fd, buffer, length, offset),
    write: (buffer, length, offset) => pwrite(fd, buffer, length, offset),
    error: () => OSError('POSIX file I/O failed', posixErrnoSlot()?.value ?? 0),
    close: () => close(fd),
  );
}
