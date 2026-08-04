import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart' show Conversation;
import '../../domain/group.dart';
import '../../domain/space_action_log.dart';
import '../../domain/space_moderation.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show conversationsProvider;

/// The sentence one described action reads as.
///
/// Top-level and dependent only on [AppL10n] so the op→kind→sentence chain can
/// be checked end to end without a widget tree.
String spaceActionTitle(
  AppL10n l,
  SpaceActionDescriptor descriptor,
  String member,
) => switch (descriptor.kind) {
  SpaceActionKind.memberAdded => l.spaceActionMemberAdded(member),
  SpaceActionKind.memberRemoved => l.spaceActionMemberRemoved(member),
  SpaceActionKind.memberLeft => l.spaceActionMemberLeft(member),
  SpaceActionKind.roleChanged => l.spaceActionRoleChanged(member),
  SpaceActionKind.ownershipTransferred => l.spaceActionOwnershipTransferred(
    member,
  ),
  SpaceActionKind.memberMuted => l.spaceActionMemberMuted(member),
  SpaceActionKind.memberUnmuted => l.spaceActionMemberUnmuted(member),
  SpaceActionKind.memberBanned => l.spaceActionMemberBanned(member),
  SpaceActionKind.moderationApplied => l.spaceActionModerationApplied(member),
  SpaceActionKind.moderationRevoked => l.spaceActionModerationRevoked(member),
  SpaceActionKind.channelCreated => l.spaceActionChannelCreated,
  SpaceActionKind.channelUpdated => l.spaceActionChannelUpdated,
  SpaceActionKind.spaceRenamed => l.spaceActionSpaceRenamed,
  SpaceActionKind.spaceDescriptionChanged =>
    l.spaceActionSpaceDescriptionChanged,
  SpaceActionKind.spaceProfileMediaChanged =>
    l.spaceActionSpaceProfileMediaChanged,
  SpaceActionKind.rulesPublished => l.spaceActionRulesPublished,
  SpaceActionKind.rulesAccepted => l.spaceActionRulesAccepted(member),
  SpaceActionKind.accessPolicyChanged => l.spaceActionAccessPolicyChanged,
  SpaceActionKind.retentionChanged => l.spaceActionRetentionChanged,
  SpaceActionKind.spaceArchived => l.spaceActionSpaceArchived,
  SpaceActionKind.spaceDeleted => l.spaceActionSpaceDeleted,
  SpaceActionKind.spaceRestored => l.spaceActionSpaceRestored,
  SpaceActionKind.postPinChanged => l.spaceActionPostPinChanged,
  SpaceActionKind.recommendationCampaignChanged =>
    l.spaceActionRecommendationCampaignChanged,
  SpaceActionKind.recommendationPolicyChanged =>
    l.spaceActionRecommendationPolicyChanged,
  SpaceActionKind.encryptionRotated => l.spaceActionEncryptionRotated,
  SpaceActionKind.checkpointRecorded => l.spaceActionCheckpointRecorded,
  SpaceActionKind.authorityWithdrawn => l.spaceActionAuthorityWithdrawn(member),
  SpaceActionKind.authorityReturned => l.spaceActionAuthorityReturned(member),
  SpaceActionKind.other => l.spaceActionOther,
};

String _roleLabel(AppL10n l, GroupRole role) => switch (role) {
  GroupRole.owner => l.spaceRoleOwner,
  GroupRole.admin => l.spaceRoleAdmin,
  GroupRole.member => l.spaceRoleMember,
};

String _moderationLabel(AppL10n l, SpaceModerationKind kind) => switch (kind) {
  SpaceModerationKind.warning => l.spaceModerationWarning,
  SpaceModerationKind.deleteMessage => l.spaceModerationDeleteMessage,
  SpaceModerationKind.deletePost => l.spaceModerationDeletePost,
  SpaceModerationKind.restrictPublishing => l.spaceModerationRestrictPublishing,
  SpaceModerationKind.restrictMessages => l.spaceModerationRestrictMessages,
  SpaceModerationKind.restrictVoice => l.spaceModerationRestrictVoice,
  SpaceModerationKind.mute => l.spaceModerationMute,
  SpaceModerationKind.timeout => l.spaceModerationTimeout,
  SpaceModerationKind.temporaryBan => l.spaceModerationTemporaryBan,
  SpaceModerationKind.permanentBan => l.spaceModerationPermanentBan,
};

/// The extra clear-text line a described action can carry, or null.
String? spaceActionDetail(AppL10n l, SpaceActionDescriptor descriptor) {
  if (descriptor.channelName != null) {
    return l.spaceActionDetailChannel(descriptor.channelName!);
  }
  if (descriptor.kind == SpaceActionKind.spaceRenamed &&
      descriptor.text != null) {
    return l.spaceActionDetailNewName(descriptor.text!);
  }
  if (descriptor.moderationKind != null) {
    return l.spaceActionDetailModeration(
      _moderationLabel(l, descriptor.moderationKind!),
    );
  }
  if (descriptor.role != null) {
    return l.spaceActionDetailRole(_roleLabel(l, descriptor.role!));
  }
  return null;
}

IconData _actionIcon(SpaceActionKind kind) => switch (kind) {
  SpaceActionKind.memberAdded ||
  SpaceActionKind.memberRemoved ||
  SpaceActionKind.memberLeft => Icons.person_outline,
  SpaceActionKind.roleChanged ||
  SpaceActionKind.ownershipTransferred ||
  SpaceActionKind.authorityWithdrawn ||
  SpaceActionKind.authorityReturned ||
  SpaceActionKind.accessPolicyChanged => Icons.admin_panel_settings_outlined,
  SpaceActionKind.memberMuted ||
  SpaceActionKind.memberUnmuted ||
  SpaceActionKind.memberBanned ||
  SpaceActionKind.moderationApplied ||
  SpaceActionKind.moderationRevoked => Icons.gavel_outlined,
  SpaceActionKind.channelCreated ||
  SpaceActionKind.channelUpdated => Icons.tag_outlined,
  SpaceActionKind.spaceRenamed ||
  SpaceActionKind.spaceDescriptionChanged ||
  SpaceActionKind.spaceProfileMediaChanged ||
  SpaceActionKind.rulesPublished ||
  SpaceActionKind.rulesAccepted => Icons.tune_outlined,
  SpaceActionKind.retentionChanged => Icons.inventory_2_outlined,
  SpaceActionKind.spaceArchived ||
  SpaceActionKind.spaceDeleted ||
  SpaceActionKind.spaceRestored => Icons.archive_outlined,
  SpaceActionKind.postPinChanged => Icons.push_pin_outlined,
  SpaceActionKind.recommendationCampaignChanged ||
  SpaceActionKind.recommendationPolicyChanged => Icons.share_outlined,
  SpaceActionKind.encryptionRotated => Icons.key_outlined,
  SpaceActionKind.checkpointRecorded ||
  SpaceActionKind.other => Icons.more_horiz,
};

/// The Space's signed administrative history, newest first.
///
/// Rows the viewer may not read keep their place as an explicit unavailable
/// row. Dropping them would quietly rewrite the order and the count; leaving
/// them lets a member see that something happened without learning what.
class SpaceRecentActionsScreen extends ConsumerWidget {
  const SpaceRecentActionsScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  String _date(BuildContext context, int timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(date)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  String _memberLabel(
    AppL10n l,
    NodeId self,
    NodeId member,
    List<Conversation> conversations,
  ) {
    if (member == self) return l.spaceYou;
    for (final conversation in conversations) {
      if (conversation.peer.nodeId == member) return conversation.peer.label;
    }
    return member.short;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final conversations =
        ref.watch(conversationsProvider).value ?? const <Conversation>[];
    NodeId spaceId;
    try {
      spaceId = NodeId.fromHex(spaceIdHex);
    } catch (_) {
      return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
    }
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      builder: (context, _) => FutureBuilder<List<SpaceActionLogItem>>(
        future: service.spaceRecentActions(spaceId),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Scaffold(
              appBar: AppBar(
                leading: const RootedBackButton(),
                title: Text(l.spaceRecentActionsTitle),
              ),
              body: const Center(child: CircularProgressIndicator()),
            );
          }
          final items = snapshot.data!;
          return Scaffold(
            appBar: AppBar(
              leading: const RootedBackButton(),
              title: Text(l.spaceRecentActionsTitle),
            ),
            body: items.isEmpty
                ? Center(child: Text(l.spaceRecentActionsEmpty))
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView.separated(
                        key: const ValueKey('space-recent-actions-list'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 56),
                        itemBuilder: (context, index) =>
                            _row(context, l, service.selfId, conversations,
                                items[index]),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AppL10n l,
    NodeId self,
    List<Conversation> conversations,
    SpaceActionLogItem item,
  ) {
    final descriptor = item.descriptor;
    if (descriptor == null) {
      return ListTile(
        key: ValueKey('space-recent-action-withheld-${item.stableId}'),
        leading: Icon(
          Icons.lock_outline,
          color: Theme.of(context).colorScheme.outline,
        ),
        title: Text(
          l.spaceRecentActionsWithheld,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        subtitle: Text(
          '${l.spaceRecentActionsWithheldHint}\n${_date(context, item.createdAtMs)}',
        ),
        isThreeLine: true,
      );
    }
    final member = descriptor.target == null
        ? ''
        : _memberLabel(l, self, descriptor.target!, conversations);
    final detail = spaceActionDetail(l, descriptor);
    final by = l.spaceRecentActionsBy(
      _memberLabel(l, self, item.author!, conversations),
    );
    return ListTile(
      key: ValueKey('space-recent-action-${item.stableId}'),
      leading: Icon(_actionIcon(descriptor.kind)),
      title: Text(spaceActionTitle(l, descriptor, member)),
      subtitle: Text(
        detail == null
            ? '${_date(context, item.createdAtMs)} · $by'
            : '$detail\n${_date(context, item.createdAtMs)} · $by',
      ),
      isThreeLine: detail != null,
    );
  }
}
