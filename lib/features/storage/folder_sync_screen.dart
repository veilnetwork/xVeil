import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/folder_sync_controller.dart';

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
          final path =
              await (pickDirectory ?? FilePicker.getDirectoryPath)();
          if (path == null || path.isEmpty) return;
          await controller.addPair(
            localPath: path,
            id: 'pair-${DateTime.now().microsecondsSinceEpoch}',
          );
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

class _PairCard extends ConsumerWidget {
  const _PairCard({required this.view});

  final FolderSyncPairView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final controller = ref.read(folderSyncControllerProvider.notifier);
    final refusal = view.lastRefusal;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: Text(view.pair.localPath),
            subtitle: Text(
              view.pair.cloudFolderId == null
                  ? l.folderSyncCloudRoot
                  : view.pair.cloudFolderId!,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l.folderSyncRemove,
              onPressed: () => controller.removePair(view.pair.id),
            ),
          ),
          if (refusal != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l.folderSyncRefused(refusal),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
