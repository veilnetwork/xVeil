import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Controller extends AppController {
  _Controller({this.gateRemap = false});
  final bool gateRemap;
  final remapped = Completer<void>();
  final continueRemap = Completer<void>();
  final reopened = <String>[];
  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  Future<void> unlock(String password) async {
    reopened.add(password);
  }

  @override
  Future<List<String>> remapRostersAfterCompaction(
    List<({List<int> password, List<int> oldSpaceKeys})> credentials, {
    Storage? storageOverride,
  }) async {
    final stale = await super.remapRostersAfterCompaction(
      credentials,
      storageOverride: storageOverride,
    );
    if (gateRemap) {
      remapped.complete();
      await continueRemap.future;
    }
    return stale;
  }
}

class _ClosingStorage extends HiddenVolumeStorage {
  _ClosingStorage(super.opener);
  final closing = Completer<void>();
  final release = Completer<void>();
  bool _first = true;

  @override
  Future<void> close() async {
    if (_first) {
      _first = false;
      closing.complete();
      await release.future;
      throw StateError('fixture close failure');
    }
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final lockDuringClose in [false, true]) {
    test(
      'failed compaction reopens only its live session (lock=$lockDuringClose)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'xveil-compaction-lifecycle-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = File('${directory.path}/fixture.hv');
        final original = <int>[1, 2, 3, 4];
        await source.writeAsBytes(original, flush: true);
        // This path must refuse BEFORE native rewriting. Deliberately not a
        // valid native container: reaching FFI would be a fixture failure.
        final fake = FakeHvContainer();
        final storage = _ClosingStorage(fake.passwordOpener);
        await storage.open(password: 'fixture', createIfMissing: true);
        final controller = _Controller();
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            singleSpaceStorageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${directory.path}/runtime',
                storePath: source.path,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(appControllerProvider);
        final lease = controller.leaseIdentity();
        final roster = CompactionRoster()
          ..addUnlocked('fixture', passwordBytes: 'fixture'.codeUnits);
        final compacting = controller.compactStorageKeeping(
          roster: roster,
          reopenWith: 'fixture',
        );
        final refusal = expectLater(compacting, throwsStateError);
        await storage.closing.future;
        if (lockDuringClose) {
          await controller.lock();
          expect(container.read(appControllerProvider).phase, AppPhase.locked);
          expect(controller.holdsIdentity(lease), isFalse);
        }
        storage.release.complete();
        await refusal;
        expect(controller.reopened, lockDuringClose ? isEmpty : ['fixture']);
        expect(await source.readAsBytes(), original);
        await storage.close();
      },
    );
  }

  final library = Platform.environment['XVEIL_HV_DYLIB'];
  for (final lockAfterRewrite in [false, true]) {
    test(
      'native rewrite reopens only its live session (lock=$lockAfterRewrite)',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final directory = await Directory.systemTemp.createTemp(
          'xveil-compaction-native-lifecycle-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/fixture.hv';
        final passwords = ['hidden-fixture', 'open-fixture'];
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode(passwords.first)),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        final storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
        final roster = CompactionRoster();
        for (var i = 0; i < passwords.length; i++) {
          expect(
            await storage.open(password: passwords[i], createIfMissing: true),
            isTrue,
          );
          await storage.saveProfile(UserProfile(displayName: 'fixture-$i'));
          roster.addUnlocked(
            'fixture-$i',
            passwordBytes: utf8.encode(passwords[i]),
            spaceKeys: await storage.exportSpaceKeys(),
          );
          await storage.close();
        }
        final controller = _Controller(gateRemap: true);
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            singleSpaceStorageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${directory.path}/runtime',
                storePath: path,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(appControllerProvider);
        final compacting = controller.compactStorageKeeping(
          roster: roster,
          reopenWith: passwords.last,
        );
        final completion = lockAfterRewrite
            ? expectLater(compacting, throwsStateError)
            : expectLater(compacting, completes);
        await controller.remapped.future;
        if (lockAfterRewrite) await controller.lock();
        controller.continueRemap.complete();
        await completion;
        expect(
          controller.reopened,
          lockAfterRewrite ? isEmpty : [passwords.last],
        );
        if (lockAfterRewrite) {
          expect(container.read(appControllerProvider).phase, AppPhase.locked);
          expect(storage.isOpen, isFalse);
        }
        // A completed rewrite remains valid; this test changes only whether
        // the application is authorized to open it automatically afterwards.
        for (var i = 0; i < passwords.length; i++) {
          final reader = HiddenVolumeStorage.async(workerSpaceOpener(path));
          try {
            expect(await reader.open(password: passwords[i]), isTrue);
            expect((await reader.loadProfile())?.displayName, 'fixture-$i');
          } finally {
            await reader.close();
          }
        }
      },
      skip: library == null ? 'requires qualified XVEIL_HV_DYLIB' : false,
    );
  }
}
