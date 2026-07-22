import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/group.dart';
import '../../domain/space_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

/// User-facing list of communities. Group chats remain in the Chats section.
class SpaceListScreen extends ConsumerWidget {
  const SpaceListScreen({super.key});

  Future<void> _decideInvite(
    BuildContext context,
    GroupService service,
    String inviteId, {
    required bool accept,
  }) async {
    final ok = await service.decideSpaceInvite(inviteId, accept: accept);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final l = AppL10n.of(context);
    final draft = await showDialog<_NewSpaceDraft>(
      context: context,
      builder: (_) => const _CreateSpaceDialog(),
    );
    if (draft == null) return;
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    try {
      final id = await service.createSpace(
        draft.name,
        description: draft.description,
        visibility: draft.visibility,
      );
      if (context.mounted) context.push('/space/${id.hex}');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final spaces = ref.watch(spaceListProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.navCommunities)),
      floatingActionButton: service == null
          ? null
          : FloatingActionButton(
              heroTag: 'xveil-spaces-create',
              tooltip: l.spaceCreateTitle,
              onPressed: () => _create(context, ref),
              child: const Icon(Icons.add),
            ),
      body: spaces.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) {
          return FutureBuilder<List<PendingSpaceInvite>>(
            future: service?.pendingSpaceInvites(),
            builder: (context, inviteSnapshot) {
              if (service != null && !inviteSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final invites = inviteSnapshot.data ?? const [];
              if (items.isEmpty && invites.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.diversity_3_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(l.spaceEmpty),
                    ],
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (invites.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        l.spaceInvitesTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (final pending in invites)
                      Card(
                        key: ValueKey(
                          'space-invite-${pending.invite.inviteId}',
                        ),
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.mark_email_unread_outlined),
                          ),
                          title: Text(
                            pending.invite.spaceName.isEmpty
                                ? l.spaceSecretInviteTitle
                                : pending.invite.spaceName,
                          ),
                          subtitle: Text(
                            pending.accepted
                                ? l.spaceInviteJoining
                                : l.spaceInviteFrom(
                                    pending.invite.inviter.short,
                                  ),
                          ),
                          trailing: pending.accepted || service == null
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Wrap(
                                  spacing: 4,
                                  children: [
                                    TextButton(
                                      key: ValueKey(
                                        'space-invite-decline-${pending.invite.inviteId}',
                                      ),
                                      onPressed: () => _decideInvite(
                                        context,
                                        service,
                                        pending.invite.inviteId,
                                        accept: false,
                                      ),
                                      child: Text(l.spaceInviteDecline),
                                    ),
                                    FilledButton.tonal(
                                      key: ValueKey(
                                        'space-invite-accept-${pending.invite.inviteId}',
                                      ),
                                      onPressed: () => _decideInvite(
                                        context,
                                        service,
                                        pending.invite.inviteId,
                                        accept: true,
                                      ),
                                      child: Text(l.spaceInviteAccept),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                  for (var index = 0; index < items.length; index++) ...[
                    if (index > 0) const Divider(height: 1, indent: 72),
                    Builder(
                      builder: (context) {
                        final space = items[index];
                        return ListTile(
                          leading: CircleAvatar(
                            child: space.visibility == SpaceVisibility.secret
                                ? const Icon(Icons.lock_outline)
                                : space.visibility == SpaceVisibility.public
                                ? const Icon(Icons.public)
                                : Text(
                                    space.name.isEmpty
                                        ? '#'
                                        : space.name.characters.first
                                              .toUpperCase(),
                                  ),
                          ),
                          title: Text(space.name),
                          subtitle: Text(
                            space.description.isNotEmpty
                                ? space.description
                                : space.preview.isEmpty
                                ? space.groupId.short
                                : space.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: space.unread == 0 && space.postUnread == 0
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (space.unread > 0) ...[
                                      const Icon(
                                        Icons.chat_bubble_outline,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Badge(label: Text('${space.unread}')),
                                    ],
                                    if (space.unread > 0 &&
                                        space.postUnread > 0)
                                      const SizedBox(width: 10),
                                    if (space.postUnread > 0) ...[
                                      const Icon(
                                        Icons.campaign_outlined,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Badge(label: Text('${space.postUnread}')),
                                    ],
                                  ],
                                ),
                          onTap: () =>
                              context.push('/space/${space.groupId.hex}'),
                        );
                      },
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

typedef _NewSpaceDraft = ({
  String name,
  String description,
  SpaceVisibility visibility,
});

class _CreateSpaceDialog extends StatefulWidget {
  const _CreateSpaceDialog();

  @override
  State<_CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<_CreateSpaceDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  SpaceVisibility _visibility = SpaceVisibility.private;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((
      name: name,
      description: _description.text.trim(),
      visibility: _visibility,
    ));
  }

  String _visibilityLabel(AppL10n l, SpaceVisibility visibility) =>
      switch (visibility) {
        SpaceVisibility.public => l.spaceVisibilityPublic,
        SpaceVisibility.private => l.spaceVisibilityPrivate,
        SpaceVisibility.secret => l.spaceVisibilitySecret,
      };

  String _visibilityHint(AppL10n l) => switch (_visibility) {
    SpaceVisibility.public => l.spaceVisibilityPublicHint,
    SpaceVisibility.private => l.spaceVisibilityPrivateHint,
    SpaceVisibility.secret => l.spaceVisibilitySecretHint,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceCreateTitle),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('space-create-name'),
                controller: _name,
                autofocus: true,
                maxLength: 160,
                decoration: InputDecoration(labelText: l.spaceNameHint),
                textInputAction: TextInputAction.next,
              ),
              TextField(
                key: const ValueKey('space-create-description'),
                controller: _description,
                maxLength: 4096,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l.spaceDescriptionLabel,
                  hintText: l.spaceDescriptionHint,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<SpaceVisibility>(
                key: const ValueKey('space-create-visibility'),
                initialValue: _visibility,
                decoration: InputDecoration(labelText: l.spaceVisibilityLabel),
                items: [
                  for (final visibility in SpaceVisibility.values)
                    DropdownMenuItem(
                      value: visibility,
                      child: Text(_visibilityLabel(l, visibility)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _visibility = value);
                },
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: Text(
                  _visibilityHint(l),
                  key: ValueKey(_visibility),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l.spaceCreateAction)),
      ],
    );
  }
}
