import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:xveil/core/backup_exclusion.dart';
import 'package:xveil/features/settings/privacy_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

/// The runner's answer about whether the container is out of the device backup.
///
/// On iOS everything durable — the encrypted container, the node runtime dir,
/// the per-profile preference files — sits under Application Support, and iOS
/// copies that into iCloud and encrypted Finder backups by default. The runner
/// sets `isExcludedFromBackup` at launch.
///
/// It used to set it and walk away: `setResourceValues` throwing nothing was
/// taken as the flag being set, and a missing directory was a bare `return`
/// with no log and no report. So the case where the whole container goes into
/// iCloud was indistinguishable from the case where it does not — from inside
/// the app, and from anywhere else short of reading somebody's backup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Stands in for the iOS runner. `answer` is what the platform side would
  /// return from `problem`: null for "excluded", a string for the reason.
  MethodChannel channelAnswering(
    Object? Function() answer, {
    List<String>? calls,
  }) {
    const channel = MethodChannel(BackupExclusion.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls?.add(call.method);
      return answer();
    });
    return channel;
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(BackupExclusion.channelName),
      null,
    );
  });

  group('what the runner reports', () {
    test('excluded reads as no problem', () async {
      final calls = <String>[];
      final channel = channelAnswering(() => null, calls: calls);
      expect(await BackupExclusion(channel: channel).problem(), isNull);
      expect(calls, ['problem']);
    });

    test('NOT excluded comes back with the reason, not just a flag', () async {
      final channel = channelAnswering(
        () => 'the exclude-from-backup flag did not read back as set',
      );
      expect(
        await BackupExclusion(channel: channel).problem(),
        'the exclude-from-backup flag did not read back as set',
      );
    });

    test('a platform with no handler is not a warning', () async {
      // Android (allowBackup=false in the manifest), the desktops, and every
      // test host. Inventing a warning here would train people past the real
      // one.
      expect(await const BackupExclusion().problem(), isNull);
    });

    test('a failed call is not evidence of exposure either', () async {
      final channel = channelAnswering(
        () => throw PlatformException(code: 'boom'),
      );
      expect(await BackupExclusion(channel: channel).problem(), isNull);
    });
  });

  group('Settings → Privacy', () {
    Future<void> pump(WidgetTester tester, BackupExclusion exclusion) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppL10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [BackupExclusionWarning(exclusion: exclusion)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says so when the data is NOT excluded', (tester) async {
      final channel = channelAnswering(() => 'operation not permitted');
      await pump(tester, BackupExclusion(channel: channel));

      expect(find.byKey(const ValueKey('backup-not-excluded')), findsOneWidget);
      // The reason the runner gave is carried through, not swallowed — it is
      // the only thing that makes the warning actionable.
      expect(
        find.textContaining('operation not permitted'),
        findsOneWidget,
      );
    });

    testWidgets('shows NOTHING when the data is excluded', (tester) async {
      final channel = channelAnswering(() => null);
      await pump(tester, BackupExclusion(channel: channel));
      expect(find.byKey(const ValueKey('backup-not-excluded')), findsNothing);
    });

    testWidgets('warns rather than blocking — the screen still works',
        (tester) async {
      final channel = channelAnswering(() => 'operation not permitted');
      await pump(tester, BackupExclusion(channel: channel));
      // The audit asked for writes or the unlock to be blocked. That takes a
      // working app away from someone over a filesystem condition they cannot
      // fix from inside it, so this is a card in a list and nothing more.
      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsOneWidget);
    });
  });
}
