import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hv_container.dart';

/// Low-level storage seam (exportSpaceKeys ↔ openWithKeys), serialized to
/// respect the exclusive lock — only one space open at a time. The end-to-end
/// roster orchestration is covered in identity_manager_test.dart.
void main() {
  test('a space created by password is reopened by its exported keys', () async {
    final c = FakeHvContainer();

    final child = c.storage();
    await child.open(password: 'childpw', createIfMissing: true);
    await child.putSetting('who', 'carol');
    final childKeys = child.exportSpaceKeys();
    expect(childKeys.length, 64);
    await child.close(); // release the lock before reopening

    final viaKeys = c.storage();
    expect(await viaKeys.openWithKeys(childKeys), isTrue);
    expect(await viaKeys.getSetting('who'), 'carol');
    await viaKeys.close();
  });

  test('openWithKeys returns false for keys matching no space', () async {
    final c = FakeHvContainer();
    final s = c.storage();
    expect(await s.openWithKeys(Uint8List(64)), isFalse);
  });
}
