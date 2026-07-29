import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/error_journal.dart';
import '../../data/storage/app_profile.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart' show activeProfile;

/// Version of the running build.
///
/// Comes from the build (`--dart-define=XVEIL_VERSION=…`) rather than a literal
/// in the source, because a literal goes stale the first time someone forgets
/// to bump it — and a report that names the wrong build is worse than one that
/// admits it does not know.
const String kAppVersion = String.fromEnvironment(
  'XVEIL_VERSION',
  defaultValue: 'dev',
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
  final report = errorJournal.toJson(
    platform: Platform.operatingSystem,
    osVersion: Platform.operatingSystemVersion,
    appVersion: kAppVersion,
    defaultProfile: activeProfile == AppProfiles.defaultName,
    phase: phase,
  );
  await Clipboard.setData(ClipboardData(text: report));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l.settingsCopyErrorsDone(count))));
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
      title: Text(l.settingsCopyErrors),
      subtitle: Text(l.settingsCopyErrorsHint),
      onTap: () => copyErrorReport(context, phase: phase),
    );
  }
}
