import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/features/bootstrap/profile_erasure_pending_app.dart';
import 'package:xveil/features/bootstrap/startup_failed_app.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/main.dart' show runStartup;

/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// that zone can only LOG an uncaught error — it cannot un-skip the `runApp`
/// the throw jumped over. A failure anywhere in bootstrap therefore ended as an
/// EMPTY WINDOW: process alive, log written where nobody looks, and a user with
/// no way to tell whether their data had been touched.
void main() {
  for (final duringOpen in [true, false]) {
    testWidgets('can retry a busy preferences file (open=$duringOpen)', (
      tester,
    ) async {
      final busy = ManagedWorkerFailure(
        ManagedWorkerFailureKind.busy,
        preferencesOpenReason: duringOpen
            ? ManagedPreferencesFailureReason.busy
            : null,
        preferencesReadReason: duringOpen
            ? null
            : ManagedPreferencesFailureReason.busy,
      );
      final retryGate = Completer<void>();
      var attempts = 0;
      Widget? presented;
      await runStartup(
        loadPreferences: () async {
          attempts++;
          if (attempts == 1) throw busy;
          if (attempts == 2) {
            await retryGate.future;
            throw busy;
          }
          return (
            profile: null,
            supportDirectory: null,
            erasurePending: true,
            legacyPreferences: null,
          );
        },
        present: (widget) => presented = widget,
      );

      await tester.pumpWidget(presented!);
      expect(find.textContaining('settings file is in use'), findsOneWidget);
      expect(find.byType(CopyErrorReportTile), findsOneWidget);
      final retry = find.widgetWithText(FilledButton, 'Try again');
      await tester.tap(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(attempts, 2);
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      retryGate.complete();
      await tester.pump();
      await tester.pumpWidget(presented!);
      expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
      await tester.tap(retry);
      await tester.pump();
      expect(attempts, 3);
      await tester.pumpWidget(presented!);
      expect(find.byType(ProfileErasurePendingApp), findsOneWidget);
      expect(find.byType(StartupFailedApp), findsNothing);
    });
  }

  for (final busy in [true, false]) {
    test('startup reports profile choice read failures (busy=$busy)', () async {
      diagnosticJournal.clear();
      addTearDown(diagnosticJournal.clear);
      Widget? presented;
      await runStartup(
        loadPreferences: () async => throw ProfileChoiceReadFailure(busy: busy),
        present: (widget) => presented = widget,
      );
      expect((presented as StartupFailedApp).retryPreferences != null, busy);
      final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
      final event = retained?['profileChoiceReadFailed'] as Map?;
      expect(
        event?['values'],
        diagnosticJournal.enabled ? {'code': busy ? 1 : 0} : isNull,
      );
    });
  }

  testWidgets('a busy preference error during resumed startup stays generic', (
    tester,
  ) async {
    Widget? presented;
    await runStartup(
      boot: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.busy,
        preferencesReadReason: ManagedPreferencesFailureReason.busy,
      ),
      present: (widget) => presented = widget,
    );
    await tester.pumpWidget(presented!);
    expect(find.byType(StartupFailedApp), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  test('startup exposes only the bounded preference admission codes', () async {
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesOpenReason: ManagedPreferencesFailureReason.filesystemUnsafe,
      ),
      present: (w) => presented = w,
    );
    expect(
      presented,
      isA<StartupFailedApp>().having(
        (w) => w.retryPreferences,
        'retry',
        isNull,
      ),
    );
    final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
    final entry = retained?['profilePreferencesOpenFailed'] as Map?;
    expect(
      entry?['values'],
      diagnosticJournal.enabled
          ? {
              'state': ManagedWorkerFailureKind.invalid.index,
              'code': ManagedPreferencesFailureReason.filesystemUnsafe.index,
            }
          : isNull,
    );
  });

  test('startup retains the distinct preference read refusal', () async {
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesReadReason: ManagedPreferencesFailureReason.filePermissions,
      ),
      present: (widget) => presented = widget,
    );
    expect(
      presented,
      isA<StartupFailedApp>().having(
        (w) => w.retryPreferences,
        'retry',
        isNull,
      ),
    );
    final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
    expect(retained?['profilePreferencesOpenFailed'], isNull);
    final event = retained?['profilePreferencesReadFailed'] as Map?;
    expect(
      event?['values'],
      diagnosticJournal.enabled
          ? {
              'state': ManagedWorkerFailureKind.invalid.index,
              'code': ManagedPreferencesFailureReason.filePermissions.index,
            }
          : isNull,
    );
  });

  testWidgets(
    'invalid preference format preserves a specific startup failure',
    (tester) async {
      diagnosticJournal.clear();
      addTearDown(diagnosticJournal.clear);
      Widget? presented;
      const reason = ProfilePreferencesFormatReason.unsupportedVersion;
      await runStartup(
        loadPreferences: () async =>
            throw const ProfilePreferencesFormatFailure(reason),
        present: (widget) => presented = widget,
      );
      await tester.pumpWidget(presented!);
      expect(find.textContaining('unsupported format'), findsOneWidget);
      final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
      final event = retained?['profilePreferencesFormatFailed'] as Map?;
      expect(
        event?['values'],
        diagnosticJournal.enabled ? {'code': reason.index} : isNull,
      );
    },
  );

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
