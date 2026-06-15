import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/onboarding/recovery_phrase_input.dart';
import 'package:xveil/l10n/app_localizations.dart';

const _good = 'alpha bravo charlie';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('submit disabled until word count AND validator pass',
      (tester) async {
    String? submitted;
    await tester.pumpWidget(_host(RecoveryPhraseInput(
      wordCount: 3,
      validate: (p) => p == _good,
      onSubmit: (p) => submitted = p,
    )));

    FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull); // empty

    // Right count but wrong words -> still disabled.
    await tester.enterText(find.byType(TextField), 'one two three');
    await tester.pump();
    expect(button().onPressed, isNull);

    // Correct phrase -> enabled.
    await tester.enterText(find.byType(TextField), _good);
    await tester.pump();
    expect(button().onPressed, isNotNull);

    await tester.tap(find.byType(FilledButton));
    expect(submitted, _good);
  });

  testWidgets('normalizes whitespace/case and counts words', (tester) async {
    await tester.pumpWidget(_host(RecoveryPhraseInput(
      wordCount: 3,
      validate: (p) => p == _good,
      onSubmit: (_) {},
    )));

    await tester.enterText(find.byType(TextField), '  ALPHA   Bravo\tCharlie ');
    await tester.pump();
    expect(find.text('3 / 3 words'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
