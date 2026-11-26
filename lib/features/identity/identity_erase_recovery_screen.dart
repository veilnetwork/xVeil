import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/identity_erase_review.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../bootstrap/startup_failed_app.dart' show reviewStorageOperationAccess;
import '../settings/error_report.dart';

class IdentityEraseRecoveryScreen extends ConsumerStatefulWidget {
  const IdentityEraseRecoveryScreen({super.key});
  @override
  ConsumerState<IdentityEraseRecoveryScreen> createState() => _RecoveryState();
}

class _RecoveryState extends ConsumerState<IdentityEraseRecoveryScreen> {
  bool _busy = false, _confirming = false;

  Future<void> _retry({IdentityEraseReview? review}) async {
    if (_busy || _confirming) return;
    setState(() => _busy = true);
    var completed = false;
    try {
      completed = await ref
          .read(appControllerProvider.notifier)
          .retryIdentityErasure(review: review);
    } catch (_) {
      // The controller retains the operation/owner. No raw exception reaches
      // the screen or clipboard; diagnostics use the existing allowlist.
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
    if (!mounted ||
        completed ||
        ref.read(appControllerProvider).phase !=
            AppPhase.identityEraseRecovery) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).identityEraseRecoveryFailed)),
    );
  }

  Future<void> _review() async {
    if (_busy || _confirming) return;
    setState(() => _busy = true);
    IdentityEraseReview? review;
    var confirmed = false;
    try {
      review = await ref
          .read(appControllerProvider.notifier)
          .reviewIdentityErasure();
      if (!mounted ||
          ref.read(appControllerProvider).phase !=
              AppPhase.identityEraseRecovery) {
        return;
      }
      final l = AppL10n.of(context);
      final reviewed = review;
      if (reviewed == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.identityEraseRecoveryFailed)));
        return;
      }
      setState(() {
        _busy = false;
        _confirming = true;
      });
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: Text(l.identityEraseReviewTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.identityEraseReviewSummary(
                      reviewed.files,
                      reviewed.directories,
                      reviewed.bytes,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(l.identityEraseReviewWarning),
                  if (reviewed.paths.isNotEmpty)
                    SizedBox(
                      width: 360,
                      height: 160,
                      child: ListView.builder(
                        primary: false,
                        itemCount: reviewed.paths.length,
                        itemBuilder: (context, index) =>
                            SelectableText(reviewed.paths[index]),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(
                    MaterialLocalizations.of(context).cancelButtonLabel,
                  ),
                ),
                FilledButton(
                  key: const Key('identity-erase-review-confirm'),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l.identityEraseReviewConfirm),
                ),
              ],
            ),
          ) ??
          false;
    } catch (_) {
      // No native exception/path/token in UI or clipboard.
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
    if (confirmed &&
        mounted &&
        ref.read(appControllerProvider).phase ==
            AppPhase.identityEraseRecovery) {
      await _retry(review: review);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final accessFailure = ref.watch(
      appControllerProvider.select((state) => state.storageAccessFailure),
    );
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.pending_actions_outlined,
                      size: 56,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l.identityEraseRecoveryTitle,
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.identityEraseRecoveryBody,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('identity-erase-retry'),
                      onPressed: _busy || _confirming ? null : () => _retry(),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(l.lockWipeRetry),
                    ),
                    if (accessFailure != null)
                      TextButton(
                        onPressed: _busy || _confirming
                            ? null
                            : () => reviewStorageOperationAccess(
                                context,
                                accessFailure,
                                stillCurrent: () => identical(
                                  ref
                                      .read(appControllerProvider)
                                      .storageAccessFailure,
                                  accessFailure,
                                ),
                              ),
                        child: Text(l.storageAclReview),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('identity-erase-review'),
                      onPressed: _busy || _confirming ? null : _review,
                      icon: const Icon(Icons.folder_open),
                      label: Text(l.identityEraseReview),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('identity-erase-lock'),
                      onPressed: () =>
                          ref.read(appControllerProvider.notifier).lock(),
                      icon: const Icon(Icons.lock_outline),
                      label: Text(l.identityEraseRecoveryLock),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l.identityEraseRecoveryHint,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const CopyErrorReportTile(phase: 'identityEraseRecovery'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
