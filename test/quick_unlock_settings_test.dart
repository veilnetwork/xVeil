import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/settings/quick_unlock_screen.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/features/lock/pattern_pad.dart';
import 'package:xveil/features/lock/screen_lock_overlay.dart';
import 'package:xveil/domain/screen_lock.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';
import 'package:xveil/state/startup_unlock.dart';

import 'support/fake_setting_storage.dart';

class _Storage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
}

class _App extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );
}

class _Auth extends LocalScreenAuthentication {
  final answer = Completer<bool>();
  int requests = 0;
  @override
  Future<bool> authenticate(String reason) {
    requests++;
    return answer.future;
  }
}

class _Vault extends QuickUnlockVault {
  _Vault()
    : super(
        const QuickUnlockSecretStore(),
        'fixture',
        LocalScreenAuthentication(),
      );
  String? saved;
  @override
  Future<String?> openPattern(List<int> nodes) async =>
      nodes.join(',') == '0,1,4,8' ? 'confirmed password' : null;
  @override
  Future<void> configure({
    required String password,
    int? grid,
    List<int>? nodes,
    required bool system,
    bool Function()? stillCurrent,
  }) async {
    if (stillCurrent?.call() == false) throw StateError('stale form');
    saved = password;
  }
}

class _MemoryStore extends QuickUnlockSecretStore {
  final values = <String, String>{};
  String _slot(String key, bool biometric) => '$biometric:$key';
  @override
  Future<String?> read(String key, {bool biometric = false}) async =>
      values[_slot(key, biometric)];
  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    values[_slot(key, biometric)] = value;
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    values.remove(_slot(key, biometric));
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) async =>
      values.containsKey(_slot(key, biometric));
  @override
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) async => await authentication.authenticate(reason)
      ? read(key, biometric: true)
      : null;
}

class _LockedApp extends AppController {
  String? opened;
  @override
  AppState build() => const AppState(AppPhase.locked);
  @override
  Future<void> unlock(String password) async {
    opened = password;
  }
}

void main() {
  testWidgets('cold startup shows biometric entry without any pattern', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({kStartupUnlockOptIn: true});
    final store = _MemoryStore(), auth = _Auth()..answer.complete(true);
    await QuickUnlockVault(
      store,
      'system-only',
      auth,
    ).configure(password: 'confirmed password', system: true);
    // Reconstruct the vault and provider graph, with persisted metadata only.
    final restarted = QuickUnlockVault(store, 'system-only', auth);
    final app = _LockedApp();
    final c = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => app),
        quickUnlockVaultProvider.overrideWithValue(restarted),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));
    final button = find.text(l.quickUnlockSystem);
    expect(button.hitTestable(), findsOneWidget);
    expect(find.byType(PatternPad), findsNothing);
    expect(auth.requests, 0);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(auth.requests, 1);
    expect(app.opened, 'confirmed password');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'screen cover keeps biometric entry after reload without a pattern',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final auth = _Auth()..answer.complete(true);
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(_Storage()),
          appControllerProvider.overrideWith(_App.new),
          localScreenAuthenticationProvider.overrideWithValue(auth),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(screenLockProvider.notifier);
      await controller.reloadTimeout();
      controller.rememberPassword('confirmed password');
      await controller.setTimeout(ScreenLockTimeout.immediately);
      expect(
        await controller.configureQuickUnlock(
          password: 'confirmed password',
          system: true,
          reason: 'fixture',
        ),
        isTrue,
      );
      controller.forgetSession();
      await controller.reloadTimeout();
      controller.rememberPassword('confirmed password');
      controller.onLeftForeground();
      expect(c.read(screenLockProvider).locked, isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Scaffold(body: ScreenLockCover()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(ScreenLockCover)));
      expect(find.byType(PatternPad), findsNothing);
      final requests = auth.requests;
      final button = find.text(l.quickUnlockSystem);
      expect(button.hitTestable(), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(auth.requests, requests + 1);
      expect(c.read(screenLockProvider).locked, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final system in [false, true]) {
    testWidgets('startup with an existing screen pattern; biometrics=$system', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = _Auth()..answer.complete(true);
      final vault = QuickUnlockVault(
        _MemoryStore(),
        'biometric-only-fixture',
        auth,
      );
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(_Storage()),
          appControllerProvider.overrideWith(_App.new),
          localScreenAuthenticationProvider.overrideWithValue(auth),
          localScreenAuthenticationAvailableProvider.overrideWith(
            (ref) async => true,
          ),
          quickUnlockVaultProvider.overrideWithValue(vault),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(screenLockProvider.notifier);
      await controller.reloadTimeout();
      controller.rememberPassword('confirmed password');
      expect(
        await controller.configureQuickUnlock(
          password: 'confirmed password',
          grid: 3,
          nodes: [0, 1, 4, 8],
          system: false,
          reason: 'fixture',
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
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(QuickUnlockScreen)));
      await tester.tap(find.text(l.startupUnlockTitle));
      await tester.pump();
      if (system) {
        await tester.scrollUntilVisible(
          find.text(l.quickUnlockSystem),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(l.quickUnlockSystem));
        await tester.pump();
      }
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'confirmed password');
      await tester.scrollUntilVisible(
        find.text(l.actionSave),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(l.actionSave));
      await tester.pumpAndSettle();
      if (!system) {
        expect(find.text(l.startupUnlockSaveFailed), findsOneWidget);
        expect((await vault.options()).enabled, isFalse);
        expect(c.read(screenLockProvider).patternGrid, 3);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      expect(
        find.text('open'),
        findsOneWidget,
        reason:
            'enrolling biometrics must not fail for lack of the old pattern',
      );
      expect(c.read(screenLockProvider).patternGrid, 3);
      final startup = await vault.options();
      expect(startup.system, isTrue);
      expect(
        startup.grid,
        isNull,
        reason: 'an unconfirmed pattern must not be enrolled for startup',
      );
      expect(await vault.openSystem('fixture'), 'confirmed password');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'startup pattern is usable inside the actual scrollable password screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final app = _LockedApp();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => app),
          quickUnlockVaultProvider.overrideWithValue(_Vault()),
          startupUnlockOptionsProvider.overrideWith(
            (ref) async => const StartupUnlockOptions(grid: 3),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: LockScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(LockScreen)));
      await tester.ensureVisible(find.text(l.quickUnlockPattern));
      await tester.tap(find.text(l.quickUnlockPattern));
      await tester.pumpAndSettle();
      for (final node in [0, 1, 4, 8]) {
        final dot = find.byKey(ValueKey('pattern-node-$node'));
        await tester.ensureVisible(dot);
        await tester.tap(dot);
        await tester.pump();
      }
      await tester.ensureVisible(find.text(l.quickUnlockWithPattern));
      await tester.tap(find.text(l.quickUnlockWithPattern));
      await tester.pumpAndSettle();
      expect(app.opened, 'confirmed password');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an OS prompt cannot change the password saved after confirmation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final auth = _Auth(), vault = _Vault();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(_Storage()),
          appControllerProvider.overrideWith(_App.new),
          localScreenAuthenticationProvider.overrideWithValue(auth),
          localScreenAuthenticationAvailableProvider.overrideWith(
            (ref) async => true,
          ),
          quickUnlockVaultProvider.overrideWithValue(vault),
          startupUnlockOptionsProvider.overrideWith(
            (ref) async => const StartupUnlockOptions(),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(screenLockProvider.notifier).reloadTimeout();
      c
          .read(screenLockProvider.notifier)
          .rememberPassword('confirmed password');
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
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(QuickUnlockScreen)));
      await tester.tap(find.text(l.startupUnlockTitle));
      await tester.pump();
      await tester.ensureVisible(find.text(l.quickUnlockSystem));
      await tester.tap(find.text(l.quickUnlockSystem));
      await tester.pump();
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'confirmed password');
      await tester.ensureVisible(find.text(l.actionSave));
      await tester.tap(find.text(l.actionSave));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      // A late IME/autofill write is independent of whether the form accepts
      // gestures. Only the password actually confirmed may reach the OS store.
      field.controller!.text = 'late unconfirmed value';
      auth.answer.complete(true);
      await tester.pumpAndSettle();
      expect(vault.saved, 'confirmed password');
      expect(find.text('open'), findsOneWidget);
    },
  );
}
