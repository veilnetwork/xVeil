import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _Controller extends AppController {
  int wipes = 0;
  @override
  AppState build() => const AppState(AppPhase.locked);
  @override
  Future<List<String>> wipeContainers() async {
    wipes++;
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late ProfileStorageRouter router;
  late ProfileStorageRouterOwner owner;

  Future<void> openProfile(String profile, {required bool populated}) async {
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      if (populated) {
        ManagedIdentityFiles.createUnencrypted(
          root,
          id: ManagedIdentityId('3' * 32),
        ).close();
      }
    } finally {
      root.close();
    }
    HiddenVolumeStorage storage() => HiddenVolumeStorage(
      ({required password, required create}) => FakeKvLogStore(),
    );
    router = await ProfileStorageRouter.open(
      profileDirectory: profile,
      legacyFactory: storage,
      storageFactory: (_, _) => storage(),
    );
    expect(router.catalog.identities, hasLength(populated ? 1 : 0));
    owner = ProfileStorageRouterOwner(
      router,
      reopen: () => throw StateError('unexpected test reopen'),
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'onboarded': true});
    fixture = Directory.systemTemp.createTempSync('xveil-lock-wipe-');
    await openProfile('${fixture.path}/profile', populated: true);
  });
  tearDown(() async {
    await owner.close();
    fixture.deleteSync(recursive: true);
  });

  Future<_Controller> mount(
    WidgetTester tester, {
    required bool owned,
    bool populated = true,
  }) async {
    if (!populated) {
      await tester.runAsync(() async {
        await owner.close();
        await openProfile('${fixture.path}/empty', populated: false);
      });
    }
    final controller = _Controller();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(() => controller),
          if (owned)
            profileStorageRouterOwnerProvider.overrideWithValue(owner)
          else
            profileStorageRouterProvider.overrideWithValue(router),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          builder: (_, child) =>
              Stack(children: [child!, const WipeReportHost()]),
          home: const LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  for (final viaStartOver in [false, true]) {
    testWidgets('owned visible catalog can request whole-profile wipe '
        '(start-over=$viaStartOver)', (tester) async {
      final controller = await mount(tester, owned: true);
      final l = AppL10n.of(tester.element(find.byType(LockScreen)));
      if (viaStartOver) {
        await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
        await tester.pumpAndSettle();
      }
      final wipe = find.text(l.lockWipe).hitTestable();
      expect(wipe, findsOneWidget);
      await tester.tap(wipe);
      await tester.pumpAndSettle();
      expect(find.text(l.profileWipeBody), findsOneWidget);
      expect(find.text(l.lockWipeBody), findsNothing);
      final confirm = find.widgetWithText(FilledButton, l.lockWipeConfirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final input = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'wrong phrase');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(controller.wipes, 0);
      await tester.tap(find.widgetWithText(TextButton, l.actionCancel));
      await tester.pumpAndSettle();
      expect(controller.wipes, 0);
      // Reopen through the direct action and require a fresh exact phrase.
      await tester.tap(find.text(l.lockWipe).hitTestable());
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(input, l.lockWipePhrase);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(controller.wipes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final populated in [false, true]) {
    testWidgets(
      'catalog without owned erasure stays unavailable (populated=$populated)',
      (tester) async {
        final controller = await mount(
          tester,
          owned: false,
          populated: populated,
        );
        final l = AppL10n.of(tester.element(find.byType(LockScreen)));
        expect(find.text(l.lockWipe), findsNothing);
        await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
        await tester.pumpAndSettle();
        expect(find.text(l.lockWipe), findsNothing);
        expect(controller.wipes, 0);
        await tester.tap(find.widgetWithText(TextButton, l.actionCancel));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
