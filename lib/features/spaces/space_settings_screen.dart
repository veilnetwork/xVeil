import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_retention.dart';
import '../../domain/space_join_request.dart';
import '../../domain/space_recommendation.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show conversationsProvider;
import '../chat/chat_actions.dart';

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
  GroupService? _snapshotService;
  NodeId? _snapshotSpaceId;
  int? _snapshotRevision;
  Future<List<Object?>>? _snapshotFuture;
  bool _snapshotLoaded = false;
  bool _snapshotCanRefresh = false;

  NodeId? get _spaceId {
    try {
      return NodeId.fromHex(widget.spaceIdHex);
    } catch (_) {
      return null;
    }
  }

  Future<List<Object?>> _loadSettingsSnapshot(
    GroupService service,
    NodeId spaceId,
  ) => Future.wait<Object?>([
    service.stateOf(spaceId),
    service.spaceSubscription(spaceId),
    service.load(spaceId),
    service.localSpaceRetentionDays(spaceId),
    service.currentSpaceJoinCode(spaceId),
    service.pendingSpaceJoinRequests(spaceId),
    service.spaceRecommendationCampaigns(spaceId),
    service.groupNotificationPolicy(spaceId),
  ]);

  Future<List<Object?>> _settingsSnapshot(
    GroupService service,
    NodeId spaceId,
    int? revision,
  ) {
    final identityChanged =
        !identical(_snapshotService, service) || _snapshotSpaceId != spaceId;
    if (identityChanged || _snapshotFuture == null) {
      _snapshotService = service;
      _snapshotSpaceId = spaceId;
      _snapshotRevision = revision;
      _snapshotCanRefresh = false;
      _startSettingsSnapshot(service, spaceId);
    } else if (_snapshotRevision != revision) {
      _snapshotRevision = revision;
      // Coalesce revisions received while the first read is in flight. Once
      // data is visible, FutureBuilder retains it while a refresh completes.
      if (_snapshotLoaded && _snapshotCanRefresh) {
        _startSettingsSnapshot(service, spaceId);
      }
    }
    return _snapshotFuture!;
  }

  void _startSettingsSnapshot(GroupService service, NodeId spaceId) {
    _snapshotLoaded = false;
    _snapshotCanRefresh = false;
    final future = _loadSettingsSnapshot(service, spaceId);
    _snapshotFuture = future;
    unawaited(
      future.then<void>(
        (_) => _settingsSnapshotFinished(future),
        onError: (Object _, StackTrace _) => _settingsSnapshotFinished(future),
      ),
    );
  }

  void _settingsSnapshotFinished(Future<List<Object?>> future) {
    if (!identical(_snapshotFuture, future)) return;
    _snapshotLoaded = true;
    // Let FutureBuilder paint the completed initial snapshot before accepting
    // another high-frequency replication revision.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_snapshotFuture, future)) {
        _snapshotCanRefresh = true;
      }
    });
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

  String _date(BuildContext context, int timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(date)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  Future<void> _setGlobalRetention(
    GroupService service,
    NodeId spaceId,
    int? days, {
    required bool mediaOnly,
  }) async {
    final policy = days == null
        ? const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever)
        : SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: Duration(days: days).inMilliseconds,
            mediaOnly: mediaOnly,
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

  Future<void> _copySpaceJoinLink(GroupService service, NodeId spaceId) async {
    final link = await service.createSpaceJoinCode(spaceId);
    if (link == null) {
      _failure();
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceJoinLinkCopied)),
      );
    });
  }

  Future<void> _revokeSpaceJoinLink(
    GroupService service,
    NodeId spaceId,
  ) async {
    if (!await service.revokeSpaceJoinCode(spaceId)) {
      _failure();
      return;
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceJoinLinkRevoked)),
      );
    });
  }

  Future<void> _createRecommendationCampaign(
    GroupService service,
    NodeId spaceId,
  ) async {
    final l = AppL10n.of(context);
    var draft = '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.spaceRecommendationCreate),
        content: TextField(
          key: const ValueKey('space-recommendation-text'),
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 1000,
          decoration: InputDecoration(hintText: l.spaceRecommendationTextHint),
          onChanged: (value) => draft = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-recommendation-create-confirm'),
            onPressed: () => Navigator.of(dialog).pop(draft),
            child: Text(l.spaceRecommendationCreate),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    if (await service.createSpaceRecommendationCampaign(spaceId, text) ==
        null) {
      _failure();
    }
  }

  Future<void> _revokeRecommendationCampaign(
    GroupService service,
    NodeId spaceId,
    String campaignId,
  ) async {
    if (!await service.revokeSpaceRecommendationCampaign(spaceId, campaignId)) {
      _failure();
    }
  }

  Future<void> _decideJoinRequest(
    GroupService service,
    SpaceJoinInboxEntry entry, {
    required bool accept,
  }) async {
    if (!await service.decideSpaceJoinRequest(
      entry.request.requestId,
      accept: accept,
    )) {
      _failure();
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

  Future<void> _setArchived(
    GroupService service,
    NodeId spaceId, {
    required bool archived,
  }) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(archived ? l.spaceArchiveTitle : l.spaceRestoreTitle),
        content: Text(archived ? l.spaceArchiveConfirm : l.spaceRestoreConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-lifecycle-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(archived ? l.spaceArchiveAction : l.spaceRestoreAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await service.setSpaceArchived(spaceId, archived)) _failure();
  }

  Future<void> _deleteSpace(GroupService service, NodeId spaceId) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.spaceDeleteTitle),
        content: Text(l.spaceDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l.spaceDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await service.deleteSpace(spaceId)) _failure();
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
    return Scaffold(
      appBar: AppBar(title: Text(l.spaceSettingsTitle)),
      body: StreamBuilder<int>(
        stream: service.changes.stream,
        builder: (context, changes) => FutureBuilder<List<Object?>>(
          future: _settingsSnapshot(service, spaceId, changes.data),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final state = snapshot.data![0] as GroupState?;
            if (state == null || !state.isMember(service.selfId)) {
              return Center(child: Text(l.spaceOperationFailed));
            }
            final subscription = snapshot.data![1] as SpaceSubscription;
            final bundle = snapshot.data![2] as GroupBundle?;
            final localRetentionDays = snapshot.data![3] as int?;
            final joinCode = snapshot.data![4] as String?;
            final joinRequests = snapshot.data![5] as List<SpaceJoinInboxEntry>;
            final recommendationCampaigns =
                snapshot.data![6] as List<SpaceRecommendationCampaign>;
            final notificationPolicy =
                snapshot.data![7] as NotificationMutePolicy;
            final myRole = state.roleOf(service.selfId)!;
            final canRename =
                state.isActive &&
                canApply(authorRole: myRole, op: ControlOp.setName);
            final canEditDescription =
                state.isActive &&
                canApply(authorRole: myRole, op: ControlOp.setDescription);
            final canAdd =
                state.isActive &&
                canApply(
                  authorRole: myRole,
                  op: ControlOp.addMember,
                  newRole: GroupRole.member,
                );
            final canManageRetention = SpaceAcl(
              state,
            ).allows(service.selfId, SpacePermission.manageStorage);
            final canManageRecommendations =
                bundle?.manifest.visibility == SpaceVisibility.public &&
                SpaceAcl(
                  state,
                ).allows(service.selfId, SpacePermission.manageRecommendations);
            final globalRetentionPolicy = state.effectiveRetentionPolicy();
            final globalRetentionDays = _retentionDays(globalRetentionPolicy);
            final members = state.members.values.toList()
              ..sort((a, b) {
                final rank = b.role.rank.compareTo(a.role.rank);
                return rank != 0 ? rank : a.nodeId.hex.compareTo(b.nodeId.hex);
              });
            return LayoutBuilder(
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
                            ExpansionTile(
                              key: const ValueKey(
                                'space-subscription-settings',
                              ),
                              leading: const Icon(Icons.tune),
                              title: Text(l.spaceSubscriptionSettings),
                              children: [
                                ListTile(
                                  key: const ValueKey(
                                    'space-notification-policy-setting',
                                  ),
                                  leading: const Icon(
                                    Icons.notifications_paused_outlined,
                                  ),
                                  title: Text(l.notificationsTitle),
                                  subtitle: Text(
                                    notificationMutePolicyLabel(
                                      context,
                                      notificationPolicy,
                                    ),
                                  ),
                                  trailing:
                                      notificationPolicy.effectiveAt(
                                            DateTime.now(),
                                          ) ==
                                          NotificationMuteMode.all
                                      ? const Icon(Icons.chevron_right)
                                      : IconButton(
                                          tooltip: l.chatMenuUnmute,
                                          icon: const Icon(
                                            Icons.notifications_active_outlined,
                                          ),
                                          onPressed: () => unawaited(
                                            service.setGroupNotificationPolicy(
                                              spaceId,
                                              NotificationMuteMode.all,
                                              null,
                                            ),
                                          ),
                                        ),
                                  onTap: () async {
                                    final picked =
                                        await pickNotificationMutePolicy(
                                          context,
                                        );
                                    if (picked == null) return;
                                    await service.setGroupNotificationPolicy(
                                      spaceId,
                                      picked.mode,
                                      picked.until,
                                    );
                                  },
                                ),
                                SwitchListTile(
                                  key: const ValueKey('space-feed-setting'),
                                  secondary: const Icon(
                                    Icons.campaign_outlined,
                                  ),
                                  title: Text(l.spaceFeedSetting),
                                  subtitle: Text(l.spaceFeedSettingHint),
                                  value: subscription.feedEnabled,
                                  onChanged: (enabled) => unawaited(
                                    service.setSpaceFeedEnabled(
                                      spaceId,
                                      enabled,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    12,
                                  ),
                                  child:
                                      DropdownButtonFormField<
                                        SpaceCommentNotificationMode
                                      >(
                                        key: const ValueKey(
                                          'space-comment-notifications-setting',
                                        ),
                                        initialValue:
                                            subscription.commentNotifications,
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          prefixIcon: const Icon(
                                            Icons.forum_outlined,
                                          ),
                                          labelText: l
                                              .spaceCommentNotificationsSetting,
                                          helperText: l
                                              .spaceCommentNotificationsSettingHint,
                                        ),
                                        items: [
                                          DropdownMenuItem(
                                            value: SpaceCommentNotificationMode
                                                .all,
                                            child: Text(
                                              l.spaceCommentNotificationsAll,
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value: SpaceCommentNotificationMode
                                                .replies,
                                            child: Text(
                                              l.spaceCommentNotificationsReplies,
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value: SpaceCommentNotificationMode
                                                .none,
                                            child: Text(
                                              l.spaceCommentNotificationsNone,
                                            ),
                                          ),
                                        ],
                                        onChanged: (mode) {
                                          if (mode != null) {
                                            unawaited(
                                              service
                                                  .setSpaceCommentNotifications(
                                                    spaceId,
                                                    mode,
                                                  ),
                                            );
                                          }
                                        },
                                      ),
                                ),
                                SwitchListTile(
                                  key: const ValueKey(
                                    'space-notifications-setting',
                                  ),
                                  secondary: const Icon(
                                    Icons.notifications_outlined,
                                  ),
                                  title: Text(l.spaceNotificationsSetting),
                                  subtitle: Text(
                                    l.spaceNotificationsSettingHint,
                                  ),
                                  value: subscription.notificationsEnabled,
                                  onChanged: (enabled) => unawaited(
                                    service.setSpaceNotificationsEnabled(
                                      spaceId,
                                      enabled,
                                    ),
                                  ),
                                ),
                                SwitchListTile(
                                  key: const ValueKey(
                                    'space-hide-recommendations-setting',
                                  ),
                                  secondary: const Icon(Icons.visibility_off),
                                  title: Text(
                                    l.spaceHideRecommendationsSetting,
                                  ),
                                  subtitle: Text(
                                    l.spaceHideRecommendationsSettingHint,
                                  ),
                                  value: subscription.hiddenFromRecommendations,
                                  onChanged: (hidden) => unawaited(
                                    service.setSpaceHiddenFromRecommendations(
                                      spaceId,
                                      hidden,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            _ReplicationSetting(
                              service: service,
                              spaceId: spaceId,
                            ),
                          ],
                        ),
                      ),
                      if (canAdd &&
                          bundle?.manifest.visibility ==
                              SpaceVisibility.public) ...[
                        const SizedBox(height: 12),
                        Card(
                          child: Column(
                            children: [
                              ListTile(
                                key: const ValueKey('space-join-link-tile'),
                                leading: const Icon(Icons.link),
                                title: Text(l.spaceJoinLinkTitle),
                                subtitle: Text(l.spaceJoinLinkHint),
                                trailing: joinCode == null
                                    ? FilledButton.tonal(
                                        key: const ValueKey(
                                          'space-join-link-create',
                                        ),
                                        onPressed: () => _copySpaceJoinLink(
                                          service,
                                          spaceId,
                                        ),
                                        child: Text(l.spaceJoinLinkCreate),
                                      )
                                    : Wrap(
                                        spacing: 4,
                                        children: [
                                          IconButton(
                                            key: const ValueKey(
                                              'space-join-link-copy',
                                            ),
                                            tooltip: l.spaceJoinLinkCopy,
                                            onPressed: () => _copySpaceJoinLink(
                                              service,
                                              spaceId,
                                            ),
                                            icon: const Icon(
                                              Icons.copy_outlined,
                                            ),
                                          ),
                                          IconButton(
                                            key: const ValueKey(
                                              'space-join-link-revoke',
                                            ),
                                            tooltip: l.spaceJoinLinkRevoke,
                                            onPressed: () =>
                                                _revokeSpaceJoinLink(
                                                  service,
                                                  spaceId,
                                                ),
                                            icon: const Icon(
                                              Icons.link_off_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (canAdd && joinRequests.isNotEmpty) ...[
                        Text(
                          l.spaceJoinRequestsTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (
                                var index = 0;
                                index < joinRequests.length;
                                index++
                              ) ...[
                                if (index > 0)
                                  const Divider(height: 1, indent: 56),
                                Builder(
                                  builder: (context) {
                                    final entry = joinRequests[index];
                                    final label = _memberLabel(
                                      l,
                                      service,
                                      entry.request.requester,
                                      conversations,
                                    );
                                    return ListTile(
                                      key: ValueKey(
                                        'space-join-request-${entry.request.requestId}',
                                      ),
                                      leading: const Icon(
                                        Icons.person_add_alt_1_outlined,
                                      ),
                                      title: Text(
                                        l.spaceJoinRequestFrom(label),
                                      ),
                                      subtitle: Text(
                                        entry.request.requester.short,
                                      ),
                                      trailing: Wrap(
                                        spacing: 4,
                                        children: [
                                          TextButton(
                                            onPressed: () => _decideJoinRequest(
                                              service,
                                              entry,
                                              accept: false,
                                            ),
                                            child: Text(l.spaceJoinDecline),
                                          ),
                                          FilledButton.tonal(
                                            onPressed: () => _decideJoinRequest(
                                              service,
                                              entry,
                                              accept: true,
                                            ),
                                            child: Text(l.spaceJoinApprove),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      if (canManageRecommendations) ...[
                        Card(
                          child: Column(
                            children: [
                              ListTile(
                                key: const ValueKey(
                                  'space-recommendations-tile',
                                ),
                                leading: const Icon(Icons.share_outlined),
                                title: Text(l.spaceRecommendationsTitle),
                                subtitle: Text(l.spaceRecommendationsHint),
                                trailing: FilledButton.tonal(
                                  key: const ValueKey(
                                    'space-recommendation-create',
                                  ),
                                  onPressed: () =>
                                      _createRecommendationCampaign(
                                        service,
                                        spaceId,
                                      ),
                                  child: Text(l.spaceRecommendationCreate),
                                ),
                              ),
                              if (recommendationCampaigns.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      l.spaceRecommendationEmpty,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                ),
                              for (final campaign
                                  in recommendationCampaigns) ...[
                                const Divider(height: 1, indent: 56),
                                ListTile(
                                  key: ValueKey(
                                    'space-recommendation-${campaign.campaignId}',
                                  ),
                                  leading: const Icon(Icons.campaign_outlined),
                                  title: Text(
                                    campaign.text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    _date(context, campaign.createdAtMs),
                                  ),
                                  trailing: IconButton(
                                    tooltip: l.spaceRecommendationRevoke,
                                    onPressed: () =>
                                        _revokeRecommendationCampaign(
                                          service,
                                          spaceId,
                                          campaign.campaignId,
                                        ),
                                    icon: const Icon(Icons.campaign_outlined),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
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
                                      !state.isActive ||
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
                      else if (state.isActive)
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
                                _setGlobalRetention(
                                  service,
                                  spaceId,
                                  days,
                                  mediaOnly:
                                      days != null &&
                                      globalRetentionPolicy.mediaOnly,
                                ),
                              ),
                              mediaOnly: globalRetentionPolicy.mediaOnly,
                              onMediaOnlyChanged: (mediaOnly) => unawaited(
                                _setGlobalRetention(
                                  service,
                                  spaceId,
                                  globalRetentionDays,
                                  mediaOnly: mediaOnly,
                                ),
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
                      const SizedBox(height: 12),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              key: const ValueKey('space-lifecycle-tile'),
                              leading: Icon(
                                state.isDeleted
                                    ? Icons.delete_forever_outlined
                                    : state.isArchived
                                    ? Icons.unarchive_outlined
                                    : Icons.archive_outlined,
                              ),
                              title: Text(
                                state.isDeleted
                                    ? l.spaceDeletedTitle
                                    : state.isArchived
                                    ? l.spaceArchivedTitle
                                    : l.spaceActiveTitle,
                              ),
                              subtitle: Text(
                                state.isDeleted
                                    ? [
                                        l.spaceDeletedHint,
                                        if (state
                                                .lifecycleTransition
                                                ?.recoveryDeadlineMs !=
                                            null)
                                          l.spaceRecoveryUntil(
                                            _date(
                                              context,
                                              state
                                                  .lifecycleTransition!
                                                  .recoveryDeadlineMs!,
                                            ),
                                          ),
                                      ].join('\n')
                                    : state.isArchived
                                    ? l.spaceArchivedHint
                                    : l.spaceActiveHint,
                              ),
                              trailing: myRole == GroupRole.owner
                                  ? FilledButton.tonal(
                                      key: const ValueKey(
                                        'space-lifecycle-action',
                                      ),
                                      onPressed: () => _setArchived(
                                        service,
                                        spaceId,
                                        archived: state.isActive,
                                      ),
                                      child: Text(
                                        state.isActive
                                            ? l.spaceArchiveAction
                                            : l.spaceRestoreAction,
                                      ),
                                    )
                                  : null,
                            ),
                            if (myRole == GroupRole.owner && !state.isDeleted)
                              ListTile(
                                key: const ValueKey('space-delete-action'),
                                leading: Icon(
                                  Icons.delete_outline,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                title: Text(
                                  l.spaceDeleteAction,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                subtitle: Text(l.spaceDeleteHint),
                                onTap: () => _deleteSpace(service, spaceId),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
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
    this.mediaOnly = false,
    this.onMediaOnlyChanged,
  });

  final String title;
  final String subtitle;
  final int? value;
  final bool enabled;
  final ValueChanged<int?> onChanged;
  final bool mediaOnly;
  final ValueChanged<bool>? onMediaOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      children: [
        ListTile(
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
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
        ),
        if (value != null && onMediaOnlyChanged != null)
          SwitchListTile(
            key: const ValueKey('space-global-retention-media-only'),
            value: mediaOnly,
            onChanged: enabled ? onMediaOnlyChanged : null,
            title: Text(l.spaceRetentionMediaOnly),
            subtitle: Text(l.spaceRetentionMediaOnlyHint),
            secondary: const Icon(Icons.perm_media_outlined),
          ),
      ],
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
