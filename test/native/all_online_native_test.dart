import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

/// Reproduces the STORAGE path of "all identities online" on a REAL container,
/// headless (no veil node): build a master + two child identities exactly like
/// addIdentity does, then open the whole roster at once via HvMultiSpaceBacking
/// — the step the live all-online unlock does before booting nodes. If this
/// passes, an all-online unlock failure is in the node boot (ports/sockets),
/// not storage.
void main() {
  final available = ensureHiddenVolumeLoaded();
  final skip = available
      ? null
      : 'libhidden_volume_ffi not built — run scripts/build-native.sh';

  NodeId nid(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

  test('master roster opens ALL children at once over one MultiSpace', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_ao_');
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage single() => HiddenVolumeStorage(
          hvSpaceOpener(path, argon: hv.ArgonPreset.min),
          keysOpener: hvKeysSpaceOpener(path),
        );
    try {
      // 1. The first identity (onboarding-style): create, save id, grab keys.
      final personal = single();
      expect(await personal.open(password: 'one', createIfMissing: true), isTrue);
      await personal.saveIdentity(Identity(nodeId: nid(1), displayName: 'Personal'));
      final kPersonal = personal.exportSpaceKeys();
      await personal.close();

      // 2. The second identity (addIdentity creates it under its own password).
      final work = single();
      expect(await work.open(password: 'two', createIfMissing: true), isTrue);
      await work.saveIdentity(Identity(nodeId: nid(2), displayName: 'Work'));
      final kWork = work.exportSpaceKeys();
      await work.close();

      // 3. The master space holds the roster (created by add_space under
      //    'master'), exactly as addIdentity does.
      final master = single();
      expect(await master.open(password: 'master', createIfMissing: true), isTrue);
      await master.saveRoster([
        RosterEntry(label: 'Personal', spaceKeys: kPersonal),
        RosterEntry(label: 'Work', spaceKeys: kWork),
      ]);
      await master.close();

      // 4. The live unlock path: open the master single-space, read the roster,
      //    close it, THEN host every child at once over one MultiSpace.
      final unlockMaster = single();
      expect(await unlockMaster.open(password: 'master'), isTrue);
      final roster = await unlockMaster.loadRoster();
      await unlockMaster.close();
      expect(roster, isNotNull);
      expect(roster!.map((e) => e.label), ['Personal', 'Work']);

      final backing = HvMultiSpaceBacking.open(path);
      final views = <String, HiddenVolumeStorage>{};
      for (final e in roster) {
        final id = backing.openSpace(e.spaceKeys); // the step that may fail
        views[e.label] = HiddenVolumeStorage.fromStore(
            MultiSpaceKvLogStore(backing, id));
      }

      // Both identities are open AT ONCE and read their own data.
      expect((await views['Personal']!.loadIdentity())!.displayName, 'Personal');
      expect((await views['Work']!.loadIdentity())!.displayName, 'Work');
      // Independent writes to both, concurrently — the all-online property.
      await views['Personal']!.putSetting('k', 'p');
      await views['Work']!.putSetting('k', 'w');
      expect(await views['Personal']!.getSetting('k'), 'p');
      expect(await views['Work']!.getSetting('k'), 'w');

      backing.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);
}
