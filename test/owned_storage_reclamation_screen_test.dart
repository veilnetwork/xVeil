import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/settings/storage_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'support/fake_hv_container.dart';

class _Controller extends AppController {
  final release = Completer<void>();
  int calls = 0;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  bool get usesManagedStorage => true;
  @override
  bool get canReclaimOwnedStorage => true;
  @override
  Future<void> reclaimOwnedStorage() async {
    calls++;
    await release.future;
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  for (final locale in ['en', 'ru', 'es']) {
    for (final outcome in ['success', 'failure', 'unmounted']) {
      testWidgets('owned maintenance controls $locale $outcome', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(430, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'synthetic', createIfMissing: true);
        final ctrl = _Controller();
        final app = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => ctrl),
            singleSpaceStorageProvider.overrideWithValue(storage),
          ],
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: app,
              child: MaterialApp(
                locale: Locale(locale),
                localizationsDelegates: AppL10n.localizationsDelegates,
                supportedLocales: AppL10n.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child!,
                ),
                home: const StorageSettingsScreen(),
              ),
            ),
          );
          await frames(tester);
          final target = find.byKey(const Key('owned-storage-reclaim'));
          await tester.scrollUntilVisible(
            target,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await frames(tester);
          final l = AppL10n.of(tester.element(target));
          expect(find.text(l.storageOwnedReclaim), findsOneWidget);
          await tester.tap(target);
          await frames(tester);
          expect(ctrl.calls, 1);
          expect(tester.widget<ListTile>(target).onTap, isNull);
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          if (outcome == 'unmounted') {
            await tester.pumpWidget(const SizedBox());
          }
          if (outcome == 'failure') {
            ctrl.release.completeError(StateError('synthetic private refusal'));
          } else {
            ctrl.release.complete();
          }
          await frames(tester);
          expect(tester.takeException(), isNull);
          if (outcome != 'unmounted') {
            expect(
              find.text(
                outcome == 'success'
                    ? l.actionDone
                    : l.settingsStorageCompactFailed,
              ),
              findsOneWidget,
            );
            expect(tester.widget<ListTile>(target).onTap, isNotNull);
            expect(
              find.textContaining('synthetic private refusal'),
              findsNothing,
            );
          }
        } finally {
          if (!ctrl.release.isCompleted) ctrl.release.complete();
          await tester.pumpWidget(const SizedBox());
          app.dispose();
          await storage.close();
        }
      });
    }
  }
}
