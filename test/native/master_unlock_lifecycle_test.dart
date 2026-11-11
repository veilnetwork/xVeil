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
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vpn_controller.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Storage extends HiddenVolumeStorage {
  _Storage(String path, this.gateKeys)
    : super.async(
        workerSpaceOpener(path),
        keysOpener: workerKeysSpaceOpener(path),
      );
  final bool gateKeys;
  final entered = Completer<void>();
  final release = Completer<void>();
  List<RosterEntry>? returnedRoster;
  Uint8List? returnedKeys;
  Future<void> park(bool here) async {
    if (!here || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final result = await super.loadRoster();
    returnedRoster = result;
    await park(!gateKeys);
    return result;
  }

  @override
  Future<Uint8List> exportSpaceKeys() async {
    final result = await super.exportSpaceKeys();
    returnedKeys = result;
    await park(gateKeys);
    return result;
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn extends Fake implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XVEIL_HV_DYLIB'];
  setUp(
    () => SharedPreferences.setMockInitialValues({'keep_all_online': false}),
  );

  for (final gateKeys in [false, true]) {
    test(
      'native master cancels late ${gateKeys ? 'keys' : 'roster'} without changing stored references',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-master-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode('child-fixture')),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
        final seed = HiddenVolumeStorage.async(workerSpaceOpener(path));
        late Uint8List childKeys;
        try {
          expect(await seed.open(password: 'child-fixture'), isTrue);
          await seed.saveProfile(
            const UserProfile(displayName: 'Native child fixture'),
          );
          await seed.storeFile('fixture-body', body);
          await seed.putSetting('storage.autocompact.v1', '1');
          childKeys = await seed.exportSpaceKeys();
          await seed.close();
          expect(
            await seed.open(password: 'master-fixture', createIfMissing: true),
            isTrue,
          );
          await seed.saveRoster([
            RosterEntry(label: 'child-fixture', spaceKeys: childKeys),
          ]);
        } finally {
          await seed.close();
        }

        final storage = _Storage(path, gateKeys);
        final controller = _Controller();
        final c = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            singleSpaceStorageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            vpnBackendProvider.overrideWithValue(_Vpn()),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${dir.path}/runtime',
                storePath: path,
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(storage.close);
        c.read(appControllerProvider);
        controller.debugDeniableStackStarter = (_) async {
          throw StateError('fixture forbids native node boot');
        };
        final unlocking = controller.unlock('master-fixture');
        await storage.entered.future;
        try {
          await controller.lock();
        } finally {
          storage.release.complete();
          await unlocking;
        }
        expect(controller.debugMasterKeys, isNull);
        expect(controller.debugRoster, isNull);
        expect(storage.isOpen, isFalse);
        expect(c.read(appControllerProvider).phase, AppPhase.locked);
        for (final e in storage.returnedRoster!) {
          expect(e.spaceKeys.every((b) => b == 0), isTrue);
        }
        if (gateKeys) {
          expect(storage.returnedKeys!.every((b) => b == 0), isTrue);
        }

        Future<void> readOriginal(String expectedFlag) async {
          final reader = HiddenVolumeStorage.async(
            workerSpaceOpener(path),
            keysOpener: workerKeysSpaceOpener(path),
          );
          try {
            expect(await reader.open(password: 'master-fixture'), isTrue);
            final entry = (await reader.loadRoster())!.single;
            expect(
              entry.spaceKeys,
              childKeys,
              reason:
                  'wiping returned bytes must not corrupt the stored roster',
            );
            await reader.close();
            expect(await reader.openWithKeys(entry.spaceKeys), isTrue);
            expect(
              (await reader.loadProfile())!.displayName,
              'Native child fixture',
            );
            expect(await reader.loadFile('fixture-body'), body);
            expect(
              await reader.getSetting('storage.autocompact.v1'),
              expectedFlag,
            );
          } finally {
            await reader.close();
          }
        }

        await readOriginal('1');
        // The same controller's next authorized attempt must still perform the
        // complete migration and expose the master picker, not remain gated.
        await controller.unlock('master-fixture');
        expect(c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
        expect(controller.debugMasterKeys!.any((b) => b != 0), isTrue);
        expect(storage.isOpen, isFalse);
        await readOriginal('0');
        await controller.lock();
      },
      skip: library == null
          ? 'Set XVEIL_HV_DYLIB to a qualified library'
          : false,
    );
  }
}
