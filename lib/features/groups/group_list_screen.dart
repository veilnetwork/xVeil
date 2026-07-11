// Group list (groups epic, phase 0, brick 5): the "Channels" tab surface —
// the groups the user belongs to, with a create button. Materialized groups
// (arrived over the wire) show here too, since ingest bumps the change signal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/group.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';

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
    final gid = await svc.createGroup(name);
    if (context.mounted) context.push('/group/${gid.hex}');
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
              onPressed: () => _create(context, ref),
              tooltip: l.groupCreateTitle,
              child: const Icon(Icons.group_add),
            ),
      body: svc == null
          ? const Center(child: CircularProgressIndicator())
          : AnimatedBuilder(
              animation: svc.changes,
              builder: (context, _) => FutureBuilder<List<GroupManifest>>(
                future: svc.listGroups(),
                builder: (context, snap) {
                  final groups = snap.data ?? const [];
                  if (groups.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.campaign_outlined,
                              size: 48,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant),
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
                          child: Text(g.name.isEmpty
                              ? '#'
                              : g.name.characters.first.toUpperCase()),
                        ),
                        title: Text(g.name),
                        subtitle: Text(g.groupId.short),
                        onTap: () => context.push('/group/${g.groupId.hex}'),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}
