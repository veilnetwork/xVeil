import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/error_journal.dart';
import '../../core/diagnostic_journal.dart';
import '../../l10n/app_localizations.dart';

/// Version of the running build.
///
/// Comes from the build (`--dart-define=XVEIL_VERSION=…`) rather than a literal
/// in the source, because a literal goes stale the first time someone forgets
/// to bump it — and a report that names the wrong build is worse than one that
/// admits it does not know.
const String _appVersion = String.fromEnvironment(
  'XVEIL_VERSION',
  defaultValue: 'dev',
);

const String kAppVersion = kDiagnosticReportEnabled
    ? '$_appVersion (diagnostic)'
    : _appVersion;

/// Native source revisions embedded by the build entrypoints. A bare Flutter
/// build cannot truthfully name its native dependencies, so it shows '?'.
const String kVeilBuildVersion = String.fromEnvironment(
  'XVEIL_VEIL_VERSION',
  defaultValue: '?',
);
const String kHiddenVolumeBuildVersion = String.fromEnvironment(
  'XVEIL_HV_VERSION',
  defaultValue: '?',
);

/// Put the error report on the clipboard and say what was copied.
///
/// [phase] is where the app was when the person asked: "stuck on the lock
/// screen" and "crashed in a chat" are different reports even with the same
/// exception in them.
Future<void> copyErrorReport(
  BuildContext context, {
  required String phase,
}) async {
  final l = AppL10n.of(context);
  final count = errorJournal.entries.length;
  final report = buildErrorReport(phase: phase);
  await Clipboard.setData(ClipboardData(text: report));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l.settingsCopyErrorsDone(count))));
}

String buildErrorReport({required String phase}) => errorJournal.toJson(
  platform: Platform.operatingSystem,
  osVersion: anonymousOsVersion(Platform.operatingSystemVersion),
  appVersion: kAppVersion,
  includeTimestamps: false,
  phase: phase,
  veilVersion: kVeilBuildVersion,
  hiddenVolumeVersion: kHiddenVolumeBuildVersion,
  diagnostics: kDiagnosticReportEnabled ? diagnosticJournal : null,
);

/// The OS description can contain a kernel builder/hostname. Export just a
/// numeric release/build; an unrecognised description is omitted as unknown.
String anonymousOsVersion(String raw) {
  final patterns = [
    RegExp(r'^\[?Version[ :]+(\d+(?:\.\d+){1,3})', caseSensitive: false),
    RegExp(r'^Windows.*?\[Version (\d+(?:\.\d+){1,3})', caseSensitive: false),
    RegExp(r'^Windows (\d+(?:\.\d+){0,3})(?: |\(|$)'),
    RegExp(r'^Android (\d+(?:\.\d+){0,3})(?: |\(|$)'),
    RegExp(r'^Darwin Kernel Version (\d+(?:\.\d+){1,3})'),
    RegExp(r'^Linux (\d+(?:\.\d+){1,3})'),
    RegExp(r'^(\d+(?:\.\d+){1,3})(?:\s|\(|$)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(raw);
    if (match != null) return match.group(1)!;
  }
  return 'unknown';
}

/// The same allow-listed report as the clipboard action, in a user-chosen file.
/// No temporary raw log or peer-labelled filename is created.
Future<void> saveErrorReport(
  BuildContext context, {
  required String phase,
}) async {
  final l = AppL10n.of(context);
  final bytes = Uint8List.fromList(utf8.encode(buildErrorReport(phase: phase)));
  try {
    final path = await FilePicker.saveFile(
      dialogTitle: l.settingsSaveDiagnostics,
      fileName: 'xveil-diagnostics.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
    if (path == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.settingsDiagnosticsSaved)));
  } catch (error, stack) {
    errorJournal.record(
      kind: 'diagnostic-export',
      error: error,
      stack: stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.settingsDiagnosticsSaveFailed)));
  }
}

/// The settings entry. The subtitle states what the report does *not* contain,
/// because someone about to paste a diagnostics blob into a chat deserves to
/// know that before they paste it, not after.
class CopyErrorReportTile extends StatelessWidget {
  const CopyErrorReportTile({super.key, required this.phase});

  final String phase;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListTile(
      leading: const Icon(Icons.bug_report_outlined),
      title: Text(
        kDiagnosticReportEnabled
            ? l.settingsCopyDiagnostics
            : l.settingsCopyErrors,
      ),
      subtitle: Text(
        kDiagnosticReportEnabled
            ? l.settingsCopyDiagnosticsHint
            : l.settingsCopyErrorsHint,
      ),
      trailing: kDiagnosticReportEnabled
          ? IconButton(
              tooltip: l.settingsSaveDiagnostics,
              icon: const Icon(Icons.save_alt),
              onPressed: () => saveErrorReport(context, phase: phase),
            )
          : null,
      onTap: () => copyErrorReport(context, phase: phase),
    );
  }
}
