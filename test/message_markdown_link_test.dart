import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/message_markdown.dart';
import 'package:xveil/l10n/app_localizations.dart';

// Widget-level checks for the link tap flow. adb synthetic taps don't drive a
// TextSpan's TapGestureRecognizer (they fire widget-level recognizers only), so
// the on-device tap can't be exercised from tooling — this pins the wiring
// (tap → consent dialog) deterministically instead.
void main() {
  Widget host(String body) => MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Center(child: FormattedText(body))),
      );

  testWidgets('tapping a link opens the Open / Copy / Cancel dialog', (
    tester,
  ) async {
    await tester.pumpWidget(host('see https://veil.im now'));
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('https://veil.im'));
    await tester.pumpAndSettle();

    expect(find.text('Open link?'), findsOneWidget);
    expect(find.text('https://veil.im'), findsOneWidget); // shown in the body
    expect(find.widgetWithText(TextButton, 'Open'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Copy'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
  });

  testWidgets('Cancel dismisses the dialog without opening anything', (
    tester,
  ) async {
    await tester.pumpWidget(host('go https://veil.im'));
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('https://veil.im'));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsNothing);
  });
}
