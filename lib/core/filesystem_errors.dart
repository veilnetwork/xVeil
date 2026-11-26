import 'dart:io';

bool fileSystemAccessDenied(FileSystemException error) {
  final code = error.osError?.errorCode;
  return Platform.isWindows
      ? code == 5 || (code != null && (code & 0xffffffff) == 0xc0000022)
      : code == 1 || code == 13;
}

bool fileSystemPathMissing(FileSystemException error) {
  final code = error.osError?.errorCode;
  return code == 2 || (Platform.isWindows ? code == 3 : code == 20);
}
