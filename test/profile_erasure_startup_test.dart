import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/bootstrap/profile_erasure_pending_app.dart';
import 'package:xveil/features/bootstrap/storage_unavailable_app.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/main.dart' show applicationForBootstrap;
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';

void main() {
  for (final shipped in [false, true]) {
    for (final managed in [false, true]) {
      for (final ready in [false, true]) {
        testWidgets(
          'pending erase blocks ordinary startup: shipped=$shipped managed=$managed ready=$ready',
          (tester) async {
            var ordinaryReads = 0;
            final app = applicationForBootstrap(
              (
                overrides: [
                  appControllerProvider.overrideWith(() {
                    ordinaryReads++;
                    throw StateError('ordinary controller must not start');
                  }),
                  singleSpaceStorageProvider.overrideWith((ref) {
                    ordinaryReads++;
                    throw StateError('ordinary storage must not open');
                  }),
                  quickUnlockVaultProvider.overrideWith((ref) {
                    ordinaryReads++;
                    throw StateError('OS vault must not be read');
                  }),
                ],
                secureStorageReady: ready,
                managedErasurePending: true,
              ),
              shipped: shipped,
              managedStorage: managed,
            );
            expect(app, isA<ProfileErasurePendingApp>());
            await tester.pumpWidget(app);
            expect(find.byType(Scaffold), findsOneWidget);
            expect(find.byType(ProviderScope), findsNothing);
            final l = AppL10n.of(tester.element(find.byType(Scaffold)));
            expect(find.text(l.profileErasurePendingTitle), findsOneWidget);
            expect(find.text(l.profileErasurePendingBody), findsOneWidget);
            expect(ordinaryReads, 0);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  test('managed debug startup cannot silently use the in-memory fallback', () {
    const boot = (
      overrides: <Never>[],
      secureStorageReady: false,
      managedErasurePending: false,
    );
    expect(
      applicationForBootstrap(boot, shipped: false, managedStorage: true),
      isA<StorageUnavailableApp>(),
    );
    expect(
      applicationForBootstrap(boot, shipped: false, managedStorage: false),
      isA<ProviderScope>(),
    );
  });
  for (final locale in AppL10n.supportedLocales) {
    testWidgets(
      'pending erasure message is localized for ${locale.languageCode}',
      (tester) async {
        await tester.binding.setLocale(
          locale.languageCode,
          locale.countryCode ?? '',
        );
        addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
        await tester.pumpWidget(const ProfileErasurePendingApp());
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(Scaffold)));
        expect(find.text(l.profileErasurePendingTitle), findsOneWidget);
        expect(find.text(l.profileErasurePendingBody), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
