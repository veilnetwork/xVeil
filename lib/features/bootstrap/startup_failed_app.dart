import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/storage/managed_fs_contract.dart';
import '../../l10n/app_localizations.dart';
import '../settings/error_report.dart';

/// The whole app, when startup threw before it could put anything on screen.
///
/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// the zone handler LOGS an uncaught error — it cannot un-skip the `runApp` the
/// throw jumped over. So a failure anywhere in bootstrap (a preference store
/// that will not install, a container path that will not resolve, a provider
/// override that throws while it is being built) ended with an empty window and
/// nothing to read and no way to export diagnostics.
///
/// The screen offers diagnostic export and, when preferences are busy, a retry.
/// The stack trace stays in the log and error journal.
class StartupFailedApp extends StatelessWidget {
  const StartupFailedApp({
    super.key,
    this.retryPreferences,
    this.preferencesFormatFailed = false,
    this.preferencesUnsafeAncestor = false,
    this.ancestorRefusal,
    this.deleteWarning,
    this.acceptDeleteWarning,
  });

  final Future<void> Function()? retryPreferences;
  final bool preferencesFormatFailed;
  final bool preferencesUnsafeAncestor;
  final ManagedAncestorRefusal? ancestorRefusal;
  final ManagedWindowsDeleteWarning? deleteWarning;
  final Future<bool> Function(bool remember)? acceptDeleteWarning;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E6B5C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _StartupFailedScreen(
        retryPreferences: retryPreferences,
        preferencesFormatFailed: preferencesFormatFailed,
        preferencesUnsafeAncestor: preferencesUnsafeAncestor,
        ancestorRefusal: ancestorRefusal,
        deleteWarning: deleteWarning,
        acceptDeleteWarning: acceptDeleteWarning,
      ),
    );
  }
}

class _StartupFailedScreen extends StatefulWidget {
  const _StartupFailedScreen({
    required this.retryPreferences,
    required this.preferencesFormatFailed,
    required this.preferencesUnsafeAncestor,
    required this.ancestorRefusal,
    required this.deleteWarning,
    required this.acceptDeleteWarning,
  });

  final Future<void> Function()? retryPreferences;
  final bool preferencesFormatFailed;
  final bool preferencesUnsafeAncestor;
  final ManagedAncestorRefusal? ancestorRefusal;
  final ManagedWindowsDeleteWarning? deleteWarning;
  final Future<bool> Function(bool remember)? acceptDeleteWarning;

  @override
  State<_StartupFailedScreen> createState() => _StartupFailedScreenState();
}

class _StartupFailedScreenState extends State<_StartupFailedScreen> {
  bool _retrying = false;
  bool _approvalFailed = false;

  Future<void> _retry(Future<void> Function() retryPreferences) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await retryPreferences();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _accept(
    Future<bool> Function(bool remember) accept,
    bool remember,
  ) => _retry(() async {
    setState(() => _approvalFailed = false);
    final accepted = await accept(remember);
    if (mounted && !accepted) setState(() => _approvalFailed = true);
  });

  Future<void> _copyAclRepair() async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      final script = await rootBundle.loadString(
        'scripts/repair-windows-profile-delete-grant.ps1',
      );
      await Clipboard.setData(ClipboardData(text: '& {\n$script\n}'));
      message = l.startupAclRepairCopied;
    } catch (_) {
      message = l.startupAclRepairCopyFailed;
    }
    if (mounted) messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retryPreferences = widget.retryPreferences;
    final ancestor = widget.ancestorRefusal;
    final warning = widget.deleteWarning;
    final accept = widget.acceptDeleteWarning;
    final actionStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final explanation = switch (widget.preferencesUnsafeAncestor) {
      true => switch (ancestor?.cause) {
        ManagedAncestorRefusalCause.notDirectory =>
          l.startupPreferencesAncestorNotDirectory,
        ManagedAncestorRefusalCause.untrustedOwner =>
          l.startupPreferencesAncestorOwner,
        ManagedAncestorRefusalCause.unsafePermissions =>
          l.startupPreferencesAncestorPermissions,
        null => l.startupPreferencesUnsafeAncestor,
      },
      false when widget.preferencesFormatFailed =>
        l.startupPreferencesFormatFailed,
      false when retryPreferences != null => l.startupPreferencesBusy,
      false => l.startupFailedAction,
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  warning == null ? Icons.error_outline : Icons.warning_amber,
                  size: 56,
                  color: scheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  warning == null
                      ? l.startupFailedTitle
                      : l.startupAclWarningTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                if (warning != null && accept != null) ...[
                  Text(l.startupAclWarningRisk, style: actionStyle),
                  const SizedBox(height: 8),
                  SelectableText(warning.path),
                  const SizedBox(height: 8),
                  for (final grant in warning.grants)
                    Text(
                      grant.canList
                          ? l.startupAclGrantDeleteAndList(grant.account)
                          : l.startupAclGrantDelete(grant.account),
                    ),
                  const SizedBox(height: 8),
                  Text(l.startupAclCorrectionHint, style: actionStyle),
                  if (_approvalFailed)
                    Text(
                      l.startupAclApprovalFailed,
                      style: TextStyle(color: scheme.error),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _retrying ? null : () => exit(0),
                        child: Text(l.startupAclClose),
                      ),
                      OutlinedButton(
                        onPressed: _retrying
                            ? null
                            : () => _accept(accept, false),
                        child: Text(l.startupAclContinueOnce),
                      ),
                      OutlinedButton(
                        onPressed: _retrying
                            ? null
                            : () => _accept(accept, true),
                        child: Text(l.startupAclRemember),
                      ),
                      TextButton(
                        onPressed: _retrying ? null : _copyAclRepair,
                        child: Text(l.startupAclCopyRepair),
                      ),
                    ],
                  ),
                ] else ...[
                  Text(explanation, style: actionStyle),
                  if (widget.preferencesUnsafeAncestor && ancestor != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      l.startupPreferencesAncestorDepth(ancestor.depth),
                      style: actionStyle,
                    ),
                  ],
                ],
                const CopyErrorReportTile(phase: 'startup-failed'),
                if (retryPreferences != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _retrying
                        ? null
                        : () => _retry(retryPreferences),
                    child: Text(
                      warning == null ? l.startupRetry : l.startupAclRecheck,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
