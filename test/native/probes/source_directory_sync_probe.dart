import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:xveil/data/native_libs.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_fs_windows.dart' as windows;

void require(bool condition) {
  if (!condition) throw StateError('source-directory probe assertion');
}

void refuses(void Function() work, ManagedFsFailureKind kind) {
  try {
    work();
  } on ManagedFsFailure catch (error) {
    require(error.kind == kind);
    return;
  }
  throw StateError('source-directory probe did not refuse');
}

void main(List<String> args) {
  require(
    Platform.isWindows && args.length == 1 && File(args.single).isAbsolute,
  );
  rememberNativeLib('veilclient_ffi', DynamicLibrary.open(args.single));
  const fs = ManagedFsPlatform();
  final fixture = Directory.systemTemp.createTempSync(
    'xveil-source-directory-',
  );
  try {
    final a = '${fixture.path}/a', b = '${fixture.path}/b';
    require(fs.createPrivateDirectory(a));
    require(fs.createPrivateDirectory(b));
    final expected = fs.inspect(a), other = fs.inspect(b);
    fs.syncSourceDirectory(a);
    require(fs.inspect(a).sameObject(expected));
    refuses(
      () => windows.syncSourceDirectory(a, other),
      ManagedFsFailureKind.unsafe,
    );
    final file = File('$b/keep')..writeAsBytesSync([1, 2, 3], flush: true);
    refuses(
      () => windows.syncSourceDirectory(file.path, expected),
      ManagedFsFailureKind.unsafe,
    );
    refuses(
      () => fs.syncSourceDirectory(file.path),
      ManagedFsFailureKind.unsafe,
    );
    refuses(
      () => windows.syncSourceDirectory('$b/absent', expected),
      ManagedFsFailureKind.io,
    );
    Directory(a).deleteSync();
    require(fs.createPrivateDirectory(a));
    // Keep the original directory alive under a different name instead of
    // relying on filesystem file-ID allocation not to reuse a deleted ID.
    final stale = fs.inspect(a);
    Directory(a).renameSync('$a-retired');
    require(fs.createPrivateDirectory(a));
    refuses(
      () => windows.syncSourceDirectory(a, stale),
      ManagedFsFailureKind.unsafe,
    );
    fs.syncSourceDirectory(a);
    require(base64.encode(file.readAsBytesSync()) == 'AQID');
    stdout.writeln(
      jsonEncode({
        'probe': 'source-directory-sync',
        'checks': 8,
        'passed': true,
      }),
    );
  } finally {
    fixture.deleteSync(recursive: true);
  }
}
