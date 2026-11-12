import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

class _AfterPublication implements Exception {}

enum _Boundary { complete, afterPublication, lockBeforePublication }

class _Controller extends AppController {
  _Controller(this.boundary);
  final _Boundary boundary;
  final repaired = Completer<void>();
  final release = Completer<void>();
  var reopenCalls = 0;

  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  Future<void> unlock(String password) async => reopenCalls++;

  @override
  Future<List<String>> remapRostersAfterCompaction(
    List<({List<int> password, List<int> oldSpaceKeys})> credentials, {
    Storage? storageOverride,
  }) async {
    final result = await super.remapRostersAfterCompaction(
      credentials,
      storageOverride: storageOverride,
    );
    if (boundary == _Boundary.lockBeforePublication) {
      repaired.complete();
      await release.future;
    }
    return result;
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in _Boundary.values) {
    test(
      'real master references survive $boundary',
      () async {
        SharedPreferences.setMockInitialValues({});
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-prepublication-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode('child-fixture')),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        HiddenVolumeStorage facade() => HiddenVolumeStorage.async(
          workerSpaceOpener(path),
          keysOpener: workerKeysSpaceOpener(path),
        );
        final seed = facade();
        final roster = CompactionRoster();
        late Uint8List oldChildKeys;
        for (final password in [
          'child-fixture',
          'master-fixture',
          'duress-fixture',
        ]) {
          try {
            expect(
              await seed.open(password: password, createIfMissing: true),
              isTrue,
            );
            await seed.saveProfile(UserProfile(displayName: password));
            if (password == 'child-fixture') {
              await seed.storeFile('fixture-body', body);
              oldChildKeys = await seed.exportSpaceKeys();
            } else {
              await seed.saveRoster([
                RosterEntry(
                  label: 'child',
                  spaceKeys: oldChildKeys,
                  anonymous: password == 'duress-fixture',
                ),
              ]);
            }
            roster.addUnlocked(
              password,
              passwordBytes: utf8.encode(password),
              spaceKeys: await seed.exportSpaceKeys(),
            );
          } finally {
            await seed.close();
          }
        }
        final before = await File(path).readAsBytes();
        final storage = facade();
        final controller = _Controller(boundary);
        var nativeCalls = 0;
        final providers = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            storageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${dir.path}/runtime',
                storePath: path,
              ),
            ),
            preparedContainerCompactorProvider.overrideWithValue((
              path,
              passwords, {
              required repairMetadata,
              dylibPath,
            }) async {
              nativeCalls++;
              await hv.compactKnownPreparedAsync(
                path,
                passwords,
                repairMetadata: repairMetadata,
                dylibPath: dylibPath,
              );
              if (boundary == _Boundary.afterPublication) {
                throw _AfterPublication();
              }
            }),
          ],
        );
        addTearDown(providers.dispose);
        providers.read(appControllerProvider);
        try {
          final operation = controller.compactStorageKeeping(
            roster: roster,
            reopenWith: 'master-fixture',
          );
          if (boundary == _Boundary.lockBeforePublication) {
            final refused = expectLater(operation, throwsStateError);
            try {
              await controller.repaired.future;
              expect(await File(path).readAsBytes(), before);
              await controller.lock();
            } finally {
              controller.release.complete();
              await refused;
            }
            // Check before any unlock can legitimately write to the source.
            expect(await File(path).readAsBytes(), before);
            expect(controller.reopenCalls, 0);
          } else if (boundary == _Boundary.afterPublication) {
            await expectLater(operation, throwsA(isA<_AfterPublication>()));
            expect(controller.reopenCalls, 1);
          } else {
            await operation;
            expect(controller.reopenCalls, 1);
          }
          expect(nativeCalls, 1);
          expect(storage.isOpen, isFalse);
          for (final password in ['master-fixture', 'duress-fixture']) {
            final reader = facade();
            try {
              expect(await reader.open(password: password), isTrue);
              final entries = (await reader.loadRoster())!;
              expect(entries, hasLength(1));
              expect(entries.single.anonymous, password == 'duress-fixture');
              expect(
                entries.single.spaceKeys,
                boundary == _Boundary.lockBeforePublication
                    ? equals(oldChildKeys)
                    : isNot(oldChildKeys),
              );
              await reader.close();
              expect(
                await reader.openWithKeys(entries.single.spaceKeys),
                isTrue,
              );
              expect(await reader.loadFile('fixture-body'), body);
            } finally {
              await reader.close();
            }
          }
        } finally {
          await storage.close();
        }
      },
      skip:
          Platform.environment['XVEIL_NATIVE_COMPACTION_PREPUBLICATION'] != '1',
    );
  }
}
