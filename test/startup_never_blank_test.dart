import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/bootstrap/startup_failed_app.dart';
import 'package:xveil/main.dart' show runStartup;

/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// that zone can only LOG an uncaught error — it cannot un-skip the `runApp`
/// the throw jumped over. A failure anywhere in bootstrap therefore ended as an
/// EMPTY WINDOW: process alive, log written where nobody looks, and a user with
/// no way to tell whether their data had been touched.
void main() {
  testWidgets('a startup that throws still puts something on screen', (
    tester,
  ) async {
    Widget? presented;
    await runStartup(
      boot: () async =>
          throw StateError('the container path would not resolve'),
      present: (w) => presented = w,
    );

    expect(
      presented,
      isNotNull,
      reason: 'the throw skipped runApp and left an empty window',
    );
    // ...and it must actually PAINT. A widget that cannot build is the blank
    // window by another name, so it is pumped rather than merely type-checked.
    await tester.pumpWidget(presented!);
    expect(find.byType(StartupFailedApp), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    // Localized text, not a placeholder: the fallback is the only thing the
    // user will read, so it has to be readable.
    expect(find.textContaining('xVeil'), findsWidgets);
  });

  testWidgets('CONTROL: a startup that succeeds is left alone — no second app '
      'is presented over it', (tester) async {
    var booted = 0;
    Widget? presented;
    await runStartup(boot: () async => booted++, present: (w) => presented = w);
    expect(booted, 1);
    expect(
      presented,
      isNull,
      reason: 'the fallback ran over a startup that had already succeeded',
    );
  });

  testWidgets(
    'an asynchronous failure counts too, not only a synchronous one',
    (tester) async {
      Widget? presented;
      await runStartup(
        boot: () async {
          // A suspension, not a timer: `testWidgets` runs on a fake clock that
          // only advances when pumped, so a real delay here would hang.
          await null;
          throw 'a plugin channel answered nothing';
        },
        present: (w) => presented = w,
      );
      expect(presented, isA<StartupFailedApp>());
    },
  );
}
