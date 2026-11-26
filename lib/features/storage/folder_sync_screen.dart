import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/folder_sync.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/identity_guard.dart';
import '../../state/folder_sync_controller.dart';
import '../bootstrap/startup_failed_app.dart' show StorageAclDetails;
import '../common/relative_time.dart';
import 'folder_saved_versions_dialog.dart';

/// Configure which local folders mirror which Storage folders, and answer the
/// conflicts a pass could not decide.
///
/// Conflicts are shown here rather than as a notification because answering
/// one is not urgent: nothing was overwritten and nothing is lost while it
/// waits. What matters is that the answer is a deliberate choice, made looking
/// at both sides.
class FolderSyncScreen extends ConsumerWidget {
  const FolderSyncScreen({super.key, this.pickDirectory});

  /// Injected in tests, where no native picker exists.
  final Future<String?> Function()? pickDirectory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final pairs = ref.watch(folderSyncControllerProvider);
    final controller = ref.read(folderSyncControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.folderSyncTitle),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          // Taken BEFORE the native picker, which is the long await here. The
          // notifier is reused across a switch and its store is repointed to
          // B, so a path chosen from A's screen became a pair of B's and B's
          // scheduler uploaded those local files into B's cloud.
          final lease = ref.leaseIdentity();
          final path = await (pickDirectory ?? FilePicker.getDirectoryPath)();
          if (path == null || path.isEmpty) return;
          if (!ref.holdsIdentity(lease)) return;
          final id = 'pair-${DateTime.now().microsecondsSinceEpoch}';
          final refusal = await controller.addPair(
            localPath: path,
            id: id,
            owner: lease,
          );
          if (refusal == null || !context.mounted) return;
          await _reviewRoot(context, refusal, (approval) async {
            if (!context.mounted || !ref.holdsIdentity(lease)) return null;
            return controller.addPair(
              localPath: path,
              id: id,
              owner: lease,
              rootApproval: approval,
            );
          }, adding: true);
        },
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(l.folderSyncAdd),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              l.folderSyncHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              l.folderSyncDeleteWarning,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (pairs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(l.folderSyncEmpty)),
            ),
          for (final view in pairs) _PairCard(view: view),
        ],
      ),
    );
  }
}

/// The sentence for a refusal code, in the reader's language.
///
/// Lives here rather than on [FolderSyncRefusal] because the controller has no
/// [BuildContext] and must not acquire one: a rule that decides whether a
/// folder is safe has no business knowing what language the person reads.
/// Null when there is nothing to say, which is not the same as no refusal.
String? folderSyncRefusalText(AppL10n l, FolderSyncRefusal refusal) {
  final path = refusal.path ?? '';
  return switch (refusal.code) {
    // Silence on purpose: see the code's own doc.
    FolderSyncRefusalCode.identityChanged => null,
    FolderSyncRefusalCode.pathChanged => l.folderSyncRefusedPathChanged,
    FolderSyncRefusalCode.confirmationRequired =>
      l.folderSyncConfirmExistingRoot(path),
    FolderSyncRefusalCode.redirectableWindowsPath =>
      l.folderSyncWindowsRootRedirectable(path),
    FolderSyncRefusalCode.overlapsExistingPair => l.folderSyncRefusedOverlap,
    FolderSyncRefusalCode.unresolvable => l.folderSyncRefusedUnresolvable(
      path,
      refusal.detail ?? '',
    ),
    FolderSyncRefusalCode.osAccessDenied => l.folderSyncReadAccessDenied(path),
    FolderSyncRefusalCode.permissionsUnreadable =>
      l.folderSyncRefusedUnreadable(path),
    FolderSyncRefusalCode.readableByOtherAccounts => l.folderSyncAclReadRisk,
    FolderSyncRefusalCode.traversalByOtherAccounts =>
      l.folderSyncAclTraversalRisk,
    FolderSyncRefusalCode.writableByOtherAccounts =>
      l.folderSyncRefusedWritable(path),
  };
}

Future<void> _reviewRoot(
  BuildContext context,
  FolderSyncRefusal refusal,
  Future<FolderSyncRefusal?> Function(FolderSyncRootApproval) confirm, {
  bool adding = false,
}) async {
  var current = refusal;
  while (true) {
    if (!context.mounted) return;
    final warning = current.aclWarning;
    final approval = current.approval;
    final l = AppL10n.of(context);
    final message = folderSyncRefusalText(l, current);
    if (message == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(
          adding && approval == null
              ? l.folderSyncNotAddedTitle
              : l.startupAclWarningTitle,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              approval != null
                  ? approval.writeAccess
                        ? l.folderSyncAclRisk
                        : message
                  : adding
                  ? l.folderSyncNotAdded(message)
                  : message,
            ),
            if (warning != null) ...[
              const SizedBox(height: 8),
              StorageAclDetails(warning),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(approval == null ? l.actionDone : l.actionCancel),
          ),
          if (approval != null)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.folderSyncAclAccept),
            ),
        ],
      ),
    );
    if (accepted != true || approval == null || !context.mounted) return;
    final next = await confirm(approval);
    if (next == null) return;
    current = next;
  }
}

class _PairCard extends ConsumerWidget {
  const _PairCard({required this.view});

  final FolderSyncPairView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final controller = ref.read(folderSyncControllerProvider.notifier);
    final rootRefusal = view.rootRefusal;
    final lastRefusal = view.lastRefusal;
    final readIssue = view.readIssue;
    final refusal = rootRefusal != null
        ? folderSyncRefusalText(l, rootRefusal)
        : lastRefusal == FolderSyncRefusalCode.pathChanged.name
        ? l.folderSyncRefusedPathChanged
        : switch (FolderSyncScanRefusal.values
              .where((code) => code.name == lastRefusal)
              .firstOrNull) {
            FolderSyncScanRefusal.accessDenied => l.folderSyncScanAccessDenied,
            FolderSyncScanRefusal.unavailable => l.folderSyncScanUnavailable,
            FolderSyncScanRefusal.busy => l.folderSyncScanBusy,
            FolderSyncScanRefusal.rootChanged => l.folderSyncScanRootChanged,
            null =>
              FolderSyncRefusalCode.values.any(
                    (code) => code.name == lastRefusal,
                  )
                  ? null
                  : lastRefusal,
          };
    final readRefusal = switch (readIssue) {
      (path: final path, reason: FolderSyncAccessRefusal.accessDenied) =>
        l.folderSyncReadAccessDenied(path),
      (path: final path, reason: FolderSyncAccessRefusal.cannotVerify) =>
        l.folderSyncReadCannotVerify(path),
      null => null,
    };
    final writeRefusal = switch (view.writeIssue) {
      (path: final path, reason: FolderSyncAccessRefusal.accessDenied) =>
        l.folderSyncWriteAccessDenied(path),
      (path: final path, reason: FolderSyncAccessRefusal.cannotVerify) =>
        l.folderSyncWriteCannotVerify(path),
      null => null,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: Text(view.pair.localPath),
            // Where it mirrors to, and WHEN it last ran. The second line was
            // missing entirely: `lastPassAtMs` was carried all the way into
            // the view and never shown, and the string for the null case
            // (`folderSyncNever`) sat unused in both ARB files. A mirror that
            // never says when it last ran is one you cannot trust without
            // opening the folder and looking.
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  view.pair.cloudFolderId == null
                      ? l.folderSyncCloudRoot
                      : view.pair.cloudFolderId!,
                ),
                Text(
                  view.lastPassAtMs == null
                      ? l.folderSyncNever
                      : l.folderSyncLastPass(
                          formatAgoL10n(
                            l,
                            DateTime.now().difference(
                              DateTime.fromMillisecondsSinceEpoch(
                                view.lastPassAtMs!,
                              ),
                            ),
                          ),
                        ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l.folderSyncRemove,
              onPressed: () => controller.removePair(view.pair.id),
            ),
          ),
          if (refusal != null || readRefusal != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                refusal == null ? readRefusal! : l.folderSyncRefused(refusal),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (writeRefusal != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                writeRefusal,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (rootRefusal?.rootIdentity case final identity?)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: view.busy
                    ? null
                    : () async {
                        final lease = ref.leaseIdentity();
                        final accepted = await showDialog<bool>(
                          context: context,
                          builder: (dialog) => AlertDialog(
                            title: Text(l.folderSyncConfirmRoot),
                            content: Text(
                              l.folderSyncConfirmExistingRoot(
                                view.pair.localPath,
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialog, false),
                                child: Text(l.actionCancel),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(dialog, true),
                                child: Text(l.folderSyncConfirmRoot),
                              ),
                            ],
                          ),
                        );
                        if (!context.mounted || accepted != true) return;
                        final refusal = await controller.confirmPairRoot(
                          view.pair.id,
                          identity,
                          owner: lease,
                        );
                        if (!context.mounted || refusal == null) return;
                        await _reviewRoot(
                          context,
                          refusal,
                          (approval) => controller.approvePair(
                            view.pair.id,
                            approval,
                            owner: lease,
                          ),
                        );
                      },
                child: Text(l.folderSyncConfirmRoot),
              ),
            ),
          SwitchListTile(
            title: Text(l.folderSyncPropagateDeletions),
            subtitle: Text(l.folderSyncPropagateDeletionsHelp),
            value: view.pair.deletePropagates,
            onChanged: view.busy
                ? null
                : (enabled) => controller.setDeletePropagation(
                    view.pair.id,
                    enabled,
                    owner: ref.leaseIdentity(),
                  ),
          ),
          if (rootRefusal?.aclWarning != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: view.busy
                    ? null
                    : () async {
                        final lease = ref.leaseIdentity();
                        await _reviewRoot(
                          context,
                          rootRefusal!,
                          (approval) => controller.approvePair(
                            view.pair.id,
                            approval,
                            owner: lease,
                          ),
                        );
                      },
                child: Text(l.folderSyncAclReview),
              ),
            ),
          if (view.conflicts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                l.folderSyncConflictsTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                l.folderSyncConflictExplain,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final path in view.conflicts.toList()..sort())
              ListTile(
                dense: true,
                leading: const Icon(Icons.call_split_outlined),
                title: Text(path),
                // The answer is recorded, not carried out here: acting needs
                // both copies as they are at the moment of the next pass.
                subtitle: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => controller.resolveConflict(
                        view.pair.id,
                        path,
                        keepLocal: true,
                      ),
                      child: Text(l.folderSyncKeepLocal),
                    ),
                    TextButton(
                      onPressed: () => controller.resolveConflict(
                        view.pair.id,
                        path,
                        keepLocal: false,
                      ),
                      child: Text(l.folderSyncKeepCloud),
                    ),
                  ],
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    var pair = view.pair;
                    final lease = ref.leaseIdentity();
                    FolderSyncRefusal? inspect() {
                      final identity =
                          pair.rootIdentity ?? pair.rootApproval?.identity;
                      if (identity == null) {
                        return FolderSyncRefusal(
                          FolderSyncRefusalCode.confirmationRequired,
                          path: pair.localPath,
                        );
                      }
                      return folderSyncRootRefusal(
                        pair.localPath,
                        approval: pair.rootApproval,
                        expectedIdentity: identity,
                      );
                    }

                    await showDialog<void>(
                      context: context,
                      builder: (_) => FolderSavedVersionsDialog(
                        root: pair.localPath,
                        rootRefusal: () {
                          final refusal = inspect();
                          return refusal == null
                              ? null
                              : folderSyncRefusalText(l, refusal);
                        },
                        reviewRoot: (dialog) async {
                          final refusal = inspect();
                          if (refusal?.aclWarning == null) return;
                          await _reviewRoot(dialog, refusal!, (approval) async {
                            final next = await controller.approvePair(
                              pair.id,
                              approval,
                              owner: lease,
                            );
                            if (next == null &&
                                context.mounted &&
                                ref.holdsIdentity(lease)) {
                              pair =
                                  ref
                                      .read(folderSyncControllerProvider)
                                      .where(
                                        (entry) => entry.pair.id == pair.id,
                                      )
                                      .firstOrNull
                                      ?.pair ??
                                  pair;
                            }
                            return next;
                          });
                        },
                        canReviewRoot: () => inspect()?.aclWarning != null,
                      ),
                    );
                  },
                  icon: const Icon(Icons.history),
                  label: Text(l.folderSyncSavedTitle),
                ),
                if (view.busy)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(l.folderSyncBusy),
                  ),
                FilledButton.tonalIcon(
                  onPressed: view.busy
                      ? null
                      : () => controller.runOnce(view.pair),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l.folderSyncRunNow),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
