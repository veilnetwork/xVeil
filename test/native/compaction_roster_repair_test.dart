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
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _FaultStorage extends HiddenVolumeStorage {
  _FaultStorage(String path, this.failProbe)
    : super.async(workerSpaceOpener(path));
  final bool failProbe;
  bool armed = true;
  String? password;

  @override
  Future<bool> open({required String password, bool createIfMissing = false}) {
    this.password = password;
    if (armed && failProbe && password == 'child-fixture') {
      return Future<bool>.value(false);
    }
    return super.open(password: password, createIfMissing: createIfMissing);
  }

  @override
  Future<void> saveRoster(List<RosterEntry> entries) {
    if (armed && !failProbe && password == 'duress-fixture') {
      throw StateError('fixture metadata write refusal');
    }
    return super.saveRoster(entries);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XVEIL_HV_DYLIB'];
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final failProbe in [false, true]) {
    test(
      'real remap retry retains child data (probe=$failProbe)',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-repair-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        final passwords = ['child-fixture', 'master-fixture', 'duress-fixture'];
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode(passwords.first)),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        final roster = CompactionRoster();
        final oldKeys = <String, Uint8List>{};
        final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
        for (final password in passwords) {
          final seed = HiddenVolumeStorage.async(workerSpaceOpener(path));
          try {
            expect(
              await seed.open(password: password, createIfMissing: true),
              isTrue,
            );
            await seed.saveProfile(UserProfile(displayName: password));
            if (password == 'child-fixture') {
              await seed.storeFile('fixture-body', body);
            } else {
              await seed.saveRoster([
                RosterEntry(
                  label: 'child',
                  spaceKeys: oldKeys[passwords.first]!,
                  anonymous: password == 'duress-fixture',
                ),
              ]);
            }
            oldKeys[password] = await seed.exportSpaceKeys();
            roster.addUnlocked(
              password,
              passwordBytes: utf8.encode(password),
              spaceKeys: oldKeys[password],
            );
          } finally {
            await seed.close();
          }
        }
        await hv.compactKnownAsync(
          path,
          passwords.map((s) => Uint8List.fromList(utf8.encode(s))).toList(),
          dylibPath: library,
        );
        final storage = _FaultStorage(path, failProbe);
        final c = ProviderContainer(
          overrides: [
            storageProvider.overrideWithValue(storage),
            appControllerProvider.overrideWith(_Controller.new),
          ],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(appControllerProvider.notifier);
        expect(
          await ctrl.remapRostersAfterCompaction(roster.credentials()),
          isNotEmpty,
        );
        storage.armed = false;
        expect(
          await ctrl.remapRostersAfterCompaction(roster.credentials()),
          isEmpty,
        );
        expect(
          await ctrl.remapRostersAfterCompaction(roster.credentials()),
          isEmpty,
        );
        expect(storage.isOpen, isFalse);

        for (final holder in passwords.skip(1)) {
          // Fresh workers and key-based opens prove the actual references the
          // masters persisted, rather than merely checking their labels.
          final reader = HiddenVolumeStorage.async(
            workerSpaceOpener(path),
            keysOpener: workerKeysSpaceOpener(path),
          );
          try {
            expect(await reader.open(password: holder), isTrue);
            final entries = (await reader.loadRoster())!;
            expect(entries, hasLength(1));
            expect(entries.single.anonymous, holder == 'duress-fixture');
            expect(entries.single.spaceKeys, isNot(oldKeys[passwords.first]));
            await reader.close();
            expect(await reader.openWithKeys(entries.single.spaceKeys), isTrue);
            expect((await reader.loadProfile())?.displayName, passwords.first);
            expect(await reader.loadFile('fixture-body'), body);
          } finally {
            await reader.close();
          }
        }
      },
      skip: library == null
          ? 'Set XVEIL_HV_DYLIB to a qualified library'
          : false,
    );
  }
}
