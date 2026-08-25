import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// Whether a kept hardening warning is the one worth interrupting for.
///
/// Three steps can fail after a commit, and only one of them leaves the person
/// anything to do:
///
///   * `padding` — that commit's SIZE is readable to somebody diffing two
///     snapshots. Done is done; the next commit re-pads, and nothing anyone
///     does now un-leaks the one that did not.
///   * `churn` — the slots it reused stand alone in that diff. Same: past.
///   * `sync` — the masking writes are not on the platter YET. This one is
///     about the near future, and "do not pull the power / check the disk" is
///     a real answer.
///
/// So `sync` is announced and the other two wait on the storage screen. A
/// notice the reader cannot act on teaches them to dismiss notices.
@visibleForTesting
bool hardeningWarningIsUrgent(String? warning) =>
    warning != null && warning.startsWith('sync');

/// Tell the person, once per session, when the masking writes behind a commit
/// had not reached the disk.
///
/// Called after the first frame from the home shell, beside the other errands
/// that must not compete with drawing the screen someone is waiting for.
Future<void> maybeWarnHardeningSync(BuildContext context, WidgetRef ref) async {
  final warning = await ref
      .read(appControllerProvider.notifier)
      .containerHardeningWarning();
  if (!context.mounted) return;
  if (!hardeningWarningIsUrgent(warning)) return;

  final l = AppL10n.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.hardeningSyncNoticeTitle),
      content: Text(l.hardeningSyncNoticeBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l.settingsStorageHardeningDismiss),
        ),
      ],
    ),
  );
  // Acknowledged because it was READ, not because it was rendered — the dialog
  // does not close by itself. The storage screen keeps its own line for the
  // other two steps, and clearing here would take those with it, so only the
  // urgent one is dismissed this way.
  await ref.read(appControllerProvider.notifier).acknowledgeHardeningWarning();
}
