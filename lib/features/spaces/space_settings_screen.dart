import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_channel.dart';
import '../../domain/space_retention.dart';
import '../../domain/space_join_request.dart';
import '../../domain/space_moderation.dart';
import '../../domain/space_policy_audit.dart';
import '../../domain/space_recommendation.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show conversationsProvider;
import '../chat/chat_actions.dart';

enum _SpaceMemberAction { unmute, promote, demote, remove, ban, transferOwner }

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
    service.channelsOf(spaceId, includeArchived: true),
    service.spacePolicyAudit(spaceId),
    service.spaceRecommendationShareAudit(spaceId: spaceId),
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

  String _permissionLabel(AppL10n l, SpacePermission permission) =>
      switch (permission) {
        SpacePermission.view => l.spacePermissionView,
        SpacePermission.distributeContent => l.spacePermissionDistributeContent,
        SpacePermission.publishMessages => l.spacePermissionPublishMessages,
        SpacePermission.publishPosts => l.spacePermissionPublishPosts,
        SpacePermission.managePosts => l.spacePermissionManagePosts,
        SpacePermission.manageRecommendations =>
          l.spacePermissionManageRecommendations,
        SpacePermission.enterVoice => l.spacePermissionEnterVoice,
        SpacePermission.manageMembers => l.spacePermissionManageMembers,
        SpacePermission.manageRoles => l.spacePermissionManageRoles,
        SpacePermission.moderate => l.spacePermissionModerate,
        SpacePermission.manageSettings => l.spacePermissionManageSettings,
        SpacePermission.manageEncryption => l.spacePermissionManageEncryption,
        SpacePermission.manageStorage => l.spacePermissionManageStorage,
        SpacePermission.manageChannels => l.spacePermissionManageChannels,
      };

  String _scopeKindLabel(AppL10n l, SpacePermissionScopeKind kind) =>
      switch (kind) {
        SpacePermissionScopeKind.space => l.spaceAccessScopeSpace,
        SpacePermissionScopeKind.category => l.spaceAccessScopeCategory,
        SpacePermissionScopeKind.channel => l.spaceAccessScopeChannel,
        SpacePermissionScopeKind.posts => l.spaceAccessScopePosts,
        SpacePermissionScopeKind.moderation => l.spaceAccessScopeModeration,
        SpacePermissionScopeKind.members => l.spaceAccessScopeMembers,
        SpacePermissionScopeKind.roles => l.spaceAccessScopeRoles,
        SpacePermissionScopeKind.settings => l.spaceAccessScopeSettings,
        SpacePermissionScopeKind.encryption => l.spaceAccessScopeEncryption,
        SpacePermissionScopeKind.storage => l.spaceAccessScopeStorage,
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

  String _policyAuditSummary(
    AppL10n l,
    SpacePolicyAuditEntry entry,
    List<SpaceChannel> channels,
  ) => switch (entry) {
    SpaceAccessPolicyAuditEntry(:final policy) =>
      l.spacePolicyAuditAccessSummary(
        policy.revision,
        policy.roles.length,
        policy.groups.length,
        policy.directAssignments.length,
      ),
    SpaceRetentionPolicyAuditEntry(:final revision) =>
      '${revision.policy.channelId == null ? l.spacePolicyAuditScopeSpace : l.spacePolicyAuditScopeChannel(_channelAuditLabel(revision.policy.channelId!, channels))} · '
          '${_retentionAuditRule(l, revision.policy)}'
          '${revision.policy.mediaOnly ? ' · ${l.spacePolicyAuditMediaOnly}' : ''}',
    SpaceRecommendationPolicyAuditEntry(:final policy) =>
      policy.enabled
          ? l.spaceRecommendationPolicyEnabled
          : l.spaceRecommendationPolicyDisabled,
  };

  String _channelAuditLabel(NodeId channelId, List<SpaceChannel> channels) {
    for (final channel in channels) {
      if (channel.channelId == channelId) return channel.name;
    }
    return channelId.short;
  }

  String _retentionAuditRule(AppL10n l, SpaceRetentionPolicy policy) =>
      switch (policy.mode) {
        SpaceRetentionMode.inherit => l.spacePolicyAuditRetentionInherit,
        SpaceRetentionMode.keepForever => l.spacePolicyAuditRetentionForever,
        SpaceRetentionMode.deleteAfter => l.spacePolicyAuditRetentionDays(
          policy.retentionMs! ~/ const Duration(days: 1).inMilliseconds,
        ),
      };

  Future<void> _showPolicyAudit(
    List<SpacePolicyAuditEntry> audit,
    List<SpaceChannel> channels,
    GroupService service,
    List<Conversation> conversations,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final l = AppL10n.of(sheetContext);
      return FractionallySizedBox(
        heightFactor: .85,
        child: Column(
          children: [
            ListTile(
              leading: IconButton(
                key: const ValueKey('space-policy-audit-back'),
                tooltip: MaterialLocalizations.of(
                  sheetContext,
                ).backButtonTooltip,
                onPressed: () => Navigator.of(sheetContext).pop(),
                icon: const Icon(Icons.arrow_back),
              ),
              title: Text(l.spacePolicyAuditTitle),
              subtitle: Text(l.spacePolicyAuditHint),
            ),
            const Divider(height: 1),
            Expanded(
              child: audit.isEmpty
                  ? Center(child: Text(l.spacePolicyAuditEmpty))
                  : ListView.separated(
                      key: const ValueKey('space-policy-audit-list'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: audit.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final entry = audit[index];
                        final author = _memberLabel(
                          l,
                          service,
                          entry.author,
                          conversations,
                        );
                        return ListTile(
                          key: ValueKey(
                            'space-policy-audit-entry-${entry.stableId}',
                          ),
                          leading: Icon(
                            entry is SpaceAccessPolicyAuditEntry
                                ? Icons.admin_panel_settings_outlined
                                : entry is SpaceRecommendationPolicyAuditEntry
                                ? Icons.share_outlined
                                : Icons.inventory_2_outlined,
                          ),
                          title: Text(
                            entry is SpaceAccessPolicyAuditEntry
                                ? l.spacePolicyAuditAccess
                                : entry is SpaceRecommendationPolicyAuditEntry
                                ? l.spacePolicyAuditRecommendations
                                : l.spacePolicyAuditRetention,
                          ),
                          subtitle: Text(
                            '${_policyAuditSummary(l, entry, channels)}\n'
                            '${_date(sheetContext, entry.changedAtMs)} · '
                            '${l.spacePolicyAuditSignedBy(author)}',
                          ),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );

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

  Future<bool> _replaceAccessPolicy(
    GroupService service,
    NodeId spaceId,
    GroupState state, {
    required Iterable<SpaceRoleDefinition> roles,
    required Iterable<SpaceMemberGroup> groups,
    required Iterable<SpaceMemberRoleAssignment> directAssignments,
  }) async {
    final saved = await service.replaceSpaceAccessPolicy(
      spaceId,
      expectedRevision: state.accessPolicy?.revision ?? 0,
      roles: roles,
      groups: groups,
      directAssignments: directAssignments,
    );
    if (saved != null) return true;
    _failure();
    return false;
  }

  Future<void> _editAccessRole(
    GroupService service,
    NodeId spaceId,
    GroupState state, [
    List<SpaceChannel> channels = const <SpaceChannel>[],
    SpaceRoleDefinition? existing,
  ]) async {
    final draft = await showDialog<_SpaceRoleDraft>(
      context: context,
      builder: (_) => _SpaceRoleDialog(
        existing: existing,
        channels: channels,
        canUseRule: (permission, scope) =>
            SpaceAcl(state).canDelegateRule(service.selfId, permission, scope),
        permissionLabel: (permission) =>
            _permissionLabel(AppL10n.of(context), permission),
        scopeLabel: (scope) => _scopeKindLabel(AppL10n.of(context), scope),
      ),
    );
    if (draft == null) return;
    final roleId = existing?.roleId ?? service.newSpaceAccessObjectId();
    final roles = [...?state.accessPolicy?.roles]
      ..removeWhere((role) => role.roleId == roleId)
      ..add(
        SpaceRoleDefinition(
          roleId: roleId,
          name: draft.name,
          grants: draft.grants,
          denials: draft.denials,
        ),
      );
    await _replaceAccessPolicy(
      service,
      spaceId,
      state,
      roles: roles,
      groups: state.accessPolicy?.groups ?? const <SpaceMemberGroup>[],
      directAssignments:
          state.accessPolicy?.directAssignments ??
          const <SpaceMemberRoleAssignment>[],
    );
  }

  Future<void> _deleteAccessRole(
    GroupService service,
    NodeId spaceId,
    GroupState state,
    SpaceRoleDefinition role,
  ) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.spaceAccessRoleDelete),
        content: Text(l.spaceAccessRoleDeleteConfirm(role.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.spaceAccessRoleDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final remainingRoles = [
      for (final candidate
          in state.accessPolicy?.roles ?? const <SpaceRoleDefinition>[])
        if (candidate.roleId != role.roleId) candidate,
    ];
    final groups = [
      for (final group
          in state.accessPolicy?.groups ?? const <SpaceMemberGroup>[])
        if (group.roleIds.any((roleId) => roleId != role.roleId))
          SpaceMemberGroup(
            groupId: group.groupId,
            name: group.name,
            members: group.members,
            roleIds: group.roleIds.where((roleId) => roleId != role.roleId),
          ),
    ];
    final direct = [
      for (final assignment
          in state.accessPolicy?.directAssignments ??
              const <SpaceMemberRoleAssignment>[])
        if (assignment.roleIds.any((roleId) => roleId != role.roleId))
          SpaceMemberRoleAssignment(
            member: assignment.member,
            roleIds: assignment.roleIds.where(
              (roleId) => roleId != role.roleId,
            ),
          ),
    ];
    await _replaceAccessPolicy(
      service,
      spaceId,
      state,
      roles: remainingRoles,
      groups: groups,
      directAssignments: direct,
    );
  }

  Future<void> _editAccessGroup(
    GroupService service,
    NodeId spaceId,
    GroupState state,
    List<Conversation> conversations, [
    SpaceMemberGroup? existing,
  ]) async {
    final acl = SpaceAcl(state);
    final roles = (state.accessPolicy?.roles ?? const <SpaceRoleDefinition>[])
        .where((role) => acl.canDelegateRole(service.selfId, role))
        .toList(growable: false);
    if (roles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceAccessNoRoles)),
      );
      return;
    }
    final members = [
      for (final member in state.members.values)
        if (acl.canManagePolicyTarget(service.selfId, member.nodeId))
          _SpaceAccessMemberOption(
            id: member.nodeId,
            label: _memberLabel(
              AppL10n.of(context),
              service,
              member.nodeId,
              conversations,
            ),
          ),
    ];
    final draft = await showDialog<_SpaceGroupDraft>(
      context: context,
      builder: (_) =>
          _SpaceGroupDialog(existing: existing, members: members, roles: roles),
    );
    if (draft == null) return;
    final groupId = existing?.groupId ?? service.newSpaceAccessObjectId();
    final groups = [...?state.accessPolicy?.groups]
      ..removeWhere((group) => group.groupId == groupId)
      ..add(
        SpaceMemberGroup(
          groupId: groupId,
          name: draft.name,
          members: draft.members,
          roleIds: draft.roleIds,
        ),
      );
    await _replaceAccessPolicy(
      service,
      spaceId,
      state,
      roles: roles,
      groups: groups,
      directAssignments:
          state.accessPolicy?.directAssignments ??
          const <SpaceMemberRoleAssignment>[],
    );
  }

  Future<void> _deleteAccessGroup(
    GroupService service,
    NodeId spaceId,
    GroupState state,
    SpaceMemberGroup group,
  ) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.spaceAccessGroupDelete),
        content: Text(l.spaceAccessGroupDeleteConfirm(group.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.spaceAccessGroupDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _replaceAccessPolicy(
      service,
      spaceId,
      state,
      roles: state.accessPolicy?.roles ?? const <SpaceRoleDefinition>[],
      groups: [
        for (final candidate
            in state.accessPolicy?.groups ?? const <SpaceMemberGroup>[])
          if (candidate.groupId != group.groupId) candidate,
      ],
      directAssignments:
          state.accessPolicy?.directAssignments ??
          const <SpaceMemberRoleAssignment>[],
    );
  }

  Future<void> _assignDirectRoles(
    GroupService service,
    NodeId spaceId,
    GroupState state,
    GroupMember member,
    String label,
  ) async {
    final acl = SpaceAcl(state);
    final roles = (state.accessPolicy?.roles ?? const <SpaceRoleDefinition>[])
        .where((role) => acl.canDelegateRole(service.selfId, role))
        .toList(growable: false);
    if (roles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceAccessNoRoles)),
      );
      return;
    }
    final current = state.accessPolicy?.directAssignments
        .where((assignment) => assignment.member == member.nodeId)
        .firstOrNull;
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _SpaceDirectRolesDialog(
        memberLabel: label,
        roles: roles,
        selectedRoleIds: current?.roleIds.toSet() ?? const {},
      ),
    );
    if (selected == null) return;
    final direct = [...?state.accessPolicy?.directAssignments]
      ..removeWhere((assignment) => assignment.member == member.nodeId);
    if (selected.isNotEmpty) {
      direct.add(
        SpaceMemberRoleAssignment(member: member.nodeId, roleIds: selected),
      );
    }
    await _replaceAccessPolicy(
      service,
      spaceId,
      state,
      roles: roles,
      groups: state.accessPolicy?.groups ?? const <SpaceMemberGroup>[],
      directAssignments: direct,
    );
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

  Future<void> _setRecommendationPolicy(
    GroupService service,
    NodeId spaceId,
    SpaceRecommendationPolicy? current,
    bool enabled,
  ) async {
    final applied = await service.setSpaceRecommendationPolicy(
      spaceId,
      expectedRevision: current?.revision ?? 0,
      enabled: enabled,
    );
    if (applied == null) _failure();
  }

  Future<void> _revokeSentRecommendation(
    GroupService service,
    SpaceRecommendationShareAudit record,
  ) async {
    final result = await service.revokeSentSpaceRecommendation(record.stableId);
    if (result != SpaceRecommendationRevokeResult.revoked) _failure();
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
    String? banReason;
    if (action == _SpaceMemberAction.ban) {
      final l = AppL10n.of(context);
      var draftReason = '';
      banReason = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l.spaceMemberBan),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.spaceMemberBanConfirm(label)),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('space-member-ban-reason'),
                    autofocus: true,
                    maxLength: kSpaceModerationReasonMax,
                    onChanged: (value) {
                      draftReason = value;
                      setDialogState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: l.spaceModerationReason,
                      counterText: '',
                    ),
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
                key: const ValueKey('space-member-ban-confirm'),
                onPressed: draftReason.trim().isEmpty
                    ? null
                    : () => Navigator.of(dialogContext).pop(draftReason.trim()),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: Text(l.spaceMemberBan),
              ),
            ],
          ),
        ),
      );
      if (banReason == null) return;
    } else if (action == _SpaceMemberAction.remove) {
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
    if (action == _SpaceMemberAction.ban) {
      final actionId = await service.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.permanentBan,
        target: member.nodeId,
        scope: SpaceModerationScope.space,
        reason: banReason!,
      );
      if (actionId == null) _failure();
      return;
    }
    final (operation, role) = switch (action) {
      _SpaceMemberAction.unmute => (ControlOp.unmute, null),
      _SpaceMemberAction.promote => (ControlOp.setRole, GroupRole.admin),
      _SpaceMemberAction.demote => (ControlOp.setRole, GroupRole.member),
      _SpaceMemberAction.remove => (ControlOp.removeMember, null),
      _SpaceMemberAction.ban => throw StateError('handled above'),
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
    GroupState state,
    NodeId selfId,
    GroupRole myRole,
    GroupMember member,
  ) {
    final actions = <PopupMenuEntry<_SpaceMemberAction>>[];
    bool allowed(ControlOp op, {GroupRole? newRole}) =>
        canApply(
          authorRole: myRole,
          op: op,
          targetRole: member.role,
          newRole: newRole,
        ) ||
        SpaceAcl.customPolicyAllowsControl(
          policy: state.accessPolicy,
          author: selfId,
          op: op,
          targetRole: member.role,
          newRole: newRole,
          target: member.nodeId,
        );
    if (member.muted && allowed(ControlOp.unmute)) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.unmute,
          child: Text(l.spaceMemberUnmute),
        ),
      );
    }
    if (member.role == GroupRole.member &&
        allowed(ControlOp.setRole, newRole: GroupRole.admin)) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.promote,
          child: Text(l.spaceMemberPromote),
        ),
      );
    }
    if (member.role == GroupRole.admin &&
        allowed(ControlOp.setRole, newRole: GroupRole.member)) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.demote,
          child: Text(l.spaceMemberDemote),
        ),
      );
    }
    if (allowed(ControlOp.removeMember)) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.remove,
          child: Text(l.spaceMemberRemove),
        ),
      );
    }
    if (SpaceAcl(
      state,
    ).allowsControl(selfId, ControlOp.moderate, target: member.nodeId)) {
      actions.add(
        PopupMenuItem(
          value: _SpaceMemberAction.ban,
          child: Text(
            l.spaceMemberBan,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (allowed(ControlOp.transferOwnership)) {
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
            final channels = snapshot.data![8] as List<SpaceChannel>;
            final policyAudit =
                snapshot.data![9] as List<SpacePolicyAuditEntry>;
            final recommendationShares =
                snapshot.data![10] as List<SpaceRecommendationShareAudit>;
            final myRole = state.roleOf(service.selfId)!;
            final acl = SpaceAcl(state);
            final canRename =
                state.isActive &&
                acl.allows(service.selfId, SpacePermission.manageSettings);
            final canEditDescription =
                state.isActive &&
                acl.allows(service.selfId, SpacePermission.manageSettings);
            final canAdd =
                state.isActive &&
                (canApply(
                      authorRole: myRole,
                      op: ControlOp.addMember,
                      newRole: GroupRole.member,
                    ) ||
                    SpaceAcl.customPolicyAllowsControl(
                      policy: state.accessPolicy,
                      author: service.selfId,
                      op: ControlOp.addMember,
                      newRole: GroupRole.member,
                    ));
            final canManageRetention = acl.allows(
              service.selfId,
              SpacePermission.manageStorage,
            );
            final canManageRecommendations =
                bundle?.manifest.visibility == SpaceVisibility.public &&
                state.isActive &&
                acl.allows(
                  service.selfId,
                  SpacePermission.manageRecommendations,
                );
            final showRecommendations =
                bundle?.manifest.visibility == SpaceVisibility.public;
            final canManageAccess =
                state.isActive &&
                acl.allowsControl(service.selfId, ControlOp.setPolicy);
            final delegatedAccess =
                canManageAccess && myRole != GroupRole.owner;
            final accessRoles =
                state.accessPolicy?.roles ?? const <SpaceRoleDefinition>[];
            final accessGroups =
                state.accessPolicy?.groups ?? const <SpaceMemberGroup>[];
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
                      if (showRecommendations) ...[
                        Card(
                          child: Column(
                            children: [
                              SwitchListTile(
                                key: const ValueKey(
                                  'space-recommendation-policy-enabled',
                                ),
                                secondary: const Icon(Icons.share_outlined),
                                title: Text(l.spaceRecommendationPolicyEnabled),
                                subtitle: Text(l.spaceRecommendationPolicyHint),
                                value: state.recommendationsEnabled,
                                onChanged: canManageRecommendations
                                    ? (enabled) => _setRecommendationPolicy(
                                        service,
                                        spaceId,
                                        state.recommendationPolicy,
                                        enabled,
                                      )
                                    : null,
                              ),
                              const Divider(height: 1, indent: 56),
                              ListTile(
                                key: const ValueKey(
                                  'space-recommendations-tile',
                                ),
                                leading: const Icon(Icons.campaign_outlined),
                                title: Text(l.spaceRecommendationsTitle),
                                subtitle: Text(l.spaceRecommendationsHint),
                                trailing: canManageRecommendations
                                    ? FilledButton.tonal(
                                        key: const ValueKey(
                                          'space-recommendation-create',
                                        ),
                                        onPressed: state.recommendationsEnabled
                                            ? () =>
                                                  _createRecommendationCampaign(
                                                    service,
                                                    spaceId,
                                                  )
                                            : null,
                                        child: Text(
                                          l.spaceRecommendationCreate,
                                        ),
                                      )
                                    : null,
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
                                  trailing: canManageRecommendations
                                      ? IconButton(
                                          tooltip: l.spaceRecommendationRevoke,
                                          onPressed: () =>
                                              _revokeRecommendationCampaign(
                                                service,
                                                spaceId,
                                                campaign.campaignId,
                                              ),
                                          icon: const Icon(
                                            Icons.campaign_outlined,
                                          ),
                                        )
                                      : null,
                                ),
                              ],
                              const Divider(height: 1),
                              ListTile(
                                leading: const Icon(Icons.outbox_outlined),
                                title: Text(
                                  l.spaceRecommendationSentAuditTitle,
                                ),
                                subtitle: Text(
                                  l.spaceRecommendationSentAuditHint,
                                ),
                              ),
                              if (recommendationShares.isEmpty)
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
                                      l.spaceRecommendationSentAuditEmpty,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                ),
                              for (final record in recommendationShares) ...[
                                const Divider(height: 1, indent: 56),
                                ListTile(
                                  key: ValueKey(
                                    'space-recommendation-share-${record.stableId}',
                                  ),
                                  leading: Icon(
                                    record.revokedAtMs == null
                                        ? Icons.send_outlined
                                        : Icons.undo_outlined,
                                  ),
                                  title: Text(
                                    l.spaceRecommendationSentTo(
                                      _memberLabel(
                                        l,
                                        service,
                                        record.recipient,
                                        conversations,
                                      ),
                                    ),
                                  ),
                                  subtitle: Text(
                                    record.revokedAtMs == null
                                        ? _date(context, record.sentAtMs)
                                        : '${_date(context, record.sentAtMs)} · '
                                              '${l.spaceRecommendationSentRevoked}',
                                  ),
                                  trailing: record.canRevoke
                                      ? IconButton(
                                          key: ValueKey(
                                            'space-recommendation-share-revoke-${record.stableId}',
                                          ),
                                          tooltip:
                                              l.spaceRecommendationSentRevoke,
                                          onPressed: () =>
                                              _revokeSentRecommendation(
                                                service,
                                                record,
                                              ),
                                          icon: const Icon(Icons.undo_outlined),
                                        )
                                      : null,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      Card(
                        key: const ValueKey('space-access-card'),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          key: const ValueKey('space-access-expansion'),
                          leading: const Icon(Icons.policy_outlined),
                          title: Text(l.spaceAccessTitle),
                          subtitle: Text(l.spaceAccessHint),
                          children: [
                            if (accessRoles.isEmpty && accessGroups.isEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  12,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l.spaceAccessEmpty,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            if (delegatedAccess)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  12,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l.spaceAccessDelegatedHint,
                                    key: const ValueKey(
                                      'space-access-delegated-hint',
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            if (accessRoles.isNotEmpty) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l.spaceAccessRoles,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                              ),
                              for (final role in accessRoles)
                                ListTile(
                                  key: ValueKey(
                                    'space-access-role-${role.roleId}',
                                  ),
                                  leading: const Icon(Icons.badge_outlined),
                                  title: Text(role.name),
                                  subtitle: Text(
                                    l.spaceAccessRoleGrantSummary(
                                      {
                                        ...role.permissions,
                                        ...role.deniedPermissions,
                                      }.length,
                                      role.grants.length + role.denials.length,
                                    ),
                                  ),
                                  trailing:
                                      canManageAccess &&
                                          acl.canManageAccessRole(
                                            service.selfId,
                                            role,
                                          )
                                      ? Wrap(
                                          spacing: 0,
                                          children: [
                                            IconButton(
                                              tooltip: l.spaceAccessRoleEdit,
                                              onPressed: () => _editAccessRole(
                                                service,
                                                spaceId,
                                                state,
                                                channels,
                                                role,
                                              ),
                                              icon: const Icon(
                                                Icons.edit_outlined,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: l.spaceAccessRoleDelete,
                                              onPressed: () =>
                                                  _deleteAccessRole(
                                                    service,
                                                    spaceId,
                                                    state,
                                                    role,
                                                  ),
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                            ),
                                          ],
                                        )
                                      : null,
                                ),
                            ],
                            if (accessGroups.isNotEmpty) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l.spaceAccessGroups,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                              ),
                              for (final group in accessGroups)
                                ListTile(
                                  key: ValueKey(
                                    'space-access-group-${group.groupId}',
                                  ),
                                  leading: const Icon(
                                    Icons.group_work_outlined,
                                  ),
                                  title: Text(group.name),
                                  subtitle: Text(
                                    l.spaceAccessGroupSummary(
                                      group.members.length,
                                      group.roleIds.length,
                                    ),
                                  ),
                                  trailing:
                                      canManageAccess &&
                                          acl.canManageAccessGroup(
                                            service.selfId,
                                            group,
                                          )
                                      ? Wrap(
                                          spacing: 0,
                                          children: [
                                            IconButton(
                                              tooltip: l.spaceAccessGroupEdit,
                                              onPressed: () => _editAccessGroup(
                                                service,
                                                spaceId,
                                                state,
                                                conversations,
                                                group,
                                              ),
                                              icon: const Icon(
                                                Icons.edit_outlined,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: l.spaceAccessGroupDelete,
                                              onPressed: () =>
                                                  _deleteAccessGroup(
                                                    service,
                                                    spaceId,
                                                    state,
                                                    group,
                                                  ),
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                            ),
                                          ],
                                        )
                                      : null,
                                ),
                            ],
                            if (canManageAccess) ...[
                              const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Wrap(
                                  alignment: WrapAlignment.end,
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      key: const ValueKey(
                                        'space-access-add-role',
                                      ),
                                      onPressed: () => _editAccessRole(
                                        service,
                                        spaceId,
                                        state,
                                        channels,
                                      ),
                                      icon: const Icon(
                                        Icons.add_moderator_outlined,
                                      ),
                                      label: Text(l.spaceAccessRoleAdd),
                                    ),
                                    OutlinedButton.icon(
                                      key: const ValueKey(
                                        'space-access-add-group',
                                      ),
                                      onPressed: () => _editAccessGroup(
                                        service,
                                        spaceId,
                                        state,
                                        conversations,
                                      ),
                                      icon: const Icon(
                                        Icons.group_add_outlined,
                                      ),
                                      label: Text(l.spaceAccessGroupAdd),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
                                      !state.isActive ||
                                          member.nodeId == service.selfId
                                      ? <PopupMenuEntry<_SpaceMemberAction>>[]
                                      : _actionsFor(
                                          l,
                                          state,
                                          service.selfId,
                                          myRole,
                                          member,
                                        );
                                  final customRoleNames = [
                                    for (final role in accessRoles)
                                      if (state
                                          .customRoleIdsOf(member.nodeId)
                                          .contains(role.roleId))
                                        role.name,
                                  ]..sort();
                                  final canAssignCustomRoles =
                                      canManageAccess &&
                                      accessRoles.any(
                                        (role) => acl.canDelegateRole(
                                          service.selfId,
                                          role,
                                        ),
                                      ) &&
                                      acl.canManageDirectRolesOf(
                                        service.selfId,
                                        member.nodeId,
                                      );
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
                                            ...customRoleNames,
                                            if (member.muted)
                                              l.spaceMemberMuted,
                                          ].join(' · '),
                                        ),
                                        trailing:
                                            !canAssignCustomRoles &&
                                                actions.isEmpty &&
                                                !member.muted
                                            ? null
                                            : Wrap(
                                                spacing: 0,
                                                children: [
                                                  if (canAssignCustomRoles)
                                                    IconButton(
                                                      key: ValueKey(
                                                        'space-access-assign-${member.nodeId.hex}',
                                                      ),
                                                      tooltip: l
                                                          .spaceAccessDirectRoles,
                                                      onPressed: () =>
                                                          _assignDirectRoles(
                                                            service,
                                                            spaceId,
                                                            state,
                                                            member,
                                                            label,
                                                          ),
                                                      icon: const Icon(
                                                        Icons.badge_outlined,
                                                      ),
                                                    ),
                                                  if (actions.isNotEmpty)
                                                    PopupMenuButton<
                                                      _SpaceMemberAction
                                                    >(
                                                      itemBuilder: (_) =>
                                                          actions,
                                                      onSelected: (action) =>
                                                          _memberAction(
                                                            service,
                                                            spaceId,
                                                            member,
                                                            label,
                                                            action,
                                                          ),
                                                    )
                                                  else if (member.muted)
                                                    const Padding(
                                                      padding: EdgeInsets.all(
                                                        12,
                                                      ),
                                                      child: Icon(
                                                        Icons
                                                            .volume_off_outlined,
                                                      ),
                                                    ),
                                                ],
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
                          key: const ValueKey('space-owner-leave-hint'),
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
                      const SizedBox(height: 12),
                      Card(
                        child: ListTile(
                          key: const ValueKey('space-policy-audit-tile'),
                          leading: const Icon(Icons.fact_check_outlined),
                          title: Text(
                            '${l.spacePolicyAuditTitle} (${policyAudit.length})',
                          ),
                          subtitle: Text(l.spacePolicyAuditHint),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showPolicyAudit(
                            policyAudit,
                            channels,
                            service,
                            conversations,
                          ),
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

final class _SpaceRoleDraft {
  const _SpaceRoleDraft({
    required this.name,
    required this.grants,
    required this.denials,
  });

  final String name;
  final List<SpacePermissionGrant> grants;
  final List<SpacePermissionDenial> denials;
}

class _SpaceRoleDialog extends StatefulWidget {
  const _SpaceRoleDialog({
    required this.existing,
    required this.channels,
    required this.canUseRule,
    required this.permissionLabel,
    required this.scopeLabel,
  });

  final SpaceRoleDefinition? existing;
  final List<SpaceChannel> channels;
  final bool Function(SpacePermission permission, SpacePermissionScope scope)
  canUseRule;
  final String Function(SpacePermission permission) permissionLabel;
  final String Function(SpacePermissionScopeKind scope) scopeLabel;

  @override
  State<_SpaceRoleDialog> createState() => _SpaceRoleDialogState();
}

class _SpaceRoleDialogState extends State<_SpaceRoleDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final List<SpacePermissionGrant> _grants = [...?widget.existing?.grants];
  late final List<SpacePermissionDenial> _denials = [
    ...?widget.existing?.denials,
  ];

  List<SpaceChannel> _targets(SpacePermissionScopeKind kind) => [
    for (final channel in widget.channels)
      if ((kind == SpacePermissionScopeKind.category &&
              channel.kind == SpaceChannelKind.category) ||
          (kind == SpacePermissionScopeKind.channel &&
              channel.kind != SpaceChannelKind.category))
        channel,
  ];

  List<SpacePermissionScopeKind> _scopeKinds(SpacePermission permission) => [
    for (final kind in SpacePermissionScopeKind.values)
      if (kind.supports(permission) &&
          (!kind.requiresTarget || _targets(kind).isNotEmpty))
        kind,
  ];

  SpacePermissionGrant? _firstAvailableGrant(
    SpacePermission permission, {
    SpacePermissionScopeKind? onlyKind,
    int? replacing,
  }) {
    final kinds = onlyKind == null ? _scopeKinds(permission) : [onlyKind];
    for (final kind in kinds) {
      if (!kind.supports(permission)) continue;
      if (!kind.requiresTarget) {
        final candidate = SpacePermissionGrant(
          permission: permission,
          scope: SpacePermissionScope(kind: kind),
        );
        if (widget.canUseRule(permission, candidate.scope) &&
            !_grants.indexed.any(
              (entry) => entry.$1 != replacing && entry.$2 == candidate,
            )) {
          return candidate;
        }
        continue;
      }
      for (final target in _targets(kind)) {
        final candidate = SpacePermissionGrant(
          permission: permission,
          scope: SpacePermissionScope(kind: kind, targetId: target.channelId),
        );
        if (widget.canUseRule(permission, candidate.scope) &&
            !_grants.indexed.any(
              (entry) => entry.$1 != replacing && entry.$2 == candidate,
            )) {
          return candidate;
        }
      }
    }
    return null;
  }

  Iterable<(int, SpacePermissionGrant)> _permissionGrants(
    SpacePermission permission,
  ) => _grants.indexed.where((entry) => entry.$2.permission == permission);

  SpacePermissionDenial? _firstAvailableDenial(
    SpacePermission permission, {
    SpacePermissionScopeKind? onlyKind,
    int? replacing,
  }) {
    final kinds = onlyKind == null ? _scopeKinds(permission) : [onlyKind];
    for (final kind in kinds) {
      if (!kind.supports(permission)) continue;
      if (!kind.requiresTarget) {
        final candidate = SpacePermissionDenial(
          permission: permission,
          scope: SpacePermissionScope(kind: kind),
        );
        if (widget.canUseRule(permission, candidate.scope) &&
            !_denials.indexed.any(
              (entry) => entry.$1 != replacing && entry.$2 == candidate,
            )) {
          return candidate;
        }
        continue;
      }
      for (final target in _targets(kind)) {
        final candidate = SpacePermissionDenial(
          permission: permission,
          scope: SpacePermissionScope(kind: kind, targetId: target.channelId),
        );
        if (widget.canUseRule(permission, candidate.scope) &&
            !_denials.indexed.any(
              (entry) => entry.$1 != replacing && entry.$2 == candidate,
            )) {
          return candidate;
        }
      }
    }
    return null;
  }

  Iterable<(int, SpacePermissionDenial)> _permissionDenials(
    SpacePermission permission,
  ) => _denials.indexed.where((entry) => entry.$2.permission == permission);

  void _togglePermission(SpacePermission permission, bool selected) {
    setState(() {
      if (selected) {
        final grant = _firstAvailableGrant(
          permission,
          onlyKind: SpacePermissionScopeKind.space,
        );
        if (grant != null) _grants.add(grant);
      } else {
        _grants.removeWhere((grant) => grant.permission == permission);
      }
    });
  }

  void _changeScope(
    int index,
    SpacePermissionGrant current,
    SpacePermissionScopeKind kind,
  ) {
    final replacement = _firstAvailableGrant(
      current.permission,
      onlyKind: kind,
      replacing: index,
    );
    if (replacement != null) {
      setState(() => _grants[index] = replacement);
    }
  }

  void _changeTarget(int index, SpacePermissionGrant current, NodeId target) {
    final replacement = SpacePermissionGrant(
      permission: current.permission,
      scope: SpacePermissionScope(kind: current.scope.kind, targetId: target),
    );
    if (_grants.indexed.any(
      (entry) => entry.$1 != index && entry.$2 == replacement,
    )) {
      return;
    }
    setState(() => _grants[index] = replacement);
  }

  void _changeDenialScope(
    int index,
    SpacePermissionDenial current,
    SpacePermissionScopeKind kind,
  ) {
    final replacement = _firstAvailableDenial(
      current.permission,
      onlyKind: kind,
      replacing: index,
    );
    if (replacement != null) {
      setState(() => _denials[index] = replacement);
    }
  }

  void _changeDenialTarget(
    int index,
    SpacePermissionDenial current,
    NodeId target,
  ) {
    final replacement = SpacePermissionDenial(
      permission: current.permission,
      scope: SpacePermissionScope(kind: current.scope.kind, targetId: target),
    );
    if (_denials.indexed.any(
      (entry) => entry.$1 != index && entry.$2 == replacement,
    )) {
      return;
    }
    setState(() => _denials[index] = replacement);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = _name.text.trim();
    if (normalized.isEmpty ||
        (_grants.isEmpty && _denials.isEmpty) ||
        _grants.any((grant) => !grant.isStructurallyValid) ||
        _grants.toSet().length != _grants.length ||
        _denials.any((denial) => !denial.isStructurallyValid) ||
        _denials.toSet().length != _denials.length) {
      return;
    }
    Navigator.of(context).pop(
      _SpaceRoleDraft(
        name: normalized,
        grants: List.unmodifiable(_grants),
        denials: List.unmodifiable(_denials),
      ),
    );
  }

  Widget _scopeEditor(
    BuildContext context,
    int index,
    SpacePermissionGrant grant,
  ) {
    final l = AppL10n.of(context);
    final kinds = _scopeKinds(grant.permission)
        .where(
          (kind) =>
              kind == grant.scope.kind ||
              _firstAvailableGrant(
                    grant.permission,
                    onlyKind: kind,
                    replacing: index,
                  ) !=
                  null,
        )
        .toList(growable: false);
    final targets = grant.scope.kind.requiresTarget
        ? _targets(grant.scope.kind)
              .where((channel) {
                final candidate = SpacePermissionGrant(
                  permission: grant.permission,
                  scope: SpacePermissionScope(
                    kind: grant.scope.kind,
                    targetId: channel.channelId,
                  ),
                );
                return widget.canUseRule(
                      candidate.permission,
                      candidate.scope,
                    ) &&
                    (candidate == grant ||
                        !_grants.indexed.any(
                          (entry) => entry.$1 != index && entry.$2 == candidate,
                        ));
              })
              .toList(growable: false)
        : const <SpaceChannel>[];
    final scopeDropdown = DropdownButtonFormField<SpacePermissionScopeKind>(
      key: ValueKey('space-access-scope-${grant.permission.name}-$index'),
      initialValue: grant.scope.kind,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l.spaceAccessScopeLabel,
        isDense: true,
      ),
      items: [
        for (final kind in kinds)
          DropdownMenuItem(value: kind, child: Text(widget.scopeLabel(kind))),
      ],
      onChanged: (kind) {
        if (kind != null && kind != grant.scope.kind) {
          _changeScope(index, grant, kind);
        }
      },
    );
    final targetDropdown = grant.scope.kind.requiresTarget
        ? DropdownButtonFormField<String>(
            key: ValueKey(
              'space-access-scope-target-${grant.permission.name}-$index',
            ),
            initialValue: grant.scope.targetId?.hex,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.spaceAccessScopeTarget,
              isDense: true,
            ),
            items: [
              for (final channel in targets)
                DropdownMenuItem(
                  value: channel.channelId.hex,
                  child: Text(channel.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (target) {
              if (target != null) {
                _changeTarget(index, grant, NodeId.fromHex(target));
              }
            },
          )
        : null;
    final remove = IconButton(
      tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
      onPressed: () => setState(() => _grants.removeAt(index)),
      icon: const Icon(Icons.remove_circle_outline),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                scopeDropdown,
                if (targetDropdown != null) ...[
                  const SizedBox(height: 8),
                  targetDropdown,
                ],
                Align(alignment: Alignment.centerRight, child: remove),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Row(
            children: [
              Expanded(child: scopeDropdown),
              if (targetDropdown != null) ...[
                const SizedBox(width: 8),
                Expanded(child: targetDropdown),
              ],
              remove,
            ],
          ),
        );
      },
    );
  }

  Widget _denialScopeEditor(
    BuildContext context,
    int index,
    SpacePermissionDenial denial,
  ) {
    final l = AppL10n.of(context);
    final kinds = _scopeKinds(denial.permission)
        .where(
          (kind) =>
              kind == denial.scope.kind ||
              _firstAvailableDenial(
                    denial.permission,
                    onlyKind: kind,
                    replacing: index,
                  ) !=
                  null,
        )
        .toList(growable: false);
    final targets = denial.scope.kind.requiresTarget
        ? _targets(denial.scope.kind)
              .where((channel) {
                final candidate = SpacePermissionDenial(
                  permission: denial.permission,
                  scope: SpacePermissionScope(
                    kind: denial.scope.kind,
                    targetId: channel.channelId,
                  ),
                );
                return widget.canUseRule(
                      candidate.permission,
                      candidate.scope,
                    ) &&
                    (candidate == denial ||
                        !_denials.indexed.any(
                          (entry) => entry.$1 != index && entry.$2 == candidate,
                        ));
              })
              .toList(growable: false)
        : const <SpaceChannel>[];
    final scopeDropdown = DropdownButtonFormField<SpacePermissionScopeKind>(
      key: ValueKey('space-access-deny-scope-${denial.permission.name}-$index'),
      initialValue: denial.scope.kind,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l.spaceAccessDenyScopeLabel,
        isDense: true,
        prefixIcon: const Icon(Icons.block, size: 18),
      ),
      items: [
        for (final kind in kinds)
          DropdownMenuItem(value: kind, child: Text(widget.scopeLabel(kind))),
      ],
      onChanged: (kind) {
        if (kind != null && kind != denial.scope.kind) {
          _changeDenialScope(index, denial, kind);
        }
      },
    );
    final targetDropdown = denial.scope.kind.requiresTarget
        ? DropdownButtonFormField<String>(
            key: ValueKey(
              'space-access-deny-target-${denial.permission.name}-$index',
            ),
            initialValue: denial.scope.targetId?.hex,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.spaceAccessScopeTarget,
              isDense: true,
            ),
            items: [
              for (final channel in targets)
                DropdownMenuItem(
                  value: channel.channelId.hex,
                  child: Text(channel.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (target) {
              if (target != null) {
                _changeDenialTarget(index, denial, NodeId.fromHex(target));
              }
            },
          )
        : null;
    final remove = IconButton(
      tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
      onPressed: () => setState(() => _denials.removeAt(index)),
      icon: const Icon(Icons.remove_circle_outline),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                scopeDropdown,
                if (targetDropdown != null) ...[
                  const SizedBox(height: 8),
                  targetDropdown,
                ],
                Align(alignment: Alignment.centerRight, child: remove),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Row(
            children: [
              Expanded(child: scopeDropdown),
              if (targetDropdown != null) ...[
                const SizedBox(width: 8),
                Expanded(child: targetDropdown),
              ],
              remove,
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final canSave =
        _name.text.trim().isNotEmpty &&
        (_grants.isNotEmpty || _denials.isNotEmpty) &&
        _grants.every((grant) => grant.isStructurallyValid) &&
        _grants.toSet().length == _grants.length &&
        _denials.every((denial) => denial.isStructurallyValid) &&
        _denials.toSet().length == _denials.length;
    return AlertDialog(
      title: Text(
        widget.existing == null ? l.spaceAccessRoleAdd : l.spaceAccessRoleEdit,
      ),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('space-access-role-name'),
                  controller: _name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: l.spaceAccessRoleName),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.spaceAccessPermissionAreas,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                for (final permission in SpacePermission.values)
                  if (_permissionGrants(permission).isNotEmpty ||
                      _permissionDenials(permission).isNotEmpty ||
                      _firstAvailableGrant(permission) != null ||
                      _firstAvailableDenial(permission) != null) ...[
                    Builder(
                      builder: (context) {
                        final selected = _permissionGrants(
                          permission,
                        ).isNotEmpty;
                        return CheckboxListTile(
                          key: ValueKey(
                            'space-access-permission-${permission.name}',
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: selected,
                          title: Text(widget.permissionLabel(permission)),
                          onChanged: (value) =>
                              _togglePermission(permission, value == true),
                        );
                      },
                    ),
                    for (final entry in _permissionGrants(permission).toList())
                      _scopeEditor(context, entry.$1, entry.$2),
                    if (_permissionGrants(permission).isNotEmpty &&
                        _firstAvailableGrant(permission) != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: ValueKey(
                            'space-access-add-scope-${permission.name}',
                          ),
                          onPressed: () {
                            final grant = _firstAvailableGrant(permission);
                            if (grant != null) {
                              setState(() => _grants.add(grant));
                            }
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(l.spaceAccessAddArea),
                        ),
                      ),
                    for (final entry in _permissionDenials(permission).toList())
                      _denialScopeEditor(context, entry.$1, entry.$2),
                    if (_firstAvailableDenial(permission) != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: ValueKey(
                            'space-access-add-deny-${permission.name}',
                          ),
                          onPressed: () {
                            final denial = _firstAvailableDenial(permission);
                            if (denial != null) {
                              setState(() => _denials.add(denial));
                            }
                          },
                          icon: const Icon(Icons.block, size: 18),
                          label: Text(l.spaceAccessAddDenyArea),
                        ),
                      ),
                  ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-access-role-save'),
          onPressed: canSave ? _submit : null,
          child: Text(l.actionSave),
        ),
      ],
    );
  }
}

final class _SpaceAccessMemberOption {
  const _SpaceAccessMemberOption({required this.id, required this.label});

  final NodeId id;
  final String label;
}

final class _SpaceGroupDraft {
  const _SpaceGroupDraft({
    required this.name,
    required this.members,
    required this.roleIds,
  });

  final Set<NodeId> members;
  final Set<String> roleIds;
  final String name;
}

class _SpaceGroupDialog extends StatefulWidget {
  const _SpaceGroupDialog({
    required this.existing,
    required this.members,
    required this.roles,
  });

  final SpaceMemberGroup? existing;
  final List<_SpaceAccessMemberOption> members;
  final List<SpaceRoleDefinition> roles;

  @override
  State<_SpaceGroupDialog> createState() => _SpaceGroupDialogState();
}

class _SpaceGroupDialogState extends State<_SpaceGroupDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final Set<NodeId> _members = {...?widget.existing?.members};
  late final Set<String> _roleIds = {...?widget.existing?.roleIds};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = _name.text.trim();
    if (normalized.isEmpty || _members.isEmpty || _roleIds.isEmpty) return;
    Navigator.of(context).pop(
      _SpaceGroupDraft(
        name: normalized,
        members: Set.unmodifiable(_members),
        roleIds: Set.unmodifiable(_roleIds),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final canSave =
        _name.text.trim().isNotEmpty &&
        _members.isNotEmpty &&
        _roleIds.isNotEmpty;
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? l.spaceAccessGroupAdd
            : l.spaceAccessGroupEdit,
      ),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('space-access-group-name'),
                  controller: _name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: l.spaceAccessGroupName,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Text(
                  l.spaceAccessRoles,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final role in widget.roles)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _roleIds.contains(role.roleId),
                    title: Text(role.name),
                    onChanged: (selected) => setState(() {
                      if (selected == true) {
                        _roleIds.add(role.roleId);
                      } else {
                        _roleIds.remove(role.roleId);
                      }
                    }),
                  ),
                const SizedBox(height: 8),
                Text(
                  l.spaceMembers(widget.members.length),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final member in widget.members)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _members.contains(member.id),
                    title: Text(member.label),
                    subtitle: Text(member.id.short),
                    onChanged: (selected) => setState(() {
                      if (selected == true) {
                        _members.add(member.id);
                      } else {
                        _members.remove(member.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-access-group-save'),
          onPressed: canSave ? _submit : null,
          child: Text(l.actionSave),
        ),
      ],
    );
  }
}

class _SpaceDirectRolesDialog extends StatefulWidget {
  const _SpaceDirectRolesDialog({
    required this.memberLabel,
    required this.roles,
    required this.selectedRoleIds,
  });

  final String memberLabel;
  final List<SpaceRoleDefinition> roles;
  final Set<String> selectedRoleIds;

  @override
  State<_SpaceDirectRolesDialog> createState() =>
      _SpaceDirectRolesDialogState();
}

class _SpaceDirectRolesDialogState extends State<_SpaceDirectRolesDialog> {
  late final Set<String> _selected = {...widget.selectedRoleIds};

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceAccessDirectRoles),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.memberLabel),
            const SizedBox(height: 8),
            for (final role in widget.roles)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(role.roleId),
                title: Text(role.name),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _selected.add(role.roleId);
                  } else {
                    _selected.remove(role.roleId);
                  }
                }),
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
          key: const ValueKey('space-access-direct-save'),
          onPressed: () =>
              Navigator.of(context).pop(Set.unmodifiable(_selected)),
          child: Text(l.actionSave),
        ),
      ],
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
