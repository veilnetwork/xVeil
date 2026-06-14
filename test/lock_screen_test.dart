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
}
