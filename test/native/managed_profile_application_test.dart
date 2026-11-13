@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/features/lock/startup_quick_unlock.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _Node implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

class _LockedApplication extends AppController {
  final passwords = <String>[];
  @override
  AppState build() => const AppState(AppPhase.locked);
  @override
  Future<void> unlock(String password) async => passwords.add(password);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late String profile;
  final routers = <ProfileStorageRouter>[];
  final containers = <ProviderContainer>[];
  Future<ProfileStorageRouter> openRouter() async {
    final router = await ProfileStorageRouter.open(
      profileDirectory: profile,
      legacyFactory: () => HiddenVolumeStorage(
        ({required password, required create}) => FakeKvLogStore(),
      ),
    );
    routers.add(router);
    return router;
  }

  Future<ProviderContainer> app(ProfileStorageRouter router) async {
    final container = ProviderContainer(
      overrides: [
        profileStorageRouterProvider.overrideWithValue(router),
        singleSpaceStorageProvider.overrideWith((ref) {
          ref.watch(storageRouteRevisionProvider);
          return router.storage;
        }),
        nodeControllerProvider.overrideWithValue(_Node()),
      ],
    );
    containers.add(container);
    container.read(appControllerProvider);
    await container.read(prefsProvider.future);
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    SharedPreferences.setMockInitialValues({});
    fixture = Directory.systemTemp.createTempSync('xveil-app-storage-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final container in containers.reversed) {
      container.dispose();
    }
    for (final router in routers.reversed) {
      await router.close();
    }
    containers.clear();
    routers.clear();
    fixture.deleteSync(recursive: true);
  });

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      'application onboarding and cold unlock use actual ${mode.name} storage',
      () async {
        final router = await openRouter();
        final container = await app(router);
        expect(
          container.read(appControllerProvider).phase,
          AppPhase.onboarding,
        );
        final controller = container.read(appControllerProvider.notifier);
        await controller.completeOnboarding(
          password: mode == StorageProtection.encrypted
              ? 'synthetic password'
              : '',
          mode: StorageMode.plain,
          protection: mode,
          displayName: 'synthetic profile',
        );
        expect(container.read(appControllerProvider).phase, AppPhase.ready);
        final locator = router.location as ManagedStorageLocator;
        expect(locator.protection, mode);
        expect(router.catalog.selected, locator);
        expect(await controller.containerSizeBytes(), greaterThan(0));
        expect(await router.storage.loadProfile(), isNotNull);
        expect(
          (await router.storage.loadProfile())!.displayName,
          'synthetic profile',
        );
        expect(
          (await container.read(
            prefsProvider.future,
          )).getString('storage_mode'),
          isNull,
          reason: 'legacy visibility flag must not mislabel a managed backend',
        );
        await router.storage.putSetting('roundtrip', mode.name);
        await controller.lock();
        await router.close();
        container.dispose();
        containers.remove(container);
        SharedPreferences.setMockInitialValues({});
        final coldRouter = await openRouter();
        final cold = await app(coldRouter);
        expect(
          cold.read(appControllerProvider).phase,
          AppPhase.locked,
          reason: 'catalog survives loss of soft onboarding preferences',
        );
        expect(coldRouter.access, locator);
        final coldController = cold.read(appControllerProvider.notifier);
        if (mode == StorageProtection.encrypted) {
          await coldController.unlock('incorrect password');
          expect(cold.read(appControllerProvider).phase, AppPhase.locked);
        }
        await coldController.unlock(
          mode == StorageProtection.encrypted ? 'synthetic password' : '',
        );
        expect(cold.read(appControllerProvider).phase, AppPhase.ready);
        expect(await coldRouter.storage.getSetting('roundtrip'), mode.name);
        await coldController.lock();
      },
    );
  }

  test('controller selections isolate two visible identities', () async {
    final router = await openRouter();
    final locations = <IdentityStorageLocator>[];
    for (final mode in [
      StorageProtection.encrypted,
      StorageProtection.unencrypted,
    ]) {
      await router.create(mode);
      locations.add(router.location);
      expect(
        await router.storage.open(
          password: 'synthetic password',
          createIfMissing: true,
        ),
        isTrue,
      );
      await router.storage.saveProfile(UserProfile(displayName: mode.name));
      await router.storage.putSetting('owner', mode.name);
      await router.rememberAccess();
    }
    await router.storage.close();
    final container = await app(router);
    final controller = container.read(appControllerProvider.notifier);
    expect(await controller.selectStorageIdentity(locations.first), isTrue);
    expect(container.read(storageAccessLocatorProvider), locations.first);
    expect(identical(container.read(storageProvider), router.storage), isTrue);
    await controller.unlock('synthetic password');
    expect(container.read(appControllerProvider).phase, AppPhase.ready);
    expect(await router.storage.getSetting('owner'), 'encrypted');
    expect(
      await controller.selectStorageIdentity(locations.last),
      isFalse,
      reason: 'the lock-screen selector cannot replace an active session',
    );
    await controller.lock();
    final retired = router.storage;
    expect(await controller.selectStorageIdentity(locations.last), isTrue);
    expect(retired.isOpen, isFalse);
    expect(container.read(storageAccessLocatorProvider), locations.last);
    await controller.unlock('');
    expect(container.read(appControllerProvider).phase, AppPhase.ready);
    expect(await router.storage.getSetting('owner'), 'unencrypted');
    await controller.lock();
  });

  test(
    'an incomplete visible store cannot become a new identity on unlock',
    () async {
      final router = await openRouter();
      await router.create(StorageProtection.unencrypted);
      expect(
        await router.storage.open(password: '', createIfMissing: true),
        isTrue,
      );
      await router.rememberAccess();
      await router.storage.close();
      final container = await app(router);
      await container.read(appControllerProvider.notifier).unlock('');
      expect(
        container.read(appControllerProvider).phase,
        AppPhase.identityDamaged,
      );
      expect(router.storage.isOpen, isFalse);
      expect(await router.storage.open(password: ''), isTrue);
      expect(await router.storage.loadProfile(), isNull);
      expect(await router.storage.loadNodeConfig(), isNull);
    },
  );
  for (final remembered in [true, false]) {
    testWidgets(
      'managed lock chooser and explicit plaintext entry; remembered=$remembered',
      (tester) async {
        final router = (await tester.runAsync(() async {
          final live = await openRouter();
          await live.create(StorageProtection.unencrypted);
          expect(
            await live.storage.open(password: '', createIfMissing: true),
            isTrue,
          );
          await live.storage.saveProfile(
            const UserProfile(displayName: 'synthetic'),
          );
          await live.rememberAccess();
          if (!remembered) {
            await live.select(const LegacyStorageLocator());
            await live.rememberAccess();
          }
          await live.close();
          return openRouter();
        }))!;
        final app = _LockedApplication();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              appControllerProvider.overrideWith(() => app),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(LockScreen)));
        expect(
          find.byType(DropdownButtonFormField<IdentityStorageLocator>),
          findsOneWidget,
        );
        expect(find.byType(StartupQuickUnlock), findsNothing);
        expect(
          find.text(l.lockWipe),
          findsNothing,
          reason:
              'legacy whole-container wipe is unavailable in QA mixed storage',
        );
        if (remembered) {
          expect(find.byType(TextField), findsNothing);
          await tester.tap(
            find.widgetWithText(FilledButton, l.storageOpenPlain),
          );
          await tester.pumpAndSettle();
          expect(app.passwords, ['']);
        } else {
          final open = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, l.lockUnlock),
          );
          expect(open.onPressed, isNull);
          expect(app.passwords, isEmpty);
        }
        await tester.tap(
          find.byType(DropdownButtonFormField<IdentityStorageLocator>),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(l.storageHiddenTitle),
          findsWidgets,
          reason: 'the hidden option is offered without probing hidden spaces',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(router.close);
      },
    );
  }
}
