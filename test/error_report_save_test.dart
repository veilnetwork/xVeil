import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/l10n/app_localizations.dart';

class _PathOnlyPicker extends FilePickerPlatform {
  _PathOnlyPicker(this.path);
  final String? path;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

void desktopTest(
  String name,
  TargetPlatform platform,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = FilePickerPlatform.instance;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    FilePickerPlatform.instance = original;
    errorJournal.clear();
  });
  Future<BuildContext> context(WidgetTester tester) async {
    late BuildContext held;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              held = ctx;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return held;
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    desktopTest(
      '$platform writes the selected diagnostic file before saying saved',
      platform,
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'xv-report-save-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final target = File('${directory.path}/report.json');
        FilePickerPlatform.instance = _PathOnlyPicker(target.path);
        errorJournal.record(
          kind: 'platform',
          error: 'private peer /Users/private-user/container',
          atMs: 1,
        );
        final ctx = await context(tester);
        await tester.runAsync(() => saveErrorReport(ctx, phase: 'settings'));
        await tester.pumpAndSettle();
        expect(
          target.existsSync(),
          isTrue,
          reason: 'a selected path is not a saved report',
        );
        final text = target.readAsStringSync();
        final report = jsonDecode(text) as Map;
        expect(report['schema'], 'xveil-error-report/1');
        expect(report['phase'], 'settings');
        expect(text, isNot(contains('private-user')));
        expect(text, isNot(contains(directory.path)));
        expect(
          find.text(AppL10n.of(ctx).settingsDiagnosticsSaved),
          findsOneWidget,
        );
      },
    );
  }
  desktopTest(
    'cancel does not report saved or create a file',
    TargetPlatform.macOS,
    (tester) async {
      FilePickerPlatform.instance = _PathOnlyPicker(null);
      final ctx = await context(tester);
      await tester.runAsync(() => saveErrorReport(ctx, phase: 'settings'));
      await tester.pumpAndSettle();
      expect(find.text(AppL10n.of(ctx).settingsDiagnosticsSaved), findsNothing);
    },
  );
  desktopTest(
    'failed publication shows failure and removes its staging file',
    TargetPlatform.macOS,
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'xv-report-refusal-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final target = Directory('${directory.path}/existing-directory')
        ..createSync();
      FilePickerPlatform.instance = _PathOnlyPicker(target.path);
      final ctx = await context(tester);
      await tester.runAsync(() => saveErrorReport(ctx, phase: 'settings'));
      await tester.pumpAndSettle();
      expect(find.text(AppL10n.of(ctx).settingsDiagnosticsSaved), findsNothing);
      expect(
        find.text(AppL10n.of(ctx).settingsDiagnosticsSaveFailed),
        findsOneWidget,
      );
      expect(directory.listSync().whereType<File>(), isEmpty);
      expect(
        buildErrorReport(phase: 'settings'),
        isNot(contains(directory.path)),
      );
    },
  );
}
