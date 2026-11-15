import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/settings/quick_unlock_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/storage_router_providers.dart';

import 'support/fake_setting_storage.dart';
import 'support/retirement_secret_store.dart';

class _Storage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
  @override
  Future<void> close() async {}
}

class _App extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );
}

class _LockedApp extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _ConsentStore extends InMemorySharedPreferencesStore {
  _ConsentStore() : super.empty();
  String? refuse;
  bool throwRefusal = false;
  Completer<void>? entered, release;
  final writes = <String>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    if (release != null) {
      entered?.complete();
      final gate = release!;
      release = null;
      await gate.future;
    }
    if (key == refuse) {
      if (throwRefusal) throw StateError('synthetic preference write failure');
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  for (final enable in [false, true]) {
    testWidgets('changing managed A consent preserves B (enable=$enable)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        if (!enable) kStartupUnlockOptIn: true,
      });
      final auth = RetirementAuthentication(), store = RetirementSecretStore();
      final a = ManagedStorageLocator(
        id: ManagedIdentityId('1' * 32),
        protection: StorageProtection.encrypted,
      );
      final b = ManagedStorageLocator(
        id: ManagedIdentityId('2' * 32),
        protection: StorageProtection.encrypted,
      );
      final first = QuickUnlockVault(store, 'synthetic-managed-a', auth);
      final second = QuickUnlockVault(store, 'synthetic-managed-b', auth);
      if (!enable) {
        await first.configure(password: 'confirmed password', system: true);
      }
      await second.configure(password: 'other password', system: true);
      final before = Map.of(store.values);
      final foreign = before.entries
          .where((entry) => entry.key.contains('synthetic-managed-b'))
          .toList();
      expect(foreign, isNotEmpty);
      IdentityStorageLocator active = a;
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(_Storage()),
          appControllerProvider.overrideWith(_App.new),
          localScreenAuthenticationProvider.overrideWithValue(auth),
          localScreenAuthenticationAvailableProvider.overrideWith(
            (ref) async => true,
          ),
          storageAccessLocatorProvider.overrideWith((ref) => active),
          quickUnlockVaultProvider.overrideWith(
            (ref) =>
                ref.watch(storageAccessLocatorProvider) == a ? first : second,
          ),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(screenLockProvider.notifier);
      await controller.reloadTimeout();
      controller.rememberPassword('confirmed password');
      expect(
        await controller.configureQuickUnlock(
          password: 'confirmed password',
          system: true,
          reason: 'synthetic test',
        ),
        isTrue,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const QuickUnlockScreen(),
                    ),
                  ),
                  child: const Text('open fixture'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open fixture'));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(QuickUnlockScreen)));
      await tester.tap(find.text(l.startupUnlockTitle));
      await tester.pump();
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'confirmed password');
      await tester.ensureVisible(find.text(l.actionSave));
      await tester.tap(find.text(l.actionSave));
      await tester.pumpAndSettle();
      expect(find.text('open fixture'), findsOneWidget);
      expect(
        (await c.read(startupUnlockOptionsProvider.future)).enabled,
        enable,
      );
      active = b;
      c.invalidate(storageAccessLocatorProvider);
      expect(
        (await c.read(startupUnlockOptionsProvider.future)).system,
        !enable,
        reason: 'A must not change whether B is offered its saved entry',
      );
      expect(await second.openSystem('synthetic test'), 'other password');
      for (final entry in foreign) {
        expect(store.values[entry.key], entry.value);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  final a = ManagedStorageLocator(
    id: ManagedIdentityId('a' * 32),
    protection: StorageProtection.encrypted,
  );
  final b = ManagedStorageLocator(
    id: ManagedIdentityId('b' * 32),
    protection: StorageProtection.encrypted,
  );
  const legacy = LegacyStorageLocator();

  test('start over removes only the selected managed saved entry', () async {
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      kStartupUnlockOptIn: true,
    });
    final store = RetirementSecretStore(), auth = RetirementAuthentication();
    final first = QuickUnlockVault(store, 'synthetic-start-over-a', auth);
    final second = QuickUnlockVault(store, 'synthetic-start-over-b', auth);
    await first.configure(password: 'first password', system: true);
    await second.configure(password: 'second password', system: true);
    IdentityStorageLocator active = a;
    final c = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_LockedApp.new),
        storageProvider.overrideWithValue(_Storage()),
        storageAccessLocatorProvider.overrideWith((ref) => active),
        quickUnlockVaultProvider.overrideWith(
          (ref) =>
              ref.watch(storageAccessLocatorProvider) == a ? first : second,
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(appControllerProvider.notifier).startOver();
    expect((await first.options()).enabled, isFalse);
    expect(
      (await c.read(startupUnlockOptionsProvider.future)).enabled,
      isFalse,
    );
    active = b;
    c.invalidate(storageAccessLocatorProvider);
    expect((await c.read(startupUnlockOptionsProvider.future)).system, isTrue);
    expect(await second.openSystem('synthetic test'), 'second password');
  });

  test(
    'clearing legacy consent preserves old enrollments and explicit denial',
    () async {
      SharedPreferences.setMockInitialValues({kStartupUnlockOptIn: true});
      final prefs = await SharedPreferences.getInstance();
      expect(startupUnlockConsented(prefs, a), isTrue);
      expect(await clearStartupUnlockConsent(prefs, a), isTrue);
      expect(
        await clearStartupUnlockConsent(prefs, legacy, managedSiblings: [a, b]),
        isTrue,
      );
      expect(prefs.getBool(kStartupUnlockOptIn), isNull);
      expect(startupUnlockConsented(prefs, a), isFalse);
      expect(startupUnlockConsented(prefs, b), isTrue);
      expect(startupUnlockConsented(prefs, legacy), isFalse);
    },
  );

  test(
    'new legacy enrollment does not authorize existing unrelated records',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(
        await setStartupUnlockConsent(prefs, legacy, managedSiblings: [a, b]),
        isTrue,
      );
      expect(startupUnlockConsented(prefs, legacy), isTrue);
      expect(startupUnlockConsented(prefs, a), isFalse);
      expect(startupUnlockConsented(prefs, b), isFalse);
    },
  );

  test(
    'failed inheritance keeps historical consent and permits exact retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final original = SharedPreferencesStorePlatform.instance;
      final store = _ConsentStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final prefs = await SharedPreferences.getInstance();
      expect(await prefs.setBool(kStartupUnlockOptIn, true), isTrue);
      final refused = 'flutter.${startupUnlockConsentKey(b)}';
      store.refuse = refused;
      expect(
        await clearStartupUnlockConsent(prefs, legacy, managedSiblings: [a, b]),
        isFalse,
      );
      expect((await store.getAll())['flutter.$kStartupUnlockOptIn'], isTrue);
      // A new cache models recovery from disk, not the optimistic failed setter.
      await prefs.reload();
      store.refuse = null;
      expect(
        await clearStartupUnlockConsent(prefs, legacy, managedSiblings: [a, b]),
        isTrue,
      );
      expect(startupUnlockConsented(prefs, a), isTrue);
      expect(startupUnlockConsented(prefs, b), isTrue);
      expect(
        (await store.getAll()).containsKey('flutter.$kStartupUnlockOptIn'),
        isFalse,
      );
    },
  );

  test(
    'legacy migration joins earlier consent work before a later explicit choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final original = SharedPreferencesStorePlatform.instance;
      final store = _ConsentStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final prefs = await SharedPreferences.getInstance();
      store.entered = Completer<void>();
      final release = store.release = Completer<void>();
      final migrate = setStartupUnlockConsent(
        prefs,
        legacy,
        managedSiblings: [a, b],
      );
      await store.entered!.future;
      final explicit = setStartupUnlockConsent(prefs, b);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, hasLength(1));
      release.complete();
      expect(await migrate, isTrue);
      expect(await explicit, isTrue);
      await prefs.reload();
      expect(startupUnlockConsented(prefs, a), isFalse);
      expect(startupUnlockConsented(prefs, b), isTrue);
      expect(startupUnlockConsented(prefs, legacy), isTrue);
    },
  );

  test(
    'an exceptional consent write does not strand the following choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final original = SharedPreferencesStorePlatform.instance;
      final store = _ConsentStore()
        ..refuse = 'flutter.${startupUnlockConsentKey(a)}'
        ..throwRefusal = true;
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final prefs = await SharedPreferences.getInstance();
      final failed = setStartupUnlockConsent(prefs, a);
      final following = setStartupUnlockConsent(prefs, b);
      await expectLater(failed, throwsStateError);
      expect(await following, isTrue);
      await prefs.reload();
      expect(startupUnlockConsented(prefs, a), isFalse);
      expect(startupUnlockConsented(prefs, b), isTrue);
    },
  );
}
