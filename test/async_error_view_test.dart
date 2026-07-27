import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/features/common/async_error_view.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  setUp(errorJournal.clear);

  Future<void> pump(WidgetTester tester, Object error, {StackTrace? stack}) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: AsyncErrorView(error: error, stack: stack, where: 'chats'),
          ),
        ),
      );

  testWidgets('the raw exception never reaches the screen', (tester) async {
    // The reason this widget exists. An exception here routinely quotes a node
    // id or a store path, and this is a screen people leave open — the text
    // would sit in front of whoever is looking, and in any screenshot sent
    // while asking for help.
    const raw =
        'no route to peer '
        '7084a345b55ef17031b793b96a9edca2cb1836151490c3a67d1ceab906f2a8a2 '
        'reading /Users/alice/Library/Application Support/xveil.store';
    await pump(tester, StateError(raw));

    expect(find.textContaining('7084a345'), findsNothing);
    expect(find.textContaining('/Users/'), findsNothing);
    expect(find.textContaining('no route to peer'), findsNothing);
    expect(
      find.text(
        AppL10n.of(tester.element(find.byType(AsyncErrorView))).errorLoadFailed,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the detail is not lost — it goes to the report', (tester) async {
    // Hiding the cause would only move the problem: the point is that the
    // person chooses when to hand it over, not that nobody can see it.
    await pump(
      tester,
      StateError('no route to peer'),
      stack: StackTrace.fromString(
        '#0 Foo.bar (package:xveil/state/a.dart:12:3)',
      ),
    );

    expect(errorJournal.entries, hasLength(1));
    final entry = errorJournal.entries.single;
    expect(entry.kind, 'screen:chats');
    expect(entry.message, contains('no route to peer'));
    expect(entry.frames, contains('package:xveil/state/a.dart:12:3'));
  });

  testWidgets('one failure records once, however often it rebuilds', (
    tester,
  ) async {
    // An error view can rebuild every frame while it is on screen; 50 copies
    // of one failure would push every other error out of the ring and the
    // report would describe nothing but this screen.
    await pump(tester, StateError('boom'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(errorJournal.entries, hasLength(1));
  });
}
