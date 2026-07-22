import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/call_signal.dart';
import '../../domain/chat.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_channel.dart';
import '../../domain/space_recommendation.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/group_call_service.dart';
import '../../state/messaging.dart' show conversationsProvider;

class SpaceScreen extends ConsumerWidget {
  const SpaceScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  Future<void> _openVoiceChannel(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    NodeId channelId,
  ) async {
    final calls = ref.read(groupCallServiceProvider);
    final room = calls?.activeRoomFor(spaceId, channelId: channelId);
    final ok = room == null
        ? await calls?.startCall(
                spaceId,
                const CallMedia(audio: true, video: false, screen: false),
                channelId: channelId,
              ) ??
              false
        : await calls?.joinRoom(spaceId, channelId: channelId) ?? false;
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceVoiceStartFailed)),
      );
    }
  }

  Future<void> _createChannel(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
  ) async {
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    var kind = SpaceChannelKind.text;
    var access = SpaceChannelAccess.space;
    final result =
        await showDialog<(String, SpaceChannelKind, SpaceChannelAccess)>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(l.spaceChannelCreateTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: l.spaceChannelNameHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SpaceChannelKind>(
                    initialValue: kind,
                    items: [
                      DropdownMenuItem(
                        value: SpaceChannelKind.text,
                        child: Text(l.spaceChannelText),
                      ),
                      DropdownMenuItem(
                        value: SpaceChannelKind.voice,
                        child: Text(l.spaceChannelVoice),
                      ),
                      DropdownMenuItem(
                        value: SpaceChannelKind.category,
                        child: Text(l.spaceChannelCategory),
                      ),
                    ],
                    onChanged: access == SpaceChannelAccess.space
                        ? (value) {
                            if (value != null) {
                              setDialogState(() => kind = value);
                            }
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SpaceChannelAccess>(
                    initialValue: access,
                    decoration: InputDecoration(
                      labelText: l.spaceChannelAccess,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: SpaceChannelAccess.space,
                        child: Text(l.spaceChannelAccessSpace),
                      ),
                      DropdownMenuItem(
                        value: SpaceChannelAccess.restricted,
                        child: Text(l.spaceChannelAccessRestricted),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        access = value;
                        if (access != SpaceChannelAccess.space) {
                          kind = SpaceChannelKind.text;
                        }
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l.actionCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop((controller.text.trim(), kind, access)),
                  child: Text(l.spaceCreateAction),
                ),
              ],
            ),
          ),
        );
    controller.dispose();
    if (result == null || result.$1.isEmpty) return;
    final service = ref.read(groupServiceProvider);
    final created = await service?.createChannel(
      spaceId,
      name: result.$1,
      kind: result.$2,
      access: result.$3,
    );
    if (created == null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _shareRecommendation(
    BuildContext context,
    WidgetRef ref,
    GroupService service,
    NodeId spaceId,
    GroupState state,
    List<SpaceRecommendationCampaign> campaigns,
  ) async {
    final l = AppL10n.of(context);
    if (campaigns.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceRecommendationEmpty)));
      return;
    }
    SpaceRecommendationCampaign? campaign;
    if (campaigns.length == 1) {
      campaign = campaigns.single;
    } else {
      campaign = await showModalBottomSheet<SpaceRecommendationCampaign>(
        context: context,
        builder: (sheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheet).height * 0.65,
            child: ListView(
              children: [
                ListTile(title: Text(l.spaceRecommendationSelectCampaign)),
                for (final item in campaigns)
                  ListTile(
                    leading: const Icon(Icons.campaign_outlined),
                    title: Text(item.text),
                    onTap: () => Navigator.of(sheet).pop(item),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (campaign == null || !context.mounted) return;
    final contacts = (ref.read(conversationsProvider).valueOrNull ?? const [])
        .where(
          (conversation) =>
              conversation.peer.status == ContactStatus.accepted &&
              conversation.peer.nodeId != service.selfId &&
              !state.isMember(conversation.peer.nodeId),
        )
        .toList();
    final recipient = await showModalBottomSheet<Contact>(
      context: context,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.65,
          child: ListView(
            children: [
              ListTile(title: Text(l.spaceRecommendationSelectContact)),
              if (contacts.isEmpty)
                ListTile(title: Text(l.spaceNoContactsToAdd)),
              for (final conversation in contacts)
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(conversation.peer.label),
                  subtitle: Text(conversation.peer.nodeId.short),
                  onTap: () => Navigator.of(sheet).pop(conversation.peer),
                ),
            ],
          ),
        ),
      ),
    );
    if (recipient == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.spaceRecommendationShare),
        content: Text('${recipient.label}\n\n${campaign!.text}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-recommendation-share-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.spaceRecommendationShare),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await service.shareSpaceRecommendation(
      spaceId,
      campaign.campaignId,
      recipient.nodeId,
    );
    if (!context.mounted) return;
    final text = switch (result) {
      SpaceRecommendationShareResult.sent => l.spaceRecommendationSent,
      SpaceRecommendationShareResult.duplicate =>
        l.spaceRecommendationDuplicate,
      SpaceRecommendationShareResult.rateLimited =>
        l.spaceRecommendationRateLimited,
      SpaceRecommendationShareResult.alreadyMember =>
        l.spaceRecommendationAlreadyMember,
      _ => l.spaceOperationFailed,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
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
      builder: (context, _) => FutureBuilder(
        future: Future.wait<Object?>([
          service.stateOf(spaceId),
          service.channelsOf(spaceId),
          service.spaceRecommendationCampaigns(spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          final channels = snapshot.data![1] as List<SpaceChannel>;
          final recommendationCampaigns =
              snapshot.data![2] as List<SpaceRecommendationCampaign>;
          if (state == null) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          if (state.isDeleted) {
            return Scaffold(
              appBar: AppBar(title: Text(state.name)),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.delete_forever_outlined,
                        size: 52,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.spaceDeletedTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(l.spaceDeletedHint, textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            context.push('/space/$spaceIdHex/settings'),
                        icon: const Icon(Icons.settings_outlined),
                        label: Text(l.spaceSettingsTitle),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          final canManage = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.manageChannels);
          final archived = state.isArchived;
          return Scaffold(
            appBar: AppBar(
              title: Text(state.name),
              actions: [
                if (SpaceAcl(state).allows(
                      service.selfId,
                      SpacePermission.distributeContent,
                    ) &&
                    recommendationCampaigns.isNotEmpty)
                  IconButton(
                    key: const ValueKey('space-recommendation-share'),
                    tooltip: l.spaceRecommendationShare,
                    onPressed: () => _shareRecommendation(
                      context,
                      ref,
                      service,
                      spaceId,
                      state,
                      recommendationCampaigns,
                    ),
                    icon: const Icon(Icons.share_outlined),
                  ),
                IconButton(
                  tooltip: l.spacePostsTitle,
                  onPressed: () => context.push('/space/$spaceIdHex/posts'),
                  icon: const Icon(Icons.campaign_outlined),
                ),
                IconButton(
                  tooltip: l.spaceRulesTitle,
                  onPressed: () => context.push('/space/$spaceIdHex/rules'),
                  icon: const Icon(Icons.rule_outlined),
                ),
                IconButton(
                  tooltip: l.spaceModerationTitle,
                  onPressed: () =>
                      context.push('/space/$spaceIdHex/moderation'),
                  icon: const Icon(Icons.gavel_outlined),
                ),
                IconButton(
                  tooltip: l.spaceMembersTooltip,
                  onPressed: () => context.push('/space/$spaceIdHex/settings'),
                  icon: const Icon(Icons.manage_accounts_outlined),
                ),
              ],
            ),
            floatingActionButton: canManage
                ? FloatingActionButton(
                    heroTag: 'xveil-space-channel-create-$spaceIdHex',
                    tooltip: l.spaceChannelCreateTitle,
                    onPressed: () => _createChannel(context, ref, spaceId),
                    child: const Icon(Icons.add),
                  )
                : null,
            body: Column(
              children: [
                if (archived)
                  MaterialBanner(
                    leading: const Icon(Icons.archive_outlined),
                    content: Text(l.spaceArchivedHint),
                    actions: const [SizedBox.shrink()],
                  ),
                Expanded(
                  child: channels.isEmpty
                      ? Center(child: Text(l.spaceChannelsEmpty))
                      : ListView.builder(
                          itemCount: channels.length,
                          itemBuilder: (context, index) {
                            final channel = channels[index];
                            final isCategory =
                                channel.kind == SpaceChannelKind.category;
                            final icon = switch (channel.kind) {
                              SpaceChannelKind.text => Icons.tag,
                              SpaceChannelKind.voice =>
                                Icons.volume_up_outlined,
                              SpaceChannelKind.category =>
                                Icons.folder_outlined,
                            };
                            return ListTile(
                              contentPadding: EdgeInsets.only(
                                left: channel.categoryId == null ? 16 : 40,
                                right: 16,
                              ),
                              leading: Icon(icon),
                              title: Text(channel.name),
                              subtitle:
                                  channel.access == SpaceChannelAccess.space
                                  ? null
                                  : Text(
                                      channel.access ==
                                              SpaceChannelAccess.secret
                                          ? l.spaceChannelAccessSecret
                                          : l.spaceChannelAccessRestricted,
                                    ),
                              trailing: channel.isDefault
                                  ? const Icon(Icons.home_outlined, size: 18)
                                  : channel.access == SpaceChannelAccess.space
                                  ? null
                                  : Icon(
                                      channel.access ==
                                              SpaceChannelAccess.secret
                                          ? Icons.visibility_off_outlined
                                          : Icons.lock_outline,
                                      size: 18,
                                    ),
                              onTap:
                                  isCategory ||
                                      (archived &&
                                          channel.kind ==
                                              SpaceChannelKind.voice)
                                  ? null
                                  : () async {
                                      if (channel.kind ==
                                          SpaceChannelKind.voice) {
                                        await _openVoiceChannel(
                                          context,
                                          ref,
                                          spaceId,
                                          channel.channelId,
                                        );
                                        return;
                                      }
                                      context.push(
                                        '/space/$spaceIdHex/channel/'
                                        '${channel.channelId.hex}',
                                      );
                                    },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
