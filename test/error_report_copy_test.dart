import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? copied;
  setUp(() {
    copied = null;
    errorJournal.clear();
    diagnosticJournal.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpTile(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: const Scaffold(body: CopyErrorReportTile(phase: 'settings')),
    ),
  );

  testWidgets('the tile puts a parseable report on the clipboard', (
    tester,
  ) async {
    errorJournal.record(kind: 'zone', error: 'no route to peer', atMs: 1);
    await pumpTile(tester);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    expect(copied, isNotNull, reason: 'nothing reached the clipboard');
    final decoded = jsonDecode(copied!) as Map<String, Object?>;
    expect(decoded['schema'], 'xveil-error-report/1');
    expect(decoded['phase'], 'settings');
    expect(decoded.containsKey('profile'), isFalse);
    expect(
      ((decoded['errors'] as List).single as Map).containsKey('at'),
      isFalse,
    );
    expect(decoded['veil'], kVeilBuildVersion);
    expect(decoded['hidden_volume'], kHiddenVolumeBuildVersion);
    if (kDiagnosticReportEnabled) {
      expect((decoded['diagnostics'] as Map)['schema'], 'xveil-diagnostics/1');
    } else {
      expect(decoded.containsKey('diagnostics'), isFalse);
    }
    expect((decoded['errors']! as List), hasLength(1));
  });

  testWidgets(
    'an empty journal still copies — "nothing happened" is a report',
    (tester) async {
      await pumpTile(tester);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(copied, isNotNull);
      expect((jsonDecode(copied!) as Map)['errors'], isEmpty);
    },
  );

  testWidgets('what is copied carries no id, path or payload', (tester) async {
    // The whole point of the feature is that it is safe to paste. This is the
    // end-to-end version of that promise: not "redact() works" but "what the
    // button actually produced is clean".
    errorJournal.record(
      kind: 'platform',
      error:
          'send to 7084a345b55ef17031b793b96a9edca2cb1836151490c3a67d1ceab906f2a8a2 '
          'failed opening /Users/alice/Library/Application Support/x.store',
      stack: StackTrace.fromString(
        '#0 Foo.bar (package:xveil/state/a.dart:12:3)\n'
        '#1 main (/Users/alice/Projects/xVeil/lib/main.dart:44:5)',
      ),
      atMs: 2,
    );
    await pumpTile(tester);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, isNot(contains('7084a345')));
    expect(copied, isNot(contains('/Users/')));
    expect(copied, isNot(contains('alice')));
    // The exception's own words are not on the clipboard either — the deny-list
    // is a second line, not the promise (audit X-06).
    expect(copied, isNot(contains('failed opening')));
    expect(copied, isNot(contains('send to')));
    // ...while still saying enough to be worth sending.
    expect(copied, contains('package:xveil/state/a.dart'));
    expect(copied, contains('"kind": "platform"'));
    expect(copied, contains('"type": "String"'));
  });
  test('OS descriptions cannot export hostnames or kernel build paths', () {
    expect(
      anonymousOsVersion(
        'Darwin Kernel Version 25.0.0: root@private-host /Users/alice',
      ),
      '25.0.0',
    );
    expect(anonymousOsVersion('Windows 10 Pro (Build 19045)'), '10');
    expect(
      anonymousOsVersion('Windows [Version 10.0.19045.1] secret'),
      '10.0.19045.1',
    );
    expect(anonymousOsVersion('Android 13 (SDK 33)'), '13');
    expect(anonymousOsVersion('Version 26.0 (Build 25A354)'), '26.0');
    expect(anonymousOsVersion('alice@secret 192.168.1.22'), 'unknown');
  });

  testWidgets('file export contains only the same filtered report', (
    tester,
  ) async {
    Uint8List? savedBytes;
    String? suggested;
    const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      savedBytes = args['bytes'] as Uint8List?;
      suggested = args['fileName'] as String?;
      return '/private/tmp/user-chosen-report.json';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    errorJournal.record(
      kind: 'onboarding',
      error: const FileSystemException(
        'private message',
        '/Users/alice/secret',
        OSError('private OS detail', 13),
      ),
      atMs: 123,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => saveErrorReport(context, phase: 'onboarding'),
              child: const Text('save'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(suggested, 'xveil-diagnostics.json');
    expect(savedBytes, isNotNull);
    final report = utf8.decode(savedBytes!);
    final error = ((jsonDecode(report) as Map)['errors'] as List).single as Map;
    expect(error['code'], 13);
    for (final secret in [
      'alice',
      '/Users/',
      'secret',
      'private message',
      'private OS detail',
    ]) {
      expect(report, isNot(contains(secret)));
    }
  });
}
