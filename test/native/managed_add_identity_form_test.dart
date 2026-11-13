@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/identity/add_identity_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _App extends AppController {
  ({
    String childPassword,
    String masterPassword,
    StorageProtection? childMode,
    StorageProtection? masterMode,
  })?
  submitted;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<bool> addIdentity({
    required String masterPassword,
    required String label,
    required String password,
    String existingLabel = 'Identity 1',
    bool anonymous = false,
    StorageProtection? protection,
    StorageProtection? masterProtection,
  }) async {
    submitted = (
      childPassword: password,
      masterPassword: masterPassword,
      childMode: protection,
      masterMode: masterProtection,
    );
    return false; // Keep the form mounted; no node or route is launched.
  }
}

void main() {
  testWidgets(
    'new master and child default encrypted; plaintext is explicit and passwordless',
    (tester) async {
      final fixture = Directory.systemTemp.createTempSync('xveil-create-form-');
      ProfileStorageRouter? router;
      try {
        router = await tester.runAsync(() async {
          final profile = '${fixture.path}/profile';
          expect(
            const ManagedFsPlatform().createPrivateDirectory(profile),
            isTrue,
          );
          return ProfileStorageRouter.open(
            profileDirectory: profile,
            legacyFactory: () => HiddenVolumeStorage(
              ({required password, required create}) => FakeKvLogStore(),
            ),
          );
        });
        final app = _App();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              appControllerProvider.overrideWith(() => app),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: AddIdentityScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(AddIdentityScreen)));
        await tester.enterText(
          find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                w.decoration?.labelText == l.addIdentityCurrentName,
          ),
          'synthetic source',
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                w.decoration?.labelText == l.addIdentityNewName,
          ),
          'synthetic new',
        );
        final choices = find.byType(DropdownButtonFormField<StorageProtection>);
        expect(choices, findsNWidgets(2));
        for (var i = 0; i < 2; i++) {
          expect(
            tester
                .widget<DropdownButtonFormField<StorageProtection>>(
                  choices.at(i),
                )
                .initialValue,
            StorageProtection.encrypted,
          );
        }
        for (var i = 0; i < 2; i++) {
          await tester.ensureVisible(choices.at(i));
          await tester.tap(choices.at(i));
          await tester.pumpAndSettle();
          await tester.tap(find.text(l.storageUnencryptedTitle).last);
          await tester.pumpAndSettle();
        }
        expect(find.text(l.storageUnencryptedWarning), findsOneWidget);
        expect(find.text(l.storagePlainMasterWarning), findsOneWidget);
        // Controllers retain source/name text when ListView removes off-screen fields.
        final create = find.widgetWithText(FilledButton, l.addIdentityCreate);
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(app.submitted, (
          childPassword: '',
          masterPassword: '',
          childMode: StorageProtection.unencrypted,
          masterMode: StorageProtection.unencrypted,
        ));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (router != null) await tester.runAsync(router.close);
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
