import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/common/help_label.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  testWidgets('asking for help does not toggle the surrounding setting', (
    tester,
  ) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: SwitchListTile(
            title: const HelpLabel(
              title: 'Fixture setting',
              help: 'Fixture explanation',
            ),
            value: false,
            onChanged: (_) => changes++,
          ),
        ),
      ),
    );
    expect(find.text('Fixture explanation'), findsNothing);
    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();
    expect(find.text('Fixture explanation'), findsOneWidget);
    expect(changes, 0);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('Fixture explanation'), findsNothing);
    expect(changes, 0);
  });
}
