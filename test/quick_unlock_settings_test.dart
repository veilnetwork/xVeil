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
  @override
  Future<bool> authenticate(String reason) => answer.future;
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
