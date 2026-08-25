import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/hardening_sync_notice.dart';
import 'package:xveil/l10n/app_localizations.dart';

/// Three hardening steps can fail after a commit and only one of them leaves
/// anything to do. `padding` and `churn` describe a commit already past —
/// nothing anyone does now un-leaks it — so they wait on the storage screen.
/// `sync` says the masking writes have not reached the platter YET, and "do
/// not pull the power" is a real answer, so that one interrupts.
///
/// A notice the reader cannot act on teaches them to dismiss notices, which is
/// the failure this split exists to avoid.
void main() {
  test('only the sync step is worth interrupting for', () {
    expect(
      hardeningWarningIsUrgent('sync: fsync failed on the container'),
      isTrue,
    );
    expect(
      hardeningWarningIsUrgent('padding: could not extend the file'),
      isFalse,
      reason:
          'that commit is past; the next one re-pads and this one cannot '
          'be un-leaked',
    );
    expect(
      hardeningWarningIsUrgent('churn: no decoy moved beside the reuse'),
      isFalse,
    );
    expect(hardeningWarningIsUrgent(null), isFalse);
    expect(
      hardeningWarningIsUrgent(''),
      isFalse,
      reason: 'an empty record is an acknowledged one, not an urgent one',
    );
  });

  /// The notice is the ONLY report of an unsynced commit, and pressing its
  /// button clears the container's record for good. A dialog that also closes
  /// on a tap past it, or on Back, hands back the same "read it" answer — so a
  /// stray tap while it was appearing acknowledged a warning nobody looked at
  /// (report14 X14-L1).
  group('the notice can only be closed by reading it', () {
    Widget host(void Function(bool) record) => MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  record(await showHardeningSyncDialog(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('a tap outside does not close it', (tester) async {
      bool? answered;
      await tester.pumpWidget(host((v) => answered = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      // The barrier is what a stray tap lands on.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: 'closing on a barrier tap is indistinguishable from reading it',
      );
      expect(answered, isNull, reason: 'nothing has been answered yet');
    });

    testWidgets('Back does not close it either', (tester) async {
      bool? answered;
      await tester.pumpWidget(host((v) => answered = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // What the Android system back gesture delivers.
      final widgetsBinding = tester.binding;
      await widgetsBinding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(answered, isNull);
    });

    testWidgets('the button is the way out, and it reports a read', (
      tester,
    ) async {
      bool? answered;
      await tester.pumpWidget(host((v) => answered = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final l = AppL10n.of(tester.element(find.byType(AlertDialog)));
      await tester.tap(find.text(l.settingsStorageHardeningDismiss));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        answered,
        isTrue,
        reason: 'the acknowledgement only happens on this answer',
      );
    });
  });
}
