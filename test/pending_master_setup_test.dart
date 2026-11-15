import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/data/node/bundled_seeds.dart'
    show kBundledSeedsSettingKey;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';
import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final hasRoster in [false, true]) {
    test(
      'pending erase cannot boot without a usable recovery route; roster=$hasRoster',
      () async {
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final storage = FakeHvContainer().storage();
        expect(
          await storage.open(
            password: 'synthetic erase parent',
            createIfMissing: true,
          ),
          isTrue,
        );
        if (hasRoster) {
          await storage.saveRoster([
            RosterEntry(label: 'child', spaceKeys: Uint8List(64)),
          ]);
        }
        await storage.putSetting(kPendingIdentityErase, '{}');
        await storage.close();
        final container = ProviderContainer(
          overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
        );
        try {
          final controller = container.read(appControllerProvider.notifier);
          await container.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          await controller.unlock('synthetic erase parent');
          expect(container.read(appControllerProvider).phase, AppPhase.locked);
          expect(container.read(appControllerProvider).unlockError, isTrue);
          expect(controller.debugRoster, isNull);
          expect(storage.isOpen, isFalse);
          expect(
            await storage.open(password: 'synthetic erase parent'),
            isTrue,
          );
          expect(await storage.getSetting(kPendingIdentityErase), '{}');
          expect(await storage.loadNodeConfig(), isNull);
        } finally {
          await storage.close();
          container.dispose();
        }
      },
    );
  }
  test(
    'a pending hidden master cannot silently become a new identity',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final fake = FakeHvContainer();
      final storage = fake.storage();
      expect(
        await storage.open(
          password: 'synthetic pending master',
          createIfMissing: true,
        ),
        isTrue,
      );
      await storage.putSetting(kPendingMasterSetupSetting, '1');
      await storage.close();
      final container = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
      );
      try {
        final controller = container.read(appControllerProvider.notifier);
        await container.read(prefsProvider.future);
        await Future<void>.delayed(Duration.zero);
        await controller.unlock('synthetic pending master');
        expect(
          container.read(appControllerProvider).phase,
          AppPhase.identitySetupRecovery,
        );
        expect(controller.canResumeIdentitySetup, isFalse);
        expect(controller.beginIdentitySetupRecovery(), isFalse);
        expect(storage.isOpen, isFalse);
        expect(
          await storage.open(password: 'synthetic pending master'),
          isTrue,
        );
        expect(await storage.loadNodeConfig(), isNull);
        expect(await storage.loadProfile(), isNull);
        expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
      } finally {
        await storage.close();
        container.dispose();
      }
    },
  );

  test(
    'a pending legacy master is rejected before all-online node boot',
    () async {
      final raw = FakeMultiSpaceBacking();
      final backing = SyncWrappedAsyncMultiSpaceBacking(raw);
      final keys = Uint8List(64)..fillRange(0, 64, 7);
      final id = await backing.openSpace(keys);
      final storage = HiddenVolumeStorage.fromAsyncStore(
        AsyncMultiSpaceKvLogStore(backing, id),
      );
      await storage.putSetting(kPendingMasterSetupSetting, '1');
      var boots = 0;
      final session = MultiIdentitySession(
        backing,
        runtimeDirBase: '/synthetic',
        listenPortBase: 19000,
        boot: (_, _) async {
          boots++;
          throw StateError('unexpected boot');
        },
      );
      try {
        await expectLater(
          session.bootAll([RosterEntry(label: 'pending', spaceKeys: keys)]),
          throwsStateError,
        );
        expect(boots, 0);
      } finally {
        await session.disposeAll();
        keys.fillRange(0, keys.length, 0);
      }
      expect(session.containerLockReleased, isTrue);
    },
  );

  for (final marker in ['1', 'future-stage']) {
    for (final withRoster in [true, false]) {
      test(
        'pending master cannot enter via existing ${withRoster ? 'roster' : 'profile'} ($marker)',
        () async {
          SharedPreferences.setMockInitialValues({'onboarded': true});
          final storage = FakeHvContainer().storage();
          expect(
            await storage.open(
              password: 'synthetic partial master',
              createIfMissing: true,
            ),
            isTrue,
          );
          if (withRoster) {
            await storage.saveRoster([
              RosterEntry(
                label: 'child',
                spaceKeys: Uint8List(64)..fillRange(0, 64, 7),
              ),
            ]);
          } else {
            await storage.saveProfile(
              const UserProfile(displayName: 'preserve me'),
            );
          }
          await storage.putSetting(kPendingMasterSetupSetting, marker);
          await storage.close();
          final c = ProviderContainer(
            overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
          );
          try {
            final controller = c.read(appControllerProvider.notifier);
            await c.read(prefsProvider.future);
            await Future<void>.delayed(Duration.zero);
            await controller.unlock('synthetic partial master');
            expect(
              c.read(appControllerProvider).phase,
              AppPhase.identitySetupRecovery,
            );
            expect(controller.canResumeIdentitySetup, isFalse);
            expect(controller.canReplayIdentitySetup, isFalse);
            expect(controller.debugRoster, isNull);
            expect(storage.isOpen, isFalse);
            expect(
              await storage.open(password: 'synthetic partial master'),
              isTrue,
            );
            expect(
              await storage.getSetting(kPendingMasterSetupSetting),
              marker,
            );
            if (withRoster) {
              final rows = (await storage.loadRoster())!;
              expect(rows.single.label, 'child');
              expect(rows.single.spaceKeys, Uint8List(64)..fillRange(0, 64, 7));
            } else {
              expect((await storage.loadProfile())!.displayName, 'preserve me');
            }
            expect(await storage.loadNodeConfig(), isNull);
          } finally {
            await storage.close();
            c.dispose();
          }
        },
      );
    }
  }

  test('unknown master stage cannot enter all-online boot', () async {
    final raw = FakeMultiSpaceBacking();
    final backing = SyncWrappedAsyncMultiSpaceBacking(raw);
    final keys = Uint8List(64)..fillRange(0, 64, 9);
    final id = await backing.openSpace(keys);
    final storage = HiddenVolumeStorage.fromAsyncStore(
      AsyncMultiSpaceKvLogStore(backing, id),
    );
    await storage.putSetting(kPendingMasterSetupSetting, 'future-stage');
    var boots = 0;
    final session = MultiIdentitySession(
      backing,
      runtimeDirBase: '/synthetic',
      listenPortBase: 19000,
      boot: (_, _) async {
        boots++;
        throw StateError('unexpected boot');
      },
    );
    try {
      final error = await session
          .bootAll([RosterEntry(label: 'pending', spaceKeys: keys)])
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(boots, 0);
      expect(error, isA<StateError>());
    } finally {
      await session.disposeAll();
      keys.fillRange(0, keys.length, 0);
    }
    expect(session.containerLockReleased, isTrue);
  });

  for (final marker in ['1', '2', 'future-stage']) {
    test(
      'planner rejects pending identity before posture writes ($marker)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final backing = SyncWrappedAsyncMultiSpaceBacking(
          FakeMultiSpaceBacking(),
        );
        final keys = Uint8List(64)..fillRange(0, 64, 4);
        final id = await backing.openSpace(keys);
        final storage = HiddenVolumeStorage.fromAsyncStore(
          AsyncMultiSpaceKvLogStore(backing, id),
        );
        await storage.saveProfile(
          const UserProfile(displayName: 'not finished'),
        );
        await storage.putSetting(kPendingIdentitySetupSetting, marker);
        expect(await storage.getSetting(kBundledSeedsSettingKey), isNull);
        try {
          await expectLater(
            planIdentityBoots(
              [RosterEntry(label: 'pending', spaceKeys: keys)],
              backing,
              runtimeDirBase: '/synthetic',
              listenPortBase: 19000,
              storageFor: (_) => storage,
              peersFor: (_) => const [],
              openEntry: (_) async => id,
            ),
            throwsStateError,
          );
          expect(await storage.getSetting(kBundledSeedsSettingKey), isNull);
          expect(
            await storage.getSetting(kPendingIdentitySetupSetting),
            marker,
          );
          expect((await storage.loadProfile())!.displayName, 'not finished');
          expect(await storage.loadNodeConfig(), isNull);
        } finally {
          await backing.close();
          keys.fillRange(0, keys.length, 0);
        }
      },
    );
  }
}
