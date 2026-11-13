@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/identity/manage_identities_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _Master extends AppController {
  ({String password, String label, IdentityStorageLocator locator})? bound;
  @override
  AppState build() => const AppState(
    AppPhase.ready,
    identities: ['synthetic child'],
    activeIdentity: 'synthetic child',
  );
  @override
  Future<bool> bindExistingIdentity({
    required String identityPassword,
    required String label,
    IdentityStorageLocator identityStorageLocator =
        const LegacyStorageLocator(),
  }) async {
    bound = (
      password: identityPassword,
      label: label,
      locator: identityStorageLocator,
    );
    return true;
  }
}

void main() {
  testWidgets(
    'bind dialog passes an explicit plaintext locator without a password',
    (tester) async {
      final fixture = Directory.systemTemp.createTempSync('xveil-bind-dialog-');
      ProfileStorageRouter? router;
      try {
        router = await tester.runAsync(() async {
          expect(ensureHiddenVolumeLoaded(), isTrue);
          final profile = '${fixture.path}/profile';
          expect(
            const ManagedFsPlatform().createPrivateDirectory(profile),
            isTrue,
          );
          final store = await ManagedWorkerIdentity.createUnencrypted(
            profileDirectory: profile,
            id: ManagedIdentityId('f' * 32),
          );
          await store.close();
          final masterStore = await ManagedWorkerIdentity.createUnencrypted(
            profileDirectory: profile,
            id: ManagedIdentityId('e' * 32),
          );
          await masterStore.close();
          final selected = await ProfileStorageRouter.open(
            profileDirectory: profile,
            legacyFactory: () => HiddenVolumeStorage(
              ({required password, required create}) => FakeKvLogStore(),
            ),
          );
          await selected.select(
            ManagedStorageLocator(
              id: ManagedIdentityId('e' * 32),
              protection: StorageProtection.unencrypted,
            ),
          );
          await selected.rememberAccess();
          return selected;
        });
        final master = _Master();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              appControllerProvider.overrideWith(() => master),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: ManageIdentitiesScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10n.of(
          tester.element(find.byType(ManageIdentitiesScreen)),
        );
        await tester.tap(find.widgetWithText(ListTile, l.manageBind));
        await tester.pumpAndSettle();
        expect(find.text(l.storagePlainMasterWarning), findsOneWidget);
        expect(find.text(l.manageBindPassword), findsOneWidget);
        await tester.tap(
          find.byType(DropdownButtonFormField<IdentityStorageLocator>),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('${l.storageUnencryptedTitle} · ffffffff').last,
        );
        await tester.pumpAndSettle();
        expect(find.text(l.manageBindPassword), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'synthetic link');
        await tester.tap(find.widgetWithText(FilledButton, l.manageBind));
        await tester.pumpAndSettle();
        expect(master.bound?.label, 'synthetic link');
        expect(master.bound?.password, '');
        expect(
          master.bound?.locator,
          router!.catalog.identities
              .singleWhere((entry) => entry.id.value == 'f' * 32)
              .locator,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (router != null) await tester.runAsync(router.close);
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
