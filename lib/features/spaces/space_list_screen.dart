import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../domain/group.dart';
import '../../domain/space_invite.dart';
import '../../domain/space_join_request.dart';
import '../../domain/space_lifecycle.dart';
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

  Future<void> _requestJoin(BuildContext context, GroupService service) async {
    final l = AppL10n.of(context);
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinSpaceDialog(),
    );
    if (code == null) return;
    final ok = await service.requestToJoinSpace(code);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l.spaceJoinRequestSent : l.spaceOperationFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final spaces = ref.watch(spaceListProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.navCommunities),
        actions: [
          if (service != null)
            IconButton(
              key: const ValueKey('space-join-link-action'),
              tooltip: l.spaceJoinAction,
              onPressed: () => _requestJoin(context, service),
              icon: const Icon(Icons.link),
            ),
        ],
      ),
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
          return FutureBuilder<List<Object?>>(
            future: service == null
                ? Future.value(const <Object?>[
                    <PendingSpaceInvite>[],
                    <SpaceJoinOutboxEntry>[],
                  ])
                : Future.wait<Object?>([
                    service.pendingSpaceInvites(),
                    service.outgoingSpaceJoinRequests(),
                  ]),
            builder: (context, inviteSnapshot) {
              if (service != null && !inviteSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = inviteSnapshot.data;
              final invites = data == null
                  ? const <PendingSpaceInvite>[]
                  : data[0] as List<PendingSpaceInvite>;
              final joinRequests = data == null
                  ? const <SpaceJoinOutboxEntry>[]
                  : data[1] as List<SpaceJoinOutboxEntry>;
              if (items.isEmpty && invites.isEmpty && joinRequests.isEmpty) {
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
                  if (joinRequests.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        l.spaceJoinRequestsTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (final entry in joinRequests)
                      Card(
                        key: ValueKey(
                          'space-join-outgoing-${entry.request.requestId}',
                        ),
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.how_to_reg_outlined),
                          ),
                          title: Text(entry.ticket.spaceName),
                          subtitle: Text(
                            entry.approved
                                ? l.spaceJoinRequestApproved
                                : entry.declined
                                ? l.spaceJoinRequestDeclined
                                : l.spaceJoinRequestPending,
                          ),
                          trailing: entry.declined
                              ? TextButton(
                                  onPressed: () =>
                                      service?.dismissSpaceJoinRequest(
                                        entry.request.requestId,
                                      ),
                                  child: Text(l.spaceJoinDismiss),
                                )
                              : const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                          trailing:
                              space.unread == 0 &&
                                  space.postUnread == 0 &&
                                  space.lifecycleState ==
                                      SpaceLifecycleState.active
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (space.lifecycleState ==
                                        SpaceLifecycleState.archived) ...[
                                      const Icon(
                                        Icons.archive_outlined,
                                        size: 18,
                                      ),
                                      if (space.unread > 0 ||
                                          space.postUnread > 0)
                                        const SizedBox(width: 10),
                                    ],
                                    if (space.lifecycleState ==
                                        SpaceLifecycleState.deleted) ...[
                                      Icon(
                                        Icons.delete_forever_outlined,
                                        size: 18,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                      if (space.unread > 0 ||
                                          space.postUnread > 0)
                                        const SizedBox(width: 10),
                                    ],
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

class _JoinSpaceDialog extends StatefulWidget {
  const _JoinSpaceDialog();

  @override
  State<_JoinSpaceDialog> createState() => _JoinSpaceDialogState();
}

class _JoinSpaceDialogState extends State<_JoinSpaceDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    setState(() => _code.text = data!.text!.trim());
  }

  void _submit() {
    final value = _code.text.trim();
    if (value.isEmpty || value.length > 2048) return;
    try {
      SpaceJoinCode.parse(value);
    } catch (_) {
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceJoinDialogTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('space-join-code'),
              controller: _code,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              maxLength: 2048,
              decoration: InputDecoration(
                labelText: l.spaceJoinCodeHint,
                suffixIcon: IconButton(
                  tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              l.spaceJoinSafetyHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-join-submit'),
          onPressed: _code.text.trim().isEmpty ? null : _submit,
          child: Text(l.spaceJoinAction),
        ),
      ],
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
