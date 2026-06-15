import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/roster.dart';

import 'support/fake_hv_container.dart';

HiddenVolumeStorage _storage(FakeHvContainer c) => c.storage();

void main() {
  test('child created by password is reopened by its exported keys', () async {
    final c = FakeHvContainer();

    // A child identity space, created by its own password; write data.
    final child = _storage(c);
    await child.open(password: 'childpw', createIfMissing: true);
    await child.putSetting('who', 'carol');
    final childKeys = child.exportSpaceKeys();
    expect(childKeys.length, 64);

    // A different handle opens the SAME space from keys alone — no password.
    final viaKeys = _storage(c);
    expect(await viaKeys.openWithKeys(childKeys), isTrue);
    expect(await viaKeys.getSetting('who'), 'carol');
  });

  test('master records children in its roster and opens each by keys', () async {
    final c = FakeHvContainer();

    // The master space.
    final master = _storage(c);
    await master.open(password: 'masterpw', createIfMissing: true);

    // Two children, each its own space; set them up + collect their keys.
    final roster = <RosterEntry>[];
    for (final (label, pw, who) in [
      ('me', 'pw-me', 'alice'),
      ('relatives', 'pw-rel', 'mom'),
    ]) {
      final child = _storage(c);
      await child.open(password: pw, createIfMissing: true);
      await child.putSetting('who', who);
      roster.add(RosterEntry(label: label, spaceKeys: child.exportSpaceKeys()));
    }
    await master.saveRoster(roster);

    // A fresh master session: load the roster, open each child by its keys.
    final reopened = _storage(c);
    await reopened.open(password: 'masterpw');
    final entries = await reopened.loadRoster();
    expect(entries!.map((e) => e.label), ['me', 'relatives']);

    final opened = <String>[];
    for (final e in entries) {
      final child = _storage(c);
      expect(await child.openWithKeys(e.spaceKeys), isTrue,
          reason: 'master opens ${e.label} without its password');
      opened.add((await child.getSetting('who'))!);
    }
    expect(opened, ['alice', 'mom']);
  });

  test('openWithKeys returns false for keys matching no space', () async {
    final c = FakeHvContainer();
    final s = _storage(c);
    expect(await s.openWithKeys(Uint8List(64)), isFalse);
  });
}
