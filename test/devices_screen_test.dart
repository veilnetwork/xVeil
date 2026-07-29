import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'shows both guided roles and disables them before node readiness',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: DevicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(DevicesScreen)));
      expect(find.text(l.settingsDevices), findsOneWidget);
      expect(find.text(l.devicesNoGroup), findsOneWidget);
      expect(find.text(l.devicesLinkNew), findsOneWidget);
      expect(find.text(l.devicesJoinExisting), findsOneWidget);
      expect(find.text(l.devicesRecoverySection), findsOneWidget);
      expect(find.text(l.devicesCreateRecovery), findsOneWidget);
      expect(find.text(l.devicesRecover), findsOneWidget);
      final source = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesLinkNew),
      );
      final target = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesJoinExisting),
      );
      expect(source.enabled, isFalse);
      expect(target.enabled, isFalse);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, l.devicesCreateRecovery),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, l.devicesRecover))
            .enabled,
        isFalse,
      );
    },
  );

  group('the onboarding hand-off opens the join sheet', () {
    // The gate itself, not the sheet: opening the real sheet needs a live
    // RealVeilStack (private constructor, real node) so the positive case is
    // out of reach here. Asserting "no sheet appears" through the widget is
    // NOT a substitute — it passes just as happily with the readiness check
    // deleted, because the resulting premature call dies silently at
    // _showTarget's own null guard. Only the gate can tell the two apart.

    test('waits for the node rather than burning its one shot', () {
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: false, alreadyOpened: false),
        isFalse,
        reason: 'firing before the node is up opens nothing and never retries',
      );
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: true, alreadyOpened: false),
        isTrue,
        reason: 'once the node is up the hand-off must actually fire, or the '
            'link path dead-ends on a list the user did not ask for',
      );
    });

    test('fires once, and only for the hand-off', () {
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: true, alreadyOpened: true),
        isFalse,
        reason: 'a sheet the user closed must stay closed',
      );
      expect(
        shouldOpenJoinSheet(autoJoin: false, ready: true, alreadyOpened: false),
        isFalse,
        reason: 'reaching Devices from Settings must not pop a join sheet',
      );
    });
  });

  testWidgets('a not-ready hand-off leaves a usable screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: DevicesScreen(autoJoin: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(DevicesScreen)));
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'no node yet — there is nothing to show a join QR from',
    );
    // Still the plain list, not a wedged or blank screen.
    expect(find.text(l.devicesJoinExisting), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, l.devicesJoinExisting))
          .enabled,
      isFalse,
    );
  });
}
