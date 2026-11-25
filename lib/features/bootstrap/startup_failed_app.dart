import 'dart:io' show exit;

import 'package:flutter/material.dart';

import '../../data/storage/managed_fs_contract.dart';
import '../../data/storage/async_kv_log_store.dart'
    show ManagedPreferencesFailureReason;
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
    this.preferencesReason,
    this.aclWarnings = const [],
    this.runtimeDirectory,
    this.runtimeAclWarning,
    this.acceptAclWarning,
  });

  final Future<void> Function()? retryPreferences;
  final bool preferencesFormatFailed;
  final bool preferencesUnsafeAncestor;
  final ManagedAncestorRefusal? ancestorRefusal;
  final ManagedPreferencesFailureReason? preferencesReason;
  final List<ManagedStorageAclWarning> aclWarnings;
  final String? runtimeDirectory;
  final ManagedStorageAclWarning? runtimeAclWarning;
  final Future<bool> Function(bool remember)? acceptAclWarning;

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
        preferencesReason: preferencesReason,
        aclWarnings: aclWarnings,
        runtimeDirectory: runtimeDirectory,
        runtimeAclWarning: runtimeAclWarning,
        acceptAclWarning: acceptAclWarning,
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
    required this.preferencesReason,
    required this.aclWarnings,
    required this.runtimeDirectory,
    required this.runtimeAclWarning,
    required this.acceptAclWarning,
  });

  final Future<void> Function()? retryPreferences;
  final bool preferencesFormatFailed;
  final bool preferencesUnsafeAncestor;
  final ManagedAncestorRefusal? ancestorRefusal;
  final ManagedPreferencesFailureReason? preferencesReason;
  final List<ManagedStorageAclWarning> aclWarnings;
  final String? runtimeDirectory;
  final ManagedStorageAclWarning? runtimeAclWarning;
  final Future<bool> Function(bool remember)? acceptAclWarning;

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

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retryPreferences = widget.retryPreferences;
    final ancestor = widget.ancestorRefusal;
    final warnings = widget.aclWarnings;
    final runtimeDirectory = widget.runtimeDirectory;
    final runtimeAclWarning = widget.runtimeAclWarning;
    final accept = widget.acceptAclWarning;
    final actionStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final explanation = runtimeDirectory != null
        ? l.startupRuntimeDirectoryFailed
        : switch (widget.preferencesUnsafeAncestor) {
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
            false =>
              _preferencesExplanation(l, widget.preferencesReason) ??
                  l.startupFailedAction,
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
                  warnings.isEmpty ? Icons.error_outline : Icons.warning_amber,
                  size: 56,
                  color: scheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  warnings.isEmpty
                      ? l.startupFailedTitle
                      : l.startupAclWarningTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                if (warnings.isNotEmpty && accept != null) ...[
                  Text(
                    warnings.first.directory
                        ? l.startupAclWarningRisk
                        : l.startupAclFileWarningRisk,
                    style: actionStyle,
                  ),
                  const SizedBox(height: 8),
                  for (final warning in warnings) ...[
                    _AclDetails(warning),
                    const SizedBox(height: 16),
                  ],
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
                    ],
                  ),
                ] else ...[
                  Text(explanation, style: actionStyle),
                  if (runtimeDirectory != null) ...[
                    const SizedBox(height: 8),
                    if (runtimeAclWarning != null)
                      _AclDetails(runtimeAclWarning)
                    else
                      SelectableText(runtimeDirectory),
                  ],
                  if (widget.preferencesUnsafeAncestor && ancestor != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      l.startupPreferencesAncestorDepth(ancestor.depth),
                      style: actionStyle,
                    ),
                  ],
                ],
                if (_retrying) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                const CopyErrorReportTile(phase: 'startup-failed'),
                if (retryPreferences != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _retrying
                        ? null
                        : () => _retry(retryPreferences),
                    child: Text(
                      warnings.isEmpty ? l.startupRetry : l.startupAclRecheck,
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

class _AclDetails extends StatelessWidget {
  const _AclDetails(this.warning);

  final ManagedStorageAclWarning warning;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(warning.path),
        const SizedBox(height: 8),
        if (warning.owner case final owner?) Text(l.startupAclOwner(owner)),
        for (final grant in warning.grants)
          Text(
            l.startupAclGrant(
              grant.account.isEmpty ? l.startupAclEveryone : grant.account,
              grant.rights.map((right) => _rightLabel(l, right)).join(', '),
            ),
          ),
        if (warning.extendedAcl case final acl?)
          ExpansionTile(
            title: Text(l.startupAclDetails),
            initiallyExpanded: warning.grants.isEmpty,
            children: [SelectableText(acl)],
          ),
      ],
    );
  }
}

String _rightLabel(AppL10n l, ManagedAclRight right) => switch (right) {
  ManagedAclRight.read => l.startupAclRead,
  ManagedAclRight.write => l.startupAclWrite,
  ManagedAclRight.execute => l.startupAclExecute,
  ManagedAclRight.delete => l.startupAclDelete,
  ManagedAclRight.deleteChildren => l.startupAclDeleteChildren,
  ManagedAclRight.changePermissions => l.startupAclChangePermissions,
  ManagedAclRight.changeOwner => l.startupAclChangeOwner,
  ManagedAclRight.fullControl => l.startupAclFullControl,
  ManagedAclRight.other => l.startupAclOther,
};

String? _preferencesExplanation(
  AppL10n l,
  ManagedPreferencesFailureReason? reason,
) => switch (reason) {
  ManagedPreferencesFailureReason.invalidProfilePath ||
  ManagedPreferencesFailureReason.windowsNonDrivePath =>
    l.startupAclInvalidPath,
  ManagedPreferencesFailureReason.windowsPathAccessDenied ||
  ManagedPreferencesFailureReason.filesystemAccessDenied =>
    l.startupAclAccessDenied,
  ManagedPreferencesFailureReason.windowsReparsePoint => l.startupAclLinkedPath,
  ManagedPreferencesFailureReason.profileNotDirectory =>
    l.startupAclExpectedFolder,
  ManagedPreferencesFailureReason.fileType => l.startupAclExpectedFile,
  ManagedPreferencesFailureReason.profileOwner ||
  ManagedPreferencesFailureReason.fileOwner ||
  ManagedPreferencesFailureReason.filePermissions ||
  ManagedPreferencesFailureReason.privateDirectory ||
  ManagedPreferencesFailureReason.privateFile ||
  ManagedPreferencesFailureReason.filesystemUnsafe =>
    l.startupAclInsufficientPrivacy,
  ManagedPreferencesFailureReason.filesystemChanged => l.startupAclPathChanged,
  ManagedPreferencesFailureReason.windowsPathOpenFailed ||
  ManagedPreferencesFailureReason.windowsPathInfoFailed ||
  ManagedPreferencesFailureReason.filesystemUnavailable ||
  ManagedPreferencesFailureReason.filesystemIo =>
    l.startupAclFilesystemUnavailable,
  ManagedPreferencesFailureReason.invalidLifetimeLock =>
    l.startupAclLockInvalid,
  ManagedPreferencesFailureReason.sqlite ||
  ManagedPreferencesFailureReason.missingCatalog ||
  ManagedPreferencesFailureReason.invalidRole =>
    l.startupAclStorageRoleUnavailable,
  ManagedPreferencesFailureReason.profileChoiceUnreadable =>
    l.startupProfileChoiceUnreadable,
  ManagedPreferencesFailureReason.profileChoiceInvalid =>
    l.startupProfileChoiceInvalid,
  _ => null,
};
