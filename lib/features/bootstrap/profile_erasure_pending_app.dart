import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/storage_acl_vault.dart';
import '../../data/storage/async_kv_log_store.dart'
    show managedStorageFailureReason;
import '../../data/storage/managed_fs_contract.dart';
import '../../data/storage/managed_profile_wipe.dart';
import '../../l10n/app_localizations.dart';
import 'startup_failed_app.dart'
    show preferencesFailureText, showStorageAccessReview;

/// Outside the ordinary provider/router tree: neither saved-entry prompts nor
/// onboarding, networking or ordinary storage readers can start here.
/// This screen reports a pending operation; it does not claim cleanup finished.
class ProfileErasurePendingApp extends StatelessWidget {
  const ProfileErasurePendingApp({
    super.key,
    this.recover,
    this.onRecovered,
    this.close,
  });
  final Future<void> Function()? recover;
  final Future<void> Function()? onRecovered;
  final Future<void> Function()? close;

  @override
  Widget build(BuildContext context) => MaterialApp(
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
    home: _RecoveryBody(
      key: recover == null ? null : ObjectKey(recover),
      recover: recover,
      onRecovered: onRecovered,
      close: close,
    ),
  );
}

class _RecoveryBody extends StatefulWidget {
  const _RecoveryBody({super.key, this.recover, this.onRecovered, this.close});
  final Future<void> Function()? recover, onRecovered, close;
  @override
  State<_RecoveryBody> createState() => _RecoveryBodyState();
}

class _RecoveryBodyState extends State<_RecoveryBody> {
  bool _busy = false;
  ManagedFsFailure? _failure;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    if (widget.recover != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_resume());
      });
    }
  }

  Future<void> _resume() async {
    if (_busy || widget.recover == null) return;
    final recover = widget.recover!, completed = widget.onRecovered;
    setState(() {
      _busy = true;
      _failure = null;
      _failed = false;
    });
    try {
      final restored = <String>{};
      while (true) {
        try {
          await recover();
          break;
        } on ManagedProfileWipeFailure catch (error) {
          final warnings = error.filesystemFailure?.aclWarnings;
          if (warnings == null ||
              warnings.isEmpty ||
              warnings.any(
                (warning) =>
                    !warning.canContinue ||
                    restored.contains(warning.fingerprint),
              )) {
            rethrow;
          }
          for (final warning in warnings) {
            if (!await restoreRememberedStorageAcl(warning)) rethrow;
            restored.add(warning.fingerprint);
          }
          if (!mounted) return;
        }
      }
      if (mounted && identical(widget.onRecovered, completed)) {
        await completed?.call();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failure = error is ManagedProfileWipeFailure
              ? error.filesystemFailure
              : null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review(ManagedFsFailure failure) async {
    final remember = await showStorageAccessReview(context, failure);
    if (remember == null || !mounted || !identical(_failure, failure)) return;
    for (final warning in failure.aclWarnings) {
      if (!await recordStorageAclApproval(warning, remember: remember)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppL10n.of(context).startupAclApprovalFailed),
            ),
          );
        }
        return;
      }
    }
    if (mounted) await _resume();
  }

  @override
  void dispose() {
    final close = widget.close;
    if (close != null) unawaited(close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
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
                  Icons.delete_outline,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  l.profileErasurePendingTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  l.profileErasurePendingBody,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (_failed) ...[
                  const SizedBox(height: 16),
                  Text(
                    _failure == null
                        ? l.lockWipeStopped
                        : preferencesFailureText(
                                l,
                                managedStorageFailureReason(_failure!),
                              ) ??
                              l.lockWipeStopped,
                  ),
                  if (_failure?.path case final path?) SelectableText(path),
                  if (_failure case final failure?
                      when failure.aclWarnings.isNotEmpty)
                    TextButton(
                      onPressed: () => _review(failure),
                      child: Text(l.storageAclReview),
                    ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                ] else if (widget.recover != null) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _resume,
                    icon: const Icon(Icons.refresh),
                    label: Text(l.lockWipeRetry),
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
