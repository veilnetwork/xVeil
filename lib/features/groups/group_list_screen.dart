// Group list (groups epic, phase 0, brick 5): the "Channels" tab surface —
// the groups the user belongs to, with a create button. Materialized groups
// (arrived over the wire) show here too, since ingest bumps the change signal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

class GroupListScreen extends ConsumerWidget {
  const GroupListScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final l = AppL10n.of(context);
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.groupCreateTitle),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: l.groupNameHint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(l.groupCreateAction),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final svc = ref.read(groupServiceProvider);
    if (svc == null) return;
    try {
      final gid = await svc.createGroup(name);
      if (context.mounted) context.push('/group/${gid.hex}');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final svc = ref.watch(groupServiceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.navChannels)),
      floatingActionButton: svc == null
          ? null
          : FloatingActionButton(
              heroTag: 'xveil-groups-create',
              onPressed: () => _create(context, ref),
              tooltip: l.groupCreateTitle,
              child: const Icon(Icons.group_add),
            ),
      body: svc == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<int>(
              stream: svc.changes.stream,
              builder: (context, _) =>
                  FutureBuilder<
                    List<
                      ({
                        NodeId groupId,
                        String name,
                        int unread,
                        bool muted,
                        String preview,
                        int lastTs,
                      })
                    >
                  >(
                    future: svc.listGroups(),
                    builder: (context, snap) {
                      final groups = snap.data ?? const [];
                      if (groups.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.campaign_outlined,
                                size: 48,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
                              Text(l.groupEmpty),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: groups.length,
                        itemBuilder: (context, i) {
                          final g = groups[i];
                          return ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                g.name.isEmpty
                                    ? '#'
                                    : g.name.characters.first.toUpperCase(),
                              ),
                            ),
                            title: Text(g.name),
                            // Last-message preview (falls back to the short id
                            // for an empty group).
                            subtitle: Text(
                              g.preview.isEmpty ? g.groupId.short : g.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (g.muted)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Icon(
                                      Icons.volume_off,
                                      size: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                // Unread badge — the chat list's visual language;
                                // a muted group's badge goes low-key.
                                if (g.unread > 0)
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: g.muted
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest
                                        : Theme.of(context).colorScheme.primary,
                                    child: Text(
                                      g.unread > 999 ? '999+' : '${g.unread}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: g.muted
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onPrimary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            onTap: () =>
                                context.push('/group/${g.groupId.hex}'),
                            // Long-press: local notification mute toggle.
                            onLongPress: () async {
                              final l10n = AppL10n.of(context);
                              final muted = g.muted;
                              await showModalBottomSheet<void>(
                                context: context,
                                builder: (sheet) => SafeArea(
                                  child: ListTile(
                                    leading: Icon(
                                      muted
                                          ? Icons.volume_up_outlined
                                          : Icons.volume_off_outlined,
                                    ),
                                    title: Text(
                                      muted
                                          ? l10n.chatMenuUnmute
                                          : l10n.chatMenuMute,
                                    ),
                                    onTap: () {
                                      Navigator.of(sheet).pop();
                                      svc.setGroupMuted(g.groupId, !muted);
                                    },
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
            ),
    );
  }
}
