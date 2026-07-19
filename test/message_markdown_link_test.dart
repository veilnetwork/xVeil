import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
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

  testWidgets('inline custom emoji renders inside formatted text', (
    tester,
  ) async {
    // 1×1 transparent PNG; production uses a bounded derived PNG too.
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormattedText(
            'before **☺** after',
            customEmoji: const [InlineCustomEmoji(offset: 9, dataB64: png)],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('inline-custom-emoji:9')), findsOneWidget);
    expect(base64Decode(png), isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
