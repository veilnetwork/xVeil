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
      final source = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesLinkNew),
      );
      final target = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesJoinExisting),
      );
      expect(source.enabled, isFalse);
      expect(target.enabled, isFalse);
    },
  );
}
