import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

/// Audit X-01, on a real container.
///
/// A password already in use does NOT create a second space — the space is
/// derived from the password, so opening with `createIfMissing` lands on the
/// existing one. `addIdentity` used to write an Identity into whatever it
/// opened and only afterwards read the keys back, so the write landed on
/// somebody else's space before anything could notice.
///
/// These tests pin the property the fix depends on — a colliding password
/// yields byte-identical space keys — and that the write is what destroys, so
/// checking before it is both necessary and sufficient.
void main() {
  final skip = ensureHiddenVolumeLoaded() ? null : 'no dylib';

  Directory scratch() => Directory('/tmp').createTempSync('xveil_collide_');

  test('a re-used child password resolves to the SAME space keys', () async {
    final dir = scratch();
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage single() => HiddenVolumeStorage(
      hvSpaceOpener(path, argon: hv.ArgonPreset.min),
      keysOpener: hvKeysSpaceOpener(path),
    );
    try {
      final a = single();
      expect(await a.open(password: '222222', createIfMissing: true), isTrue);
      await a.saveProfile(UserProfile(displayName: 'Work'));
      final childKeys = await a.exportSpaceKeys();
      await a.close();

      // The "new" identity, same password. `createIfMissing` opens the
      // EXISTING space — this is the whole hazard.
      final b = single();
      expect(await b.open(password: '222222', createIfMissing: true), isTrue);
      final candidateKeys = await b.exportSpaceKeys();
      await b.close();

      expect(
        listEquals(childKeys, candidateKeys),
        isTrue,
        reason: 'the collision is detectable from the keys alone, before any write',
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('the master password is detectable the same way', () async {
    final dir = scratch();
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage single() => HiddenVolumeStorage(
      hvSpaceOpener(path, argon: hv.ArgonPreset.min),
      keysOpener: hvKeysSpaceOpener(path),
    );
    try {
      final m = single();
      expect(await m.open(password: '000000', createIfMissing: true), isTrue);
      await m.saveRoster(<RosterEntry>[
        RosterEntry(label: 'Identity 1', spaceKeys: Uint8List(64)),
      ]);
      final masterKeys = await m.exportSpaceKeys();
      await m.close();

      final c = single();
      expect(await c.open(password: '000000', createIfMissing: true), isTrue);
      final candidateKeys = await c.exportSpaceKeys();
      await c.close();

      expect(
        listEquals(masterKeys, candidateKeys),
        isTrue,
        reason: 'this is the case that used to overwrite the master with child '
            'data, after which deleting the "child" deleted master storage',
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('a distinct password yields distinct keys — the check does not over-reject', () async {
    final dir = scratch();
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage single() => HiddenVolumeStorage(
      hvSpaceOpener(path, argon: hv.ArgonPreset.min),
      keysOpener: hvKeysSpaceOpener(path),
    );
    try {
      final a = single();
      expect(await a.open(password: '111111', createIfMissing: true), isTrue);
      final k1 = await a.exportSpaceKeys();
      await a.close();

      final b = single();
      expect(await b.open(password: '222222', createIfMissing: true), isTrue);
      final k2 = await b.exportSpaceKeys();
      await b.close();

      expect(listEquals(k1, k2), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);
}
