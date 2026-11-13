import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/features/common/help_label.dart';
import 'package:xveil/features/identity/decoy_master_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _UnusedStorage implements Storage {
  @override
  bool get isOpen => false;
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unused fixture storage');
}

class _Controller extends AppController {
  List<String>? selected;
  @override
  AppState build() =>
      const AppState(AppPhase.ready, identities: ['safe', 'excluded']);
  @override
  Future<bool> createDecoyMaster({
    required String duressPassword,
    required List<String> includeLabels,
  }) async {
    selected = List.of(includeLabels);
    return false;
  }
}

void main() {
  for (final language in ['ru', 'en', 'es']) {
    testWidgets('mixed-storage help fits large text in $language', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final temporary = Directory.systemTemp.createTempSync('xveil-decoy-ui-');
      final profile = '${temporary.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      final router = (await tester.runAsync(
        () => ProfileStorageRouter.open(
          profileDirectory: profile,
          legacyFactory: _UnusedStorage.new,
        ),
      ))!;
      final container = ProviderContainer(
        overrides: [
          profileStorageRouterProvider.overrideWithValue(router),
          appControllerProvider.overrideWith(_Controller.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await tester.runAsync(() async {
          await router.close();
          temporary.deleteSync(recursive: true);
        });
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2.5)),
              child: child!,
            ),
            home: const DecoyMasterScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(HelpLabel),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(HelpLabel), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.help_outline).hitTestable(), findsOneWidget);
      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final l = AppL10n.of(tester.element(find.byType(AlertDialog)));
      expect(find.text(l.decoyStorageHint), findsOneWidget);
      expect(l.decoyStorageHint, contains(l.storageHiddenTitle));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'submits only explicit selection and reports an ordinary refusal',
    (tester) async {
      final controller = _Controller();
      final container = ProviderContainer(
        overrides: [appControllerProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const DecoyMasterScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(HelpLabel),
        findsNothing,
      ); // No storage selector in the legacy app.
      await tester.enterText(find.byType(TextField), 'synthetic duress');
      final safe = find.widgetWithText(CheckboxListTile, 'safe');
      await tester.ensureVisible(safe);
      await tester.tap(safe);
      await tester.pump();
      final submit = find.byType(FilledButton);
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(controller.selected, ['safe']);
      expect(
        find.text(AppL10n.of(tester.element(submit)).decoyClash),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
