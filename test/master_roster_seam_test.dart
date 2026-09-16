import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/roster.dart';

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
    final childKeys = await child.exportSpaceKeys();
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

  test('a roster outgrows a settings record and still comes back', () async {
    // One JSON value in a settings record, and the container caps a value at
    // 2048 bytes. Each identity costs ~105 of them, so somewhere around twenty
    // identities `saveRoster` started throwing — AFTER the child space had
    // been created, leaving a real identity on disk that the master does not
    // list (report27 X31).
    final c = FakeHvContainer();
    final master = c.storage();
    expect(await master.open(password: 'm', createIfMissing: true), isTrue);

    final many = [
      for (var i = 0; i < 24; i++)
        RosterEntry(
          label: 'identity number $i',
          spaceKeys: Uint8List.fromList(List.generate(64, (b) => (i + b) & 0xff)),
          anonymous: i.isEven,
        ),
    ];
    await master.saveRoster(many);

    final back = await master.loadRoster();
    expect(back, isNotNull);
    expect(back!.length, many.length);
    for (var i = 0; i < many.length; i++) {
      expect(back[i].label, many[i].label);
      expect(back[i].spaceKeys, many[i].spaceKeys);
      expect(back[i].anonymous, many[i].anonymous);
    }
    await master.close();

    // And it is still there for the next open — the roster is what names every
    // identity in this container.
    final again = c.storage();
    expect(await again.open(password: 'm'), isTrue);
    expect((await again.loadRoster())!.length, many.length);
    await again.close();
  });

  test('a small roster still lives in the settings record', () async {
    // The move to the file store happens only when it has to: an ordinary
    // container keeps the shape every existing install already has.
    final c = FakeHvContainer();
    final master = c.storage();
    await master.open(password: 'm', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'me', spaceKeys: Uint8List(64)),
    ]);
    expect(
      await master.hasFile('master:roster.v2'),
      isFalse,
      reason: 'a roster that fits keeps the home every install already has',
    );
    expect((await master.loadRoster())!.single.label, 'me');
    await master.close();
  });
}
