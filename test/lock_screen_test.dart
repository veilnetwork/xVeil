import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'dart:io';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/whisper_model_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'onboarded': true}));

  testWidgets('Start over confirms then returns to onboarding', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    // The lock screen's "Start over" is a TextButton; tapping it opens a
    // confirmation dialog with a FilledButton of the same label.
    await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
    await tester.pumpAndSettle();
    expect(find.text(l.lockStartOverBody), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, l.lockStartOver));
    await tester.pumpAndSettle();

    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  testWidgets('cancelling Start over keeps the lock screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();

    // Still on the lock screen (unlock button present).
    expect(find.text(l.lockUnlock), findsOneWidget);
  });

  testWidgets('Clear all data is gated behind typing the exact phrase', (
    tester,
  ) async {
    late ProviderContainer container;
    // The wipe removes the speech model, and resolving the support directory
    // goes through path_provider — which never answers in a widget test, so
    // without this the wipe is still in flight when the assertion runs.
    final modelDir = Directory.systemTemp.createTempSync('lock_wipe_model');
    addTearDown(() {
      if (modelDir.existsSync()) modelDir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => modelDir),
          ),
        ],
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();

    // The destructive confirm button is present but DISABLED until the phrase
    // is typed (so an accidental double-tap can't wipe anything).
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l.lockWipeConfirm),
    );
    expect(confirm.onPressed, isNull, reason: 'disabled before the phrase');

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, l.lockWipePhrase);
    await tester.pumpAndSettle();
    final confirmNow = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l.lockWipeConfirm),
    );
    expect(confirmNow.onPressed, isNotNull, reason: 'enabled once typed');

    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();
    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  testWidgets('small iPhone stays scrollable above the software keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.view.viewInsets = const FakeViewPadding(bottom: 291);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_LockedErrorController.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(LockScreen)));
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text(l.lockWrong), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    expect(find.text(l.lockWipe), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Clear all data stays disabled for the WRONG phrase', (
    tester,
  ) async {
    // The test above goes straight from empty to the exact phrase, so it is
    // satisfied by any gate that merely requires typing SOMETHING -- replacing
    // the comparison with `isNotEmpty` left the suite green. That is the whole
    // difference between "type these words to confirm" and "touch the keyboard
    // to confirm", on the one action in the app that cannot be undone.
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    bool confirmEnabled() =>
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, l.lockWipeConfirm),
            )
            .onPressed !=
        null;

    for (final typed in [
      'x',
      'yes',
      'delete',
      '${l.lockWipePhrase} ',
      '${l.lockWipePhrase}x',
      l.lockWipePhrase.substring(0, l.lockWipePhrase.length - 1),
    ]) {
      await tester.enterText(dialogField, typed);
      await tester.pumpAndSettle();
      final shouldPass = typed.trim() == l.lockWipePhrase;
      expect(
        confirmEnabled(),
        shouldPass,
        reason: 'typed "$typed" — expected enabled=$shouldPass',
      );
    }

    // Nothing above was allowed to wipe anything on the way through.
    expect(
      container.read(appControllerProvider).phase,
      isNot(AppPhase.onboarding),
    );
  });
}

class _LockedErrorController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked, unlockError: true);
}
