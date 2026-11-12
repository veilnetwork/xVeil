import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

class _Controller extends AppController {
  int reopenCalls = 0;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> unlock(String password) async => reopenCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('visible rewrite with surviving hardlink repairs real master references', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final dir = await Directory.systemTemp.createTemp('xveil-visible-rewrite-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/container.hv';
    HvKvLogStore(hv.HvSpace.create(path: path,
      password: Uint8List.fromList(utf8.encode('child-fixture')),
      argon: hv.ArgonPreset.min)).close();
    final roster = CompactionRoster();
    final seed = HiddenVolumeStorage.async(workerSpaceOpener(path));
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    late Uint8List childKeys;
    try {
      for (final password in ['child-fixture', 'master-fixture']) {
        expect(await seed.open(password: password, createIfMissing: true), isTrue);
        await seed.saveProfile(UserProfile(displayName: password));
        if (password == 'child-fixture') {
          await seed.storeFile('fixture-payload', bytes);
          childKeys = await seed.exportSpaceKeys();
        } else {
          await seed.saveRoster([RosterEntry(label: 'child', spaceKeys: childKeys)]);
        }
        roster.addUnlocked(password, passwordBytes: utf8.encode(password),
          spaceKeys: await seed.exportSpaceKeys());
        await seed.close();
      }
    } finally {
      await seed.close();
    }
    final link = await Process.run('/bin/ln', [path, '${dir.path}/old-alias.hv']);
    expect(link.exitCode, 0);
    final storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
    var nativeCalls = 0;
    final owner = _Controller();
    final providers = ProviderContainer(overrides: [
      appControllerProvider.overrideWith(() => owner),
      storageProvider.overrideWithValue(storage),
      deniableBootProvider.overrideWithValue(DeniableBootConfig(
        runtimeDir: '${dir.path}/runtime', storePath: path)),
      preparedContainerCompactorProvider.overrideWithValue((path, passwords, {required repairMetadata, dylibPath}) async {
        nativeCalls++;
        await hv.compactKnownPreparedAsync(path, passwords,
          repairMetadata: repairMetadata,
          dylibPath: Platform.environment['XVEIL_HV_DYLIB']);
      }),
    ]);
    addTearDown(providers.dispose);
    final controller = providers.read(appControllerProvider.notifier);
    await expectLater(controller.compactStorageKeeping(roster: roster,
      reopenWith: 'master-fixture'), throwsA(isA<hv.HvException>()
        .having((e) => e.kind, 'kind', 'RenameVisibleAliasesNotRevoked')));
    expect(nativeCalls, 1);
    expect(owner.reopenCalls, 1);
    final reader = HiddenVolumeStorage.async(workerSpaceOpener(path),
      keysOpener: workerKeysSpaceOpener(path));
    try {
      expect(await reader.open(password: 'master-fixture'), isTrue);
      final entry = (await reader.loadRoster())!.single;
      expect(entry.spaceKeys, isNot(childKeys));
      await reader.close();
      expect(await reader.openWithKeys(entry.spaceKeys), isTrue);
      expect((await reader.loadProfile())?.displayName, 'child-fixture');
      expect(await reader.loadFile('fixture-payload'), bytes);
    } finally {
      await reader.close();
      await storage.close();
      for (final entry in roster.credentials()) {
        entry.password.fillRange(0, entry.password.length, 0);
        entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
      }
      childKeys.fillRange(0, childKeys.length, 0);
    }
  }, skip: Platform.environment['XVEIL_NATIVE_COMPACTION_VISIBLE'] != '1' || !Platform.isMacOS);
}
