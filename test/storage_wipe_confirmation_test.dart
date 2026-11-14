import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/lock/storage_wipe_confirmation.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  for (final locale in AppL10n.supportedLocales) {
    for (final wholeProfile in [false, true]) {
      testWidgets('wipe consent names its scope and requires the phrase '
          '(${locale.languageCode}, profile=$wholeProfile)', (tester) async {
        bool? result;
        var returned = false;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showStorageWipeConfirmation(
                      context,
                      wholeProfile: wholeProfile,
                    );
                    returned = true;
                  },
                  child: const Text('Open confirmation'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open confirmation'));
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(AlertDialog)));
        expect(
          find.text(wholeProfile ? l.profileWipeBody : l.lockWipeBody),
          findsOneWidget,
        );
        expect(
          find.text(wholeProfile ? l.lockWipeBody : l.profileWipeBody),
          findsNothing,
        );
        final confirm = find.widgetWithText(FilledButton, l.lockWipeConfirm);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.enterText(find.byType(TextField), '${l.lockWipePhrase}?');
        await tester.pump();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        expect(returned, isFalse);
        await tester.enterText(find.byType(TextField), l.lockWipePhrase);
        await tester.pump();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(returned, isTrue);
        expect(result, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
      testWidgets('wipe cancellation grants no consent '
          '(${locale.languageCode}, profile=$wholeProfile)', (tester) async {
        bool? result;
        var returned = false;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showStorageWipeConfirmation(
                      context,
                      wholeProfile: wholeProfile,
                    );
                    returned = true;
                  },
                  child: const Text('Open confirmation'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open confirmation'));
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(AlertDialog)));
        await tester.tap(find.widgetWithText(TextButton, l.actionCancel));
        await tester.pumpAndSettle();
        expect(returned, isTrue);
        expect(result, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
