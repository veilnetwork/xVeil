import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/roster.dart';

/// Multi-space fake container: a password opener and a keys opener that share
/// the same underlying spaces, so a space created by password can be reopened
/// by its exported keys — mirroring the real `HvSpace` create/open/openWithKeys
/// over one container file. Each space gets deterministic 64-byte "SpaceKeys".
class FakeHvContainer {
  final _byKeys = <String, FakeKvLogStore>{};
  final _pwToKeyHex = <String, String>{};

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _keysFor(String pw) {
    final base = utf8.encode(pw);
    return Uint8List.fromList(
        List.generate(64, (i) => (base[i % base.length] + i) & 0xff));
  }

  SpaceOpener get passwordOpener =>
      ({required Uint8List password, required bool create}) {
        final pw = utf8.decode(password);
        final existing = _pwToKeyHex[pw];
        if (existing != null) return _byKeys[existing];
        if (!create) return null; // AuthFailed
        final keys = _keysFor(pw);
        final hex = _hex(keys);
        _pwToKeyHex[pw] = hex;
        return _byKeys[hex] = FakeKvLogStore(keys: keys);
      };

  KeysSpaceOpener get keysOpener => (Uint8List keys) => _byKeys[_hex(keys)];
}

HiddenVolumeStorage _storage(FakeHvContainer c) =>
    HiddenVolumeStorage(c.passwordOpener, keysOpener: c.keysOpener);

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
