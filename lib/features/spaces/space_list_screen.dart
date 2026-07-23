import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/space_invite.dart';
import '../../domain/space_join_request.dart';
import '../../domain/space_lifecycle.dart';
import '../../domain/space_membership.dart';
import '../../domain/space_moderation.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../chat/chat_actions.dart';
import '../home/home_section_scaffold.dart';

/// User-facing list of communities. Group chats remain in the Chats section.
class SpaceListScreen extends ConsumerStatefulWidget {
  const SpaceListScreen({super.key});

  @override
  ConsumerState<SpaceListScreen> createState() => _SpaceListScreenState();
}

class _SpaceListScreenState extends ConsumerState<SpaceListScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _startSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  bool _matches(String value) =>
      value.toLowerCase().contains(_query.trim().toLowerCase());

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

  String _moderationKindLabel(AppL10n l, SpaceModerationKind kind) =>
      switch (kind) {
        SpaceModerationKind.warning => l.spaceModerationWarning,
        SpaceModerationKind.deleteMessage => l.spaceModerationDeleteMessage,
        SpaceModerationKind.deletePost => l.spaceModerationDeletePost,
        SpaceModerationKind.restrictPublishing =>
          l.spaceModerationRestrictPublishing,
        SpaceModerationKind.restrictMessages =>
          l.spaceModerationRestrictMessages,
        SpaceModerationKind.restrictVoice => l.spaceModerationRestrictVoice,
        SpaceModerationKind.mute => l.spaceModerationMute,
        SpaceModerationKind.timeout => l.spaceModerationTimeout,
        SpaceModerationKind.temporaryBan => l.spaceModerationTemporaryBan,
        SpaceModerationKind.permanentBan => l.spaceModerationPermanentBan,
      };

  String _appealStatus(AppL10n l, SpaceModerationAppealOutboxEntry entry) =>
      switch (entry.decision?.outcome) {
        null => l.spaceModerationAppealPending,
        SpaceModerationAppealOutcome.rejected =>
          l.spaceModerationAppealRejected,
        SpaceModerationAppealOutcome.actionRevoked =>
          l.spaceModerationAppealRevoked,
        SpaceModerationAppealOutcome.acknowledgedIrreversible =>
          l.spaceModerationAppealAcknowledged,
      };

  String _membershipStatusLabel(
    BuildContext context,
    SpaceMembershipProjection membership,
  ) {
    final l = AppL10n.of(context);
    return switch (membership.status) {
      SpaceMembershipStatus.pending => l.spaceMembershipPending,
      SpaceMembershipStatus.active => l.spaceMembershipActive,
      SpaceMembershipStatus.suspended when membership.untilMs != null =>
        l.spaceMembershipSuspendedUntil(
          _membershipDateTime(context, membership.untilMs!),
        ),
      SpaceMembershipStatus.suspended => l.spaceMembershipSuspended,
      SpaceMembershipStatus.left => l.spaceMembershipLeft,
      SpaceMembershipStatus.banned => l.spaceMembershipBanned,
    };
  }

  String _membershipDateTime(BuildContext context, int milliseconds) {
    final localizations = MaterialLocalizations.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return '${localizations.formatCompactDate(date)}, '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  IconData _membershipIcon(SpaceMembershipStatus status) => switch (status) {
    SpaceMembershipStatus.pending => Icons.hourglass_top_outlined,
    SpaceMembershipStatus.active => Icons.check_circle_outline,
    SpaceMembershipStatus.suspended => Icons.pause_circle_outline,
    SpaceMembershipStatus.left => Icons.logout_outlined,
    SpaceMembershipStatus.banned => Icons.block_outlined,
  };

  Future<void> _appeal(
    BuildContext context,
    GroupService service,
    SpaceModerationAppealCandidate candidate,
  ) async {
    var draftText = '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppL10n.of(context).spaceModerationAppealDialogTitle),
        content: TextField(
          key: const ValueKey('space-moderation-appeal-text'),
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: kSpaceModerationAppealMax,
          decoration: InputDecoration(
            labelText: AppL10n.of(context).spaceModerationAppealText,
            alignLabelWithHint: true,
          ),
          onChanged: (value) => draftText = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-moderation-appeal-submit'),
            onPressed: () {
              final value = draftText.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: Text(AppL10n.of(context).spaceModerationAppealAction),
          ),
        ],
      ),
    );
    if (text == null) return;
    final ok = await service.appealSpaceModeration(
      candidate.spaceId,
      candidate.record.actionId,
      text: text,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? AppL10n.of(context).spaceModerationAppealSent
              : AppL10n.of(context).spaceOperationFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final spaces = ref.watch(spaceListProvider);
    return HomeSectionScaffold(
      title: l.navCommunities,
      searching: _searching,
      searchController: _searchController,
      searchHint: l.searchHint,
      onSearchStart: _startSearch,
      onSearchClose: _closeSearch,
      onSearchChanged: (value) => setState(() => _query = value),
      contextActions: [
        if (service != null)
          IconButton(
            key: const ValueKey('space-join-link-action'),
            tooltip: l.spaceJoinAction,
            onPressed: () => _requestJoin(context, service),
            icon: const Icon(Icons.link),
          ),
      ],
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
        data: (allItems) {
          final searching = _query.trim().isNotEmpty;
          final items = searching
              ? allItems
                    .where(
                      (space) =>
                          _matches(space.name) ||
                          _matches(space.description) ||
                          _matches(space.preview) ||
                          _matches(space.groupId.hex),
                    )
                    .toList(growable: false)
              : allItems;
          return FutureBuilder<List<Object?>>(
            future: service == null
                ? Future.value(const <Object?>[
                    <PendingSpaceInvite>[],
                    <SpaceJoinOutboxEntry>[],
                    <SpaceModerationAppealCandidate>[],
                    <SpaceModerationAppealOutboxEntry>[],
                    <String, String>{},
                    <SpaceMembershipProjection>[],
                  ])
                : Future.wait<Object?>([
                    service.pendingSpaceInvites(),
                    service.outgoingSpaceJoinRequests(),
                    service.appealableSpaceModerationActions(),
                    service.outgoingSpaceModerationAppeals(),
                    service.moderationAppealSpaceNames(),
                    service.spaceMemberships(),
                  ]),
            builder: (context, inviteSnapshot) {
              if (service != null && !inviteSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = inviteSnapshot.data;
              final allInvites = data == null
                  ? const <PendingSpaceInvite>[]
                  : data[0] as List<PendingSpaceInvite>;
              final allJoinRequests = data == null
                  ? const <SpaceJoinOutboxEntry>[]
                  : data[1] as List<SpaceJoinOutboxEntry>;
              final allAppealCandidates = data == null
                  ? const <SpaceModerationAppealCandidate>[]
                  : data[2] as List<SpaceModerationAppealCandidate>;
              final allAppeals = data == null
                  ? const <SpaceModerationAppealOutboxEntry>[]
                  : data[3] as List<SpaceModerationAppealOutboxEntry>;
              final appealSpaceNames = data == null
                  ? const <String, String>{}
                  : data[4] as Map<String, String>;
              final allMemberships = data == null
                  ? const <SpaceMembershipProjection>[]
                  : data[5] as List<SpaceMembershipProjection>;
              final membershipBySpace = {
                for (final membership in allMemberships)
                  membership.spaceId.hex: membership,
              };
              final invites = searching
                  ? allInvites
                        .where(
                          (pending) =>
                              _matches(pending.invite.spaceName) ||
                              _matches(pending.invite.inviter.hex),
                        )
                        .toList(growable: false)
                  : allInvites;
              final joinRequests = searching
                  ? allJoinRequests
                        .where((entry) => _matches(entry.ticket.spaceName))
                        .toList(growable: false)
                  : allJoinRequests;
              final appealCandidates = searching
                  ? allAppealCandidates
                        .where(
                          (candidate) =>
                              _matches(candidate.spaceName) ||
                              _matches(candidate.record.action.reason),
                        )
                        .toList(growable: false)
                  : allAppealCandidates;
              final appeals = searching
                  ? allAppeals
                        .where(
                          (entry) =>
                              _matches(entry.appeal.spaceId.hex) ||
                              _matches(entry.appeal.text),
                        )
                        .toList(growable: false)
                  : allAppeals;
              final listedIds = {for (final item in allItems) item.groupId.hex};
              final appealSpaceIds = {
                for (final candidate in allAppealCandidates)
                  candidate.spaceId.hex,
                for (final entry in allAppeals) entry.appeal.spaceId.hex,
              };
              final inactiveMemberships = allMemberships
                  .where(
                    (membership) =>
                        !listedIds.contains(membership.spaceId.hex) &&
                        membership.status != SpaceMembershipStatus.pending &&
                        !appealSpaceIds.contains(membership.spaceId.hex) &&
                        (!searching ||
                            _matches(membership.name) ||
                            _matches(membership.reason ?? '') ||
                            _matches(membership.spaceId.hex)),
                  )
                  .toList(growable: false);
              if (items.isEmpty &&
                  invites.isEmpty &&
                  joinRequests.isEmpty &&
                  appealCandidates.isEmpty &&
                  appeals.isEmpty &&
                  inactiveMemberships.isEmpty) {
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
                      Text(searching ? l.searchNoResults : l.spaceEmpty),
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
                  if (inactiveMemberships.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        l.spaceMembershipStatusTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (final membership in inactiveMemberships)
                      Card(
                        key: ValueKey(
                          'space-membership-${membership.status.name}-${membership.spaceId.hex}',
                        ),
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(_membershipIcon(membership.status)),
                          ),
                          title: Text(
                            membership.name.isEmpty
                                ? membership.spaceId.short
                                : membership.name,
                          ),
                          subtitle: Text(
                            [
                              _membershipStatusLabel(context, membership),
                              if (membership.reason != null) membership.reason!,
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing:
                              membership.status == SpaceMembershipStatus.left &&
                                  service != null
                              ? TextButton(
                                  key: ValueKey(
                                    'space-membership-rejoin-${membership.spaceId.hex}',
                                  ),
                                  onPressed: () =>
                                      _requestJoin(context, service),
                                  child: Text(l.spaceJoinAction),
                                )
                              : null,
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                  if (appealCandidates.isNotEmpty || appeals.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        l.spaceModerationAppealsTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (final candidate in appealCandidates)
                      Card(
                        key: ValueKey(
                          'space-moderation-appealable-${candidate.record.actionId}',
                        ),
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.balance_outlined),
                          ),
                          title: Text(candidate.spaceName),
                          subtitle: Text(
                            [
                              if (membershipBySpace[candidate.spaceId.hex] !=
                                  null)
                                _membershipStatusLabel(
                                  context,
                                  membershipBySpace[candidate.spaceId.hex]!,
                                ),
                              '${_moderationKindLabel(l, candidate.record.action.kind)} · '
                                  '${candidate.record.action.reason}',
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: FilledButton.tonal(
                            key: ValueKey(
                              'space-moderation-appeal-${candidate.record.actionId}',
                            ),
                            onPressed: service == null
                                ? null
                                : () => _appeal(context, service, candidate),
                            child: Text(l.spaceModerationAppealAction),
                          ),
                        ),
                      ),
                    for (final entry in appeals)
                      Card(
                        key: ValueKey(
                          'space-moderation-appeal-outgoing-${entry.appeal.appealId}',
                        ),
                        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              entry.pending
                                  ? Icons.hourglass_top_outlined
                                  : Icons.fact_check_outlined,
                            ),
                          ),
                          title: Text(
                            appealSpaceNames[entry.appeal.spaceId.hex] ??
                                entry.appeal.spaceId.short,
                          ),
                          subtitle: Text(
                            [
                              if (membershipBySpace[entry.appeal.spaceId.hex] !=
                                  null)
                                _membershipStatusLabel(
                                  context,
                                  membershipBySpace[entry.appeal.spaceId.hex]!,
                                ),
                              _appealStatus(l, entry),
                              if (entry.decision?.reason != null)
                                entry.decision!.reason,
                            ].join('\n'),
                          ),
                          trailing: entry.pending
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                  for (var index = 0; index < items.length; index++) ...[
                    if (index > 0) const Divider(height: 1, indent: 72),
                    Builder(
                      builder: (context) {
                        final space = items[index];
                        final membership = membershipBySpace[space.groupId.hex];
                        final membershipSuspended =
                            membership?.status ==
                            SpaceMembershipStatus.suspended;
                        final notificationMode = space.notificationMode;
                        final notificationPolicy = NotificationMutePolicy(
                          mode: notificationMode,
                          until: space.notificationUntil,
                        );
                        final hasLifecycleMarker =
                            space.lifecycleState != SpaceLifecycleState.active;
                        final hasUnread =
                            space.unread > 0 || space.postUnread > 0;
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
                            [
                              if (membershipSuspended)
                                _membershipStatusLabel(context, membership!),
                              space.description.isNotEmpty
                                  ? space.description
                                  : space.preview.isEmpty
                                  ? space.groupId.short
                                  : space.preview,
                            ].join('\n'),
                            maxLines: membershipSuspended ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing:
                              notificationMode == NotificationMuteMode.all &&
                                  !hasUnread &&
                                  !hasLifecycleMarker &&
                                  !membershipSuspended
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (membershipSuspended) ...[
                                      Tooltip(
                                        message: _membershipStatusLabel(
                                          context,
                                          membership!,
                                        ),
                                        child: const Icon(
                                          Icons.pause_circle_outline,
                                          size: 18,
                                        ),
                                      ),
                                      if (notificationMode !=
                                              NotificationMuteMode.all ||
                                          hasLifecycleMarker ||
                                          hasUnread)
                                        const SizedBox(width: 10),
                                    ],
                                    if (notificationMode !=
                                        NotificationMuteMode.all) ...[
                                      notificationMuteModeIndicator(
                                        context,
                                        notificationMode,
                                        key: ValueKey(
                                          'space-notification-${notificationMode.name}-${space.groupId.hex}',
                                        ),
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                      if (hasLifecycleMarker || hasUnread)
                                        const SizedBox(width: 10),
                                    ],
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
                          onLongPress: service == null
                              ? null
                              : () => showNotificationPolicySheet(
                                  context,
                                  notificationPolicy,
                                  onChanged: (mode, until) =>
                                      service.setGroupNotificationPolicy(
                                        space.groupId,
                                        mode,
                                        until,
                                      ),
                                ),
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
