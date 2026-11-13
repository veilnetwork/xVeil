import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/lock/startup_quick_unlock.dart';
import 'package:xveil/features/onboarding/storage_protection_choice.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/storage_router_providers.dart';

Widget localized(Widget child) => MaterialApp(
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  home: Scaffold(body: child),
);

class _Locked extends AppController {
  final passwords = <String>[];
  @override
  AppState build() => const AppState(AppPhase.locked);
  @override
  Future<void> unlock(String password) async {
    passwords.add(password);
  }
}

class _Vault extends QuickUnlockVault {
  _Vault()
    : super(
        const QuickUnlockSecretStore(),
        'synthetic scope',
        LocalScreenAuthentication(),
      );
  final result = Completer<String?>();
  @override
  Future<String?> openSystem(String reason) => result.future;
}

void main() {
  testWidgets(
    'three storage choices default to encrypted and warn before plaintext',
    (tester) async {
      var selected = StorageProtection.defaultForNewIdentity;
      StorageProtection? continued;
      await tester.pumpWidget(
        localized(
          StatefulBuilder(
            builder: (context, update) => StorageProtectionChoice(
              selected: selected,
              onChanged: (value) => update(() => selected = value),
              onNext: () => continued = selected,
            ),
          ),
        ),
      );
      final l = AppL10n.of(
        tester.element(find.byType(StorageProtectionChoice)),
      );
      expect(selected, StorageProtection.encrypted);
      expect(find.text(l.storageEncryptedTitle), findsOneWidget);
      expect(find.text(l.storageHiddenTitle), findsOneWidget);
      expect(find.text(l.storageUnencryptedTitle), findsOneWidget);
      expect(find.text(l.storageUnencryptedWarning), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('storage-protection-unencrypted')),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.storageUnencryptedWarning), findsOneWidget);
      await tester.tap(find.text(l.actionContinue));
      expect(continued, StorageProtection.unencrypted);
      await tester.tap(
        find.byKey(const ValueKey('storage-protection-encrypted')),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.storageUnencryptedWarning), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in [false, true]) {
    testWidgets(
      'biometric answer belongs to its chosen storage; change=$change',
      (tester) async {
        final vault = _Vault();
        final app = _Locked();
        var locator = ManagedStorageLocator(
          id: ManagedIdentityId('a' * 32),
          protection: StorageProtection.encrypted,
        );
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appControllerProvider.overrideWith(() => app),
              quickUnlockVaultProvider.overrideWithValue(vault),
              startupUnlockOptionsProvider.overrideWith(
                (ref) async => const StartupUnlockOptions(system: true),
              ),
              storageAccessLocatorProvider.overrideWith((ref) {
                ref.watch(storageRouteRevisionProvider);
                return locator;
              }),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return localized(const StartupQuickUnlock());
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(StartupQuickUnlock)));
        await tester.tap(find.text(l.quickUnlockSystem));
        await tester.pump();
        if (change) {
          locator = ManagedStorageLocator(
            id: ManagedIdentityId('b' * 32),
            protection: StorageProtection.encrypted,
          );
          container.read(storageRouteRevisionProvider.notifier).state++;
        }
        vault.result.complete('synthetic password');
        await tester.pumpAndSettle();
        expect(app.passwords, change ? isEmpty : ['synthetic password']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
