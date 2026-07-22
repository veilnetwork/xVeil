import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_retention.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show conversationsProvider;

enum _SpaceMemberAction { unmute, promote, demote, remove, transferOwner }

/// The Space-native management surface. It deliberately writes through the
/// existing signed control log: the UI only predicts permissions for clarity;
/// GroupService and the fold remain authoritative for every mutation.
class SpaceSettingsScreen extends ConsumerStatefulWidget {
  const SpaceSettingsScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  @override
  ConsumerState<SpaceSettingsScreen> createState() =>
      _SpaceSettingsScreenState();
}

class _SpaceSettingsScreenState extends ConsumerState<SpaceSettingsScreen> {
  NodeId? get _spaceId {
    try {
      return NodeId.fromHex(widget.spaceIdHex);
    } catch (_) {
      return null;
    }
  }

  void _failure() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
    );
  }

  String _roleLabel(AppL10n l, GroupRole role) => switch (role) {
    GroupRole.owner => l.spaceRoleOwner,
    GroupRole.admin => l.spaceRoleAdmin,
    GroupRole.member => l.spaceRoleMember,
  };

  String _visibilityLabel(AppL10n l, SpaceVisibility? visibility) =>
      switch (visibility) {
        SpaceVisibility.public => l.spaceVisibilityPublic,
        SpaceVisibility.private => l.spaceVisibilityPrivate,
        SpaceVisibility.secret => l.spaceVisibilitySecret,
        null => l.spaceVisibilityPrivate,
      };

  int? _retentionDays(SpaceRetentionPolicy policy) =>
      policy.mode == SpaceRetentionMode.deleteAfter
      ? policy.retentionMs! ~/ const Duration(days: 1).inMilliseconds
      : null;

  Future<void> _setGlobalRetention(
    GroupService service,
    NodeId spaceId,
    int? days,
  ) async {
    final policy = days == null
        ? const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever)
        : SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: Duration(days: days).inMilliseconds,
          );
    if (!await service.setSpaceRetentionPolicy(spaceId, policy)) _failure();
  }

  Future<void> _setLocalRetention(
    GroupService service,
    NodeId spaceId,
    int? days,
  ) async {
    if (!await service.setLocalSpaceRetentionDays(spaceId, days)) _failure();
  }

  String _memberLabel(
    AppL10n l,
    GroupService service,
    NodeId member,
    List<Conversation> conversations,
  ) {
    if (member == service.selfId) return l.spaceYou;
    for (final conversation in conversations) {
      if (conversation.peer.nodeId == member) return conversation.peer.label;
    }
    return member.short;
  }

  Future<void> _rename(
    GroupService service,
    NodeId spaceId,
    String current,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameSpaceDialog(current: current),
    );
    if (name == null || name.isEmpty || name == current) return;
    if (!await service.renameGroup(spaceId, name)) _failure();
  }

  Future<void> _editDescription(
    GroupService service,
    NodeId spaceId,
    String current,
  ) async {
    final description = await showDialog<String>(
      context: context,
      builder: (_) => _DescriptionDialog(current: current),
    );
    if (description == null || description == current) return;
    if (!await service.setSpaceDescription(spaceId, description)) _failure();
  }

  Future<void> _inviteMember(
    GroupService service,
    NodeId spaceId,
    GroupState state,
    List<Conversation> conversations,
  ) async {
    final l = AppL10n.of(context);
    final candidates = [
      for (final conversation in conversations)
        if (conversation.peer.status == ContactStatus.accepted &&
            !state.isMember(conversation.peer.nodeId))
          conversation.peer,
    ];
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceNoContactsToAdd)));
      return;
    }
    final myRole = state.roleOf(service.selfId)!;
    var selected = candidates.first.nodeId.hex;
    var role = GroupRole.member;
    final canGrantAdmin = canApply(
      authorRole: myRole,
      op: ControlOp.addMember,
      newRole: GroupRole.admin,
    );
    final picked = await showDialog<(NodeId, GroupRole)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.spaceMemberAdd),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  items: [
                    for (final candidate in candidates)
                      DropdownMenuItem(
                        value: candidate.nodeId.hex,
                        child: Text(
                          '${candidate.label} · ${candidate.nodeId.short}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selected = value);
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<GroupRole>(
                  initialValue: role,
                  decoration: InputDecoration(labelText: l.spaceRoleLabel),
                  items: [
                    DropdownMenuItem(
                      value: GroupRole.member,
                      child: Text(l.spaceRoleMember),
                    ),
                    if (canGrantAdmin)
                      DropdownMenuItem(
                        value: GroupRole.admin,
                        child: Text(l.spaceRoleAdmin),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => role = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop((NodeId.fromHex(selected), role)),
              child: Text(l.spaceMemberAdd),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final sent = await service.inviteToSpace(
      spaceId,
      picked.$1,
      role: picked.$2,
    );
    if (!sent) {
      _failure();
    } else if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceInviteSent)));
    }
  }

  Future<void> _memberAction(
    GroupService service,
    NodeId spaceId,
    GroupMember member,
    String label,
    _SpaceMemberAction action,
  ) async {
    if (action == _SpaceMemberAction.remove) {
      final l = AppL10n.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text(l.spaceMemberRemoveConfirm(label)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l.spaceMemberRemove),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    } else if (action == _SpaceMemberAction.transferOwner) {
      final l = AppL10n.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text(l.spaceMemberTransferOwnershipConfirm(label)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l.spaceMemberTransferOwnership),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final (operation, role) = switch (action) {
      _SpaceMemberAction.unmute => (ControlOp.unmute, null),
      _SpaceMemberAction.promote => (ControlOp.setRole, GroupRole.admin),
      _SpaceMemberAction.demote => (ControlOp.setRole, GroupRole.member),
      _SpaceMemberAction.remove => (ControlOp.removeMember, null),
      _SpaceMemberAction.transferOwner => (ControlOp.transferOwnership, null),
    };
    final applied = action == _SpaceMemberAction.transferOwner
        ? await service.transferSpaceOwnership(spaceId, member.nodeId)
        : await service.addControlOp(
            spaceId,
            operation,
            target: member.nodeId,
            role: role,
          );
    if (!applied) _failure();
  }

  Future<void> _leave(GroupService service, NodeId spaceId) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.spaceLeave),
        content: Text(l.spaceLeaveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.spaceLeave),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await service.leaveGroup(spaceId)) {
      _failure();
      return;
    }
    if (mounted) context.go('/spaces');
  }

  List<PopupMenuEntry<_SpaceMemberAction>> _actionsFor(
    AppL10n l,
    GroupRole myRole,
    GroupMember member,
  ) {
    final actions = <PopupMenuEntry<_SpaceMemberAction>>[];
    if (member.muted &&
        canApply(
          authorRole: myRole,
          op: ControlOp.unmute,
          targetRole: member.role,
        )) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.unmute,
          child: Text(l.spaceMemberUnmute),
        ),
      );
    }
    if (member.role == GroupRole.member &&
        canApply(
          authorRole: myRole,
          op: ControlOp.setRole,
          targetRole: member.role,
          newRole: GroupRole.admin,
        )) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.promote,
          child: Text(l.spaceMemberPromote),
        ),
      );
    }
    if (member.role == GroupRole.admin &&
        canApply(
          authorRole: myRole,
          op: ControlOp.setRole,
          targetRole: member.role,
          newRole: GroupRole.member,
        )) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.demote,
          child: Text(l.spaceMemberDemote),
        ),
      );
    }
    if (canApply(
      authorRole: myRole,
      op: ControlOp.removeMember,
      targetRole: member.role,
    )) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.remove,
          child: Text(l.spaceMemberRemove),
        ),
      );
    }
    if (canApply(
      authorRole: myRole,
      op: ControlOp.transferOwnership,
      targetRole: member.role,
    )) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.transferOwner,
          child: Text(l.spaceMemberTransferOwnership),
        ),
      );
    }
    return actions;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final spaceId = _spaceId;
    final conversations =
        ref.watch(conversationsProvider).valueOrNull ?? const <Conversation>[];
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (spaceId == null) {
      return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      builder: (context, _) => FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([
          service.stateOf(spaceId),
          service.isSpaceFeedEnabled(spaceId),
          service.load(spaceId),
          service.localSpaceRetentionDays(spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          if (state == null || !state.isMember(service.selfId)) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          final feedEnabled = snapshot.data![1] as bool;
          final bundle = snapshot.data![2] as GroupBundle?;
          final localRetentionDays = snapshot.data![3] as int?;
          final myRole = state.roleOf(service.selfId)!;
          final canRename = canApply(authorRole: myRole, op: ControlOp.setName);
          final canEditDescription = canApply(
            authorRole: myRole,
            op: ControlOp.setDescription,
          );
          final canAdd = canApply(
            authorRole: myRole,
            op: ControlOp.addMember,
            newRole: GroupRole.member,
          );
          final canManageRetention = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.manageStorage);
          final globalRetentionDays = _retentionDays(
            state.effectiveRetentionPolicy(),
          );
          final members = state.members.values.toList()
            ..sort((a, b) {
              final rank = b.role.rank.compareTo(a.role.rank);
              return rank != 0 ? rank : a.nodeId.hex.compareTo(b.nodeId.hex);
            });
          return Scaffold(
            appBar: AppBar(title: Text(l.spaceSettingsTitle)),
            body: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: SizedBox(
                  width: constraints.maxWidth > 760 ? 720 : null,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.diversity_3_outlined),
                              title: Text(state.name),
                              subtitle: Text(
                                '${_roleLabel(l, myRole)} · '
                                '${l.spaceMembers(state.members.length)}',
                              ),
                              trailing: canRename
                                  ? IconButton(
                                      key: const ValueKey(
                                        'space-rename-button',
                                      ),
                                      tooltip: l.spaceRenameTitle,
                                      onPressed: () =>
                                          _rename(service, spaceId, state.name),
                                      icon: const Icon(Icons.edit_outlined),
                                    )
                                  : null,
                            ),
                            const Divider(height: 1, indent: 56),
                            ListTile(
                              key: const ValueKey('space-description-tile'),
                              leading: const Icon(Icons.notes_outlined),
                              title: Text(
                                state.description.isEmpty
                                    ? l.spaceDescriptionHint
                                    : state.description,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${l.spaceVisibilityLabel}: '
                                '${_visibilityLabel(l, bundle?.manifest.visibility)}',
                              ),
                              trailing: canEditDescription
                                  ? IconButton(
                                      key: const ValueKey(
                                        'space-description-edit',
                                      ),
                                      tooltip: l.spaceDescriptionEditTitle,
                                      onPressed: () => _editDescription(
                                        service,
                                        spaceId,
                                        state.description,
                                      ),
                                      icon: const Icon(Icons.edit_note),
                                    )
                                  : null,
                            ),
                            SwitchListTile(
                              secondary: const Icon(Icons.campaign_outlined),
                              title: Text(
                                feedEnabled
                                    ? l.spaceFeedDisable
                                    : l.spaceFeedEnable,
                              ),
                              value: feedEnabled,
                              onChanged: (enabled) => unawaited(
                                service.setSpaceFeedEnabled(spaceId, enabled),
                              ),
                            ),
                            _ReplicationSetting(
                              service: service,
                              spaceId: spaceId,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l.spaceMembers(state.members.length),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (canAdd)
                            FilledButton.tonalIcon(
                              key: const ValueKey('space-add-member'),
                              onPressed: () => _inviteMember(
                                service,
                                spaceId,
                                state,
                                conversations,
                              ),
                              icon: const Icon(Icons.person_add_alt),
                              label: Text(l.spaceMemberAdd),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (var index = 0; index < members.length; index++)
                              Builder(
                                builder: (context) {
                                  final member = members[index];
                                  final label = _memberLabel(
                                    l,
                                    service,
                                    member.nodeId,
                                    conversations,
                                  );
                                  final actions =
                                      member.nodeId == service.selfId
                                      ? <PopupMenuEntry<_SpaceMemberAction>>[]
                                      : _actionsFor(l, myRole, member);
                                  return Column(
                                    children: [
                                      if (index > 0)
                                        const Divider(height: 1, indent: 56),
                                      ListTile(
                                        leading: Icon(
                                          member.role == GroupRole.owner
                                              ? Icons.star_outline
                                              : member.role == GroupRole.admin
                                              ? Icons.shield_outlined
                                              : Icons.person_outline,
                                        ),
                                        title: Text(label),
                                        subtitle: Text(
                                          [
                                            _roleLabel(l, member.role),
                                            member.nodeId.short,
                                            if (member.muted)
                                              l.spaceMemberMuted,
                                          ].join(' · '),
                                        ),
                                        trailing: actions.isEmpty
                                            ? member.muted
                                                  ? const Icon(
                                                      Icons.volume_off_outlined,
                                                    )
                                                  : null
                                            : PopupMenuButton<
                                                _SpaceMemberAction
                                              >(
                                                itemBuilder: (_) => actions,
                                                onSelected: (action) =>
                                                    _memberAction(
                                                      service,
                                                      spaceId,
                                                      member,
                                                      label,
                                                      action,
                                                    ),
                                              ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (myRole == GroupRole.owner)
                        ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: Text(l.spaceOwnerLeaveHint),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () => _leave(service, spaceId),
                          icon: const Icon(Icons.logout),
                          label: Text(l.spaceLeave),
                        ),
                      const SizedBox(height: 12),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.history_toggle_off),
                              title: Text(l.spaceRetentionTitle),
                              subtitle: Text(l.spaceRetentionSafetyHint),
                            ),
                            _RetentionTile(
                              key: const ValueKey('space-global-retention'),
                              title: l.spaceRetentionGlobal,
                              subtitle: l.spaceRetentionGlobalHint,
                              value: globalRetentionDays,
                              enabled: canManageRetention,
                              onChanged: (days) => unawaited(
                                _setGlobalRetention(service, spaceId, days),
                              ),
                            ),
                            _RetentionTile(
                              key: const ValueKey('space-local-retention'),
                              title: l.spaceRetentionLocal,
                              subtitle: l.spaceRetentionLocalHint,
                              value: localRetentionDays,
                              onChanged: (days) => unawaited(
                                _setLocalRetention(service, spaceId, days),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RetentionTile extends StatelessWidget {
  const _RetentionTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final int? value;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: DropdownButton<int>(
        value: value ?? 0,
        underline: const SizedBox.shrink(),
        onChanged: enabled
            ? (next) {
                if (next != null) onChanged(next == 0 ? null : next);
              }
            : null,
        selectedItemBuilder: (_) => [
          for (final text in [
            l.retentionUnlimited,
            l.retention7,
            l.retention30,
            l.retention90,
            l.retention365,
          ])
            SizedBox(
              width: 112,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
        items: [
          DropdownMenuItem(value: 0, child: Text(l.retentionUnlimited)),
          DropdownMenuItem(value: 7, child: Text(l.retention7)),
          DropdownMenuItem(value: 30, child: Text(l.retention30)),
          DropdownMenuItem(value: 90, child: Text(l.retention90)),
          DropdownMenuItem(value: 365, child: Text(l.retention365)),
        ],
      ),
    );
  }
}

class _RenameSpaceDialog extends StatefulWidget {
  const _RenameSpaceDialog({required this.current});

  final String current;

  @override
  State<_RenameSpaceDialog> createState() => _RenameSpaceDialogState();
}

class _RenameSpaceDialogState extends State<_RenameSpaceDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceRenameTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(hintText: l.spaceNameHint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l.spaceRenameAction)),
      ],
    );
  }
}

class _DescriptionDialog extends StatefulWidget {
  const _DescriptionDialog({required this.current});

  final String current;

  @override
  State<_DescriptionDialog> createState() => _DescriptionDialogState();
}

class _DescriptionDialogState extends State<_DescriptionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceDescriptionEditTitle),
      content: SizedBox(
        width: 460,
        child: TextField(
          key: const ValueKey('space-description-field'),
          controller: _controller,
          autofocus: true,
          maxLength: 4096,
          minLines: 4,
          maxLines: 8,
          decoration: InputDecoration(
            hintText: l.spaceDescriptionHint,
            alignLabelWithHint: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l.spaceDescriptionSave)),
      ],
    );
  }
}

class _ReplicationSetting extends StatefulWidget {
  const _ReplicationSetting({required this.service, required this.spaceId});

  final GroupService service;
  final NodeId spaceId;

  @override
  State<_ReplicationSetting> createState() => _ReplicationSettingState();
}

class _ReplicationSettingState extends State<_ReplicationSetting> {
  int? _value;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return FutureBuilder<int>(
      future: widget.service.groupSyncNeighborCount(widget.spaceId),
      builder: (context, snapshot) {
        final count = _value ?? snapshot.data;
        if (count == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.spaceReplicationTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Slider(
                key: const ValueKey('space-replication-slider'),
                min: GroupService.kMinGroupSyncNeighbors.toDouble(),
                max: GroupService.kMaxGroupSyncNeighbors.toDouble(),
                divisions:
                    GroupService.kMaxGroupSyncNeighbors -
                    GroupService.kMinGroupSyncNeighbors,
                value: count.toDouble(),
                label: '$count',
                onChanged: (value) => setState(() => _value = value.round()),
                onChangeEnd: (value) async {
                  final saved = value.round();
                  await widget.service.setGroupSyncNeighborCount(
                    widget.spaceId,
                    saved,
                  );
                  unawaited(widget.service.nudgeGroupSync(widget.spaceId));
                },
              ),
              Text(l.spaceReplicationNeighbors(count)),
              const SizedBox(height: 4),
              Text(
                l.spaceReplicationHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
