import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'onboarded': true}));

  testWidgets('Start over confirms then returns to onboarding', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        );
      }),
    ));
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
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: LockScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();

    // Still on the lock screen (unlock button present).
    expect(find.text(l.lockUnlock), findsOneWidget);
  });

  testWidgets('Clear all data is gated behind typing the exact phrase',
      (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        );
      }),
    ));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();

    // The destructive confirm button is present but DISABLED until the phrase
    // is typed (so an accidental double-tap can't wipe anything).
    final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, l.lockWipeConfirm));
    expect(confirm.onPressed, isNull, reason: 'disabled before the phrase');

    final dialogField = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(dialogField, l.lockWipePhrase);
    await tester.pumpAndSettle();
    final confirmNow = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, l.lockWipeConfirm));
    expect(confirmNow.onPressed, isNotNull, reason: 'enabled once typed');

    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();
    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
  });
}
