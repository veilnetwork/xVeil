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

/// Put the notice up and wait for it to be READ.
///
/// Returns true only when the person pressed the button. NOT dismissible by
/// tapping past it, and not by Back: the acknowledgement this gates clears the
/// container's record for good, and a barrier tap completes the same future a
/// button press does — so the default dialog acknowledged a warning that may
/// never have been looked at. One stray tap while the dialog was appearing and
/// the only notice of an unsynced commit was gone (report14 X14-L1).
///
/// Separated from [maybeWarnHardeningSync] so the way out can be tested
/// without the whole controller behind it.
@visibleForTesting
Future<bool> showHardeningSyncDialog(BuildContext context) async {
  final l = AppL10n.of(context);
  final read = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l.hardeningSyncNoticeTitle),
        content: Text(l.hardeningSyncNoticeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.settingsStorageHardeningDismiss),
          ),
        ],
      ),
    ),
  );
  return read == true;
}

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

  final read = await showHardeningSyncDialog(context);
  // Anything but the button — a route torn down with the screen, say — leaves
  // the warning standing for the next session.
  if (!read) return;
  // Acknowledged because it was READ. The storage screen keeps its own line
  // for the other two steps, and clearing here would take those with it, so
  // only the urgent one is dismissed this way.
  //
  // A container that refuses the acknowledgement leaves it unacknowledged on
  // both sides by contract, so the notice returns next session — which is the
  // right outcome and not worth taking a post-frame errand down over.
  try {
    await ref
        .read(appControllerProvider.notifier)
        .acknowledgeHardeningWarning();
  } catch (_) {
    // Deliberately quiet: the record survives, and the next session shows it.
  }
}
