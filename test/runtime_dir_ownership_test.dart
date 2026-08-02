import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

/// The runtime base can come from `XVEIL_RUNTIME_DIR`, and lock/wipe removes it
/// RECURSIVELY. Nothing checked the path was ours, so a wrong launcher entry —
/// or the variable set by anything else in the session — turned teardown into a
/// recursive delete of whatever it pointed at.
///
/// (The audit paired this with "allow overrides only in debug/test". That half
/// is deliberately NOT taken: profiles and headless/bot deployments legitimately
/// run on an operator-chosen `XVEIL_STORE_PATH` / `XVEIL_RUNTIME_DIR`.)
void main() {
  test('a directory we created is recognised as ours', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_own_yes');
    addTearDown(() => dir.deleteSync(recursive: true));

    expect(runtimeDirIsOurs(dir.path), isFalse,
        reason: 'precondition: an unmarked directory is not ours');
    await markRuntimeDirOwned(dir.path);
    expect(runtimeDirIsOurs(dir.path), isTrue);
    expect(File('${dir.path}/$kRuntimeDirMarker').existsSync(), isTrue);
  });

  test("someone else's directory is never ours", () async {
    // The case that mattered: a real directory full of real files, pointed at
    // by an env var. It must read as not-ours no matter what is inside it.
    final dir = Directory.systemTemp.createTempSync('xveil_own_no');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/important.txt').writeAsStringSync('do not delete me');
    Directory('${dir.path}/nested').createSync();

    expect(runtimeDirIsOurs(dir.path), isFalse);
  });

  test('a missing directory is not ours', () {
    // Answering "yes" here would make a caller's guard look like it passed.
    final missing = '${Directory.systemTemp.path}/xveil-does-not-exist-${DateTime.now().microsecondsSinceEpoch}';
    expect(runtimeDirIsOurs(missing), isFalse);
  });

  test('marking is idempotent and creates the directory', () async {
    final root = Directory.systemTemp.createTempSync('xveil_own_mk');
    addTearDown(() => root.deleteSync(recursive: true));
    final target = '${root.path}/nested/runtime';

    await markRuntimeDirOwned(target);
    await markRuntimeDirOwned(target);

    expect(Directory(target).existsSync(), isTrue);
    expect(runtimeDirIsOurs(target), isTrue);
  });
}
