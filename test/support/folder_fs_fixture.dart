import 'dart:ffi';
import 'dart:io';

import 'package:xveil/state/folder_sync_adapters.dart';

/// Explicit test dependency: never register this FS-only fixture as the SDK.
/// CI builds it before running the suite. Local usage is documented alongside
/// tests/fs_fixture; a missing dependency must not select pathname publication.
LocalFolderSyncDisk folderDiskFixture() {
  final path = Platform.environment['XVEIL_FS_TEST_DYLIB'];
  if (path == null || !File(path).isAbsolute || !File(path).existsSync()) {
    throw StateError('Build tests/fs_fixture and set XVEIL_FS_TEST_DYLIB');
  }
  return LocalFolderSyncDisk(library: DynamicLibrary.open(path));
}
