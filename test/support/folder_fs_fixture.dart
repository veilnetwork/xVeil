import 'dart:ffi';
import 'dart:io';

import 'package:xveil/data/native_libs.dart';
import 'package:xveil/data/node/veil_library.dart';
import 'package:xveil/state/folder_sync_adapters.dart';

/// Explicit test dependency: never register this FS-only fixture as the SDK.
/// CI builds it before running the suite. Local usage is documented alongside
/// tests/fs_fixture; a missing dependency must not select pathname publication.
LocalFolderSyncDisk folderDiskFixture() {
  if (Platform.environment['XVEIL_FULL_FOLDER_SDK'] == '1') {
    final path = envLibPath('VEIL_FFI_DYLIB');
    if (path == null) {
      throw StateError('Full SDK qualification requires VEIL_FFI_DYLIB');
    }
    // Exercise ordinary startup and the default ABI gate. Also prove that a
    // fallback candidate did not silently replace the selected build.
    final expected = DynamicLibrary.open(path);
    if (!loadNativeLib('veilclient_ffi', envVar: 'VEIL_FFI_DYLIB') ||
        verifiedVeilLibrary().handle != expected.handle) {
      throw StateError('The selected complete SDK was not loaded');
    }
    return LocalFolderSyncDisk();
  }
  final path = Platform.environment['XVEIL_FS_TEST_DYLIB'];
  if (path == null || !File(path).isAbsolute || !File(path).existsSync()) {
    throw StateError('Build tests/fs_fixture and set XVEIL_FS_TEST_DYLIB');
  }
  return LocalFolderSyncDisk(library: DynamicLibrary.open(path));
}
