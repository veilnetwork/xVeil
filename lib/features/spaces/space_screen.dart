import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/call_signal.dart';
import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_channel.dart';
import '../../domain/space_recommendation.dart';
import '../../domain/space_retention.dart';
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
    List<SpaceChannel> channels,
  ) async {
    final service = ref.read(groupServiceProvider);
    final state = await service?.stateOf(spaceId);
    if (!context.mounted || service == null || state == null) return;
    final acl = SpaceAcl(state);
    final canCreateAtRoot = acl.allows(
      service.selfId,
      SpacePermission.manageChannels,
    );
    final allowedCategoryIds = {
      for (final channel in channels)
        if (channel.kind == SpaceChannelKind.category &&
            !channel.archived &&
            acl.allows(
              service.selfId,
              SpacePermission.manageChannels,
              channelId: channel.channelId,
              categoryId: channel.channelId,
            ))
          channel.channelId.hex,
    };
    if (!canCreateAtRoot && allowedCategoryIds.isEmpty) return;
    final result = await _showChannelEditor(
      context,
      channels: channels,
      members: state.members.values,
      canCreateAtRoot: canCreateAtRoot,
      allowedCategoryIds: allowedCategoryIds,
    );
    if (result == null) return;
    final created = await service.createChannel(
      spaceId,
      name: result.name,
      kind: result.kind,
      description: result.description,
      categoryId: result.categoryId,
      position: nextSpaceChannelPosition(
        channels,
        categoryId: result.categoryId,
      ),
      history: result.history,
      historySinceMs: result.historySinceMs,
      access: result.access,
      members: result.members,
    );
    if (created == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  Future<_SpaceChannelDraft?> _showChannelEditor(
    BuildContext context, {
    required List<SpaceChannel> channels,
    SpaceChannel? current,
    Iterable<GroupMember> members = const <GroupMember>[],
    bool canCreateAtRoot = true,
    Set<String>? allowedCategoryIds,
  }) async {
    final l = AppL10n.of(context);
    var name = current?.name ?? '';
    var description = current?.description ?? '';
    var kind = current?.kind ?? SpaceChannelKind.text;
    var access = current?.access ?? SpaceChannelAccess.space;
    var categoryHex = current?.categoryId?.hex ?? '';
    var history = current?.history ?? SpaceChannelHistory.fromJoin;
    var historySinceMs = current?.historySinceMs;
    final memberList = members.toList(growable: false);
    final selectedMembers = {
      for (final member in memberList)
        if (member.role.rank >= GroupRole.admin.rank) member.nodeId.hex,
    };
    final categories = channels
        .where(
          (channel) =>
              channel.kind == SpaceChannelKind.category &&
              !channel.archived &&
              channel.channelId != current?.channelId &&
              (allowedCategoryIds == null ||
                  allowedCategoryIds.contains(channel.channelId.hex)),
        )
        .toList(growable: false);
    if (current == null && !canCreateAtRoot && categories.isNotEmpty) {
      categoryHex = categories.first.channelId.hex;
    }
    return showDialog<_SpaceChannelDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            current == null ? l.spaceChannelCreateTitle : l.spaceChannelEdit,
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey('space-channel-name'),
                    initialValue: name,
                    autofocus: current == null,
                    maxLength: 100,
                    decoration: InputDecoration(
                      labelText: l.spaceChannelNameHint,
                    ),
                    onChanged: (value) => name = value,
                  ),
                  TextFormField(
                    key: const ValueKey('space-channel-description'),
                    initialValue: description,
                    maxLength: 1024,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: l.spaceChannelDescriptionHint,
                    ),
                    onChanged: (value) => description = value,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<SpaceChannelKind>(
                    key: const ValueKey('space-channel-kind'),
                    isExpanded: true,
                    initialValue: kind,
                    decoration: InputDecoration(labelText: l.spaceChannelKind),
                    items: [
                      DropdownMenuItem(
                        value: SpaceChannelKind.text,
                        child: Text(l.spaceChannelText),
                      ),
                      DropdownMenuItem(
                        value: SpaceChannelKind.voice,
                        child: Text(l.spaceChannelVoice),
                      ),
                      if (current != null || canCreateAtRoot)
                        DropdownMenuItem(
                          value: SpaceChannelKind.category,
                          child: Text(l.spaceChannelCategory),
                        ),
                    ],
                    onChanged: current != null
                        ? null
                        : (value) {
                            if (value == null) return;
                            setDialogState(() {
                              kind = value;
                              if (kind == SpaceChannelKind.category) {
                                access = SpaceChannelAccess.space;
                                categoryHex = '';
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SpaceChannelAccess>(
                    key: const ValueKey('space-channel-access'),
                    isExpanded: true,
                    initialValue: access,
                    decoration: InputDecoration(
                      labelText: l.spaceChannelAccess,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: SpaceChannelAccess.space,
                        child: Text(l.spaceChannelAccessSpace),
                      ),
                      if (current != null || canCreateAtRoot)
                        DropdownMenuItem(
                          value: SpaceChannelAccess.restricted,
                          child: Text(l.spaceChannelAccessRestricted),
                        ),
                    ],
                    onChanged: current != null
                        ? null
                        : (value) {
                            if (value == null) return;
                            setDialogState(() {
                              access = value;
                              if (access != SpaceChannelAccess.space &&
                                  kind == SpaceChannelKind.category) {
                                kind = SpaceChannelKind.text;
                                categoryHex = '';
                              }
                            });
                          },
                  ),
                  if (access == SpaceChannelAccess.space &&
                      kind != SpaceChannelKind.category) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('space-channel-category'),
                      isExpanded: true,
                      initialValue: categoryHex,
                      decoration: InputDecoration(
                        labelText: l.spaceChannelCategoryLabel,
                      ),
                      items: [
                        if (current != null || canCreateAtRoot)
                          DropdownMenuItem(
                            value: '',
                            child: Text(l.spaceChannelNoCategory),
                          ),
                        for (final category in categories)
                          DropdownMenuItem(
                            value: category.channelId.hex,
                            child: Text(category.name),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => categoryHex = value ?? ''),
                    ),
                  ],
                  if (access != SpaceChannelAccess.space &&
                      current == null &&
                      memberList.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l.spaceMembersTooltip,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (final member in memberList)
                      CheckboxListTile(
                        key: ValueKey(
                          'space-channel-create-member-${member.nodeId.hex}',
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: selectedMembers.contains(member.nodeId.hex),
                        onChanged: member.role.rank >= GroupRole.admin.rank
                            ? null
                            : (value) => setDialogState(() {
                                if (value ?? false) {
                                  selectedMembers.add(member.nodeId.hex);
                                } else {
                                  selectedMembers.remove(member.nodeId.hex);
                                }
                              }),
                        secondary: Icon(
                          member.role.rank >= GroupRole.admin.rank
                              ? Icons.shield_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(member.nodeId.short),
                        subtitle: Text(member.role.name),
                      ),
                  ],
                  if (kind == SpaceChannelKind.text) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<SpaceChannelHistory>(
                      key: const ValueKey('space-channel-history'),
                      isExpanded: true,
                      initialValue: history,
                      decoration: InputDecoration(
                        labelText: l.spaceChannelHistory,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: SpaceChannelHistory.fromJoin,
                          child: Text(l.spaceChannelHistoryFromJoin),
                        ),
                        DropdownMenuItem(
                          value: SpaceChannelHistory.full,
                          child: Text(l.spaceChannelHistoryFull),
                        ),
                        DropdownMenuItem(
                          value: SpaceChannelHistory.since,
                          child: Text(l.spaceChannelHistorySinceNow),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          history = value;
                          historySinceMs = value == SpaceChannelHistory.since
                              ? historySinceMs ??
                                    DateTime.now().millisecondsSinceEpoch
                              : null;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('space-channel-save'),
              onPressed: () {
                final normalized = name.trim();
                if (normalized.isEmpty) return;
                Navigator.of(dialogContext).pop(
                  _SpaceChannelDraft(
                    name: normalized,
                    description: description,
                    kind: kind,
                    access: access,
                    categoryId: categoryHex.isEmpty
                        ? null
                        : NodeId.fromHex(categoryHex),
                    history: history,
                    historySinceMs: history == SpaceChannelHistory.since
                        ? historySinceMs ??
                              DateTime.now().millisecondsSinceEpoch
                        : null,
                    members: access == SpaceChannelAccess.space
                        ? const <NodeId>[]
                        : memberList
                              .where(
                                (member) =>
                                    selectedMembers.contains(member.nodeId.hex),
                              )
                              .map((member) => member.nodeId)
                              .toList(growable: false),
                  ),
                );
              },
              child: Text(
                current == null ? l.spaceCreateAction : l.spaceChannelSave,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _manageProtectedChannelMembers(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    SpaceChannel channel,
  ) async {
    final state = await service.stateOf(spaceId);
    final current = await service.channelMembersOf(spaceId, channel.channelId);
    if (!context.mounted || state == null || current == null) return false;
    final canManage = SpaceAcl(state).allows(
      service.selfId,
      SpacePermission.manageChannels,
      channelId: channel.channelId,
      categoryId: channel.categoryId,
    );
    final selected = current.map((member) => member.hex).toSet();
    final saved = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppL10n.of(context).groupMembers(selected.length)),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final member in state.members.values)
                  CheckboxListTile(
                    key: ValueKey('space-channel-member-${member.nodeId.hex}'),
                    value: selected.contains(member.nodeId.hex),
                    onChanged:
                        !canManage || member.role.rank >= GroupRole.admin.rank
                        ? null
                        : (value) => setDialogState(() {
                            if (value ?? false) {
                              selected.add(member.nodeId.hex);
                            } else {
                              selected.remove(member.nodeId.hex);
                            }
                          }),
                    secondary: Icon(
                      member.role.rank >= GroupRole.admin.rank
                          ? Icons.shield_outlined
                          : Icons.person_outline,
                    ),
                    title: Text(member.nodeId.short),
                    subtitle: Text(member.role.name),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(AppL10n.of(context).actionCancel),
            ),
            if (canManage)
              FilledButton(
                key: const ValueKey('space-channel-members-save'),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(Set<String>.from(selected)),
                child: Text(AppL10n.of(context).actionSave),
              ),
          ],
        ),
      ),
    );
    if (saved == null) return null;
    return service.setChannelMembers(
      spaceId,
      channel.channelId,
      state.members.values
          .where((member) => saved.contains(member.nodeId.hex))
          .map((member) => member.nodeId),
    );
  }

  Future<void> _manageChannel(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    SpaceChannel channel,
    List<SpaceChannel> channels, {
    required bool canManageRetention,
  }) async {
    final l = AppL10n.of(context);
    final action = await showModalBottomSheet<_SpaceChannelAction>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.spaceChannelEdit),
              onTap: () => Navigator.of(sheet).pop(_SpaceChannelAction.edit),
            ),
            if (channel.access != SpaceChannelAccess.space)
              ListTile(
                key: const ValueKey('space-channel-members-action'),
                leading: const Icon(Icons.group_outlined),
                title: Text(l.spaceMembersTooltip),
                onTap: () =>
                    Navigator.of(sheet).pop(_SpaceChannelAction.members),
              ),
            if (channel.kind == SpaceChannelKind.text && canManageRetention)
              ListTile(
                key: const ValueKey('space-channel-retention-action'),
                leading: const Icon(Icons.history_toggle_off),
                title: Text(l.spaceRetentionTitle),
                onTap: () =>
                    Navigator.of(sheet).pop(_SpaceChannelAction.retention),
              ),
            if (channel.kind == SpaceChannelKind.text &&
                !channel.archived &&
                !channel.isDefault)
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: Text(l.spaceChannelMakeDefault),
                onTap: () =>
                    Navigator.of(sheet).pop(_SpaceChannelAction.makeDefault),
              ),
            ListTile(
              leading: Icon(
                channel.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              title: Text(
                channel.archived
                    ? l.spaceChannelRestore
                    : l.spaceChannelArchive,
              ),
              onTap: () => Navigator.of(sheet).pop(
                channel.archived
                    ? _SpaceChannelAction.restore
                    : _SpaceChannelAction.archive,
              ),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    var applied = false;
    switch (action) {
      case _SpaceChannelAction.retention:
        final saved = await _pickChannelRetention(
          context,
          service,
          spaceId,
          channel.channelId,
        );
        if (saved == null) return;
        applied = saved;
      case _SpaceChannelAction.members:
        final saved = await _manageProtectedChannelMembers(
          context,
          service,
          spaceId,
          channel,
        );
        if (saved == null) return;
        applied = saved;
      case _SpaceChannelAction.edit:
        final draft = await _showChannelEditor(
          context,
          channels: channels,
          current: channel,
        );
        if (draft == null || !context.mounted) return;
        final moved = draft.categoryId != channel.categoryId;
        applied = await service.updateChannel(
          spaceId,
          channel.copyWith(
            name: draft.name,
            description: draft.description,
            categoryId: draft.categoryId,
            clearCategory: draft.categoryId == null,
            position: moved
                ? nextSpaceChannelPosition(
                    channels,
                    categoryId: draft.categoryId,
                  )
                : channel.position,
            history: draft.history,
            historySinceMs: draft.historySinceMs,
            clearHistorySince: draft.history != SpaceChannelHistory.since,
          ),
        );
      case _SpaceChannelAction.makeDefault:
        applied = await service.setDefaultChannel(spaceId, channel.channelId);
      case _SpaceChannelAction.archive:
        applied = await service.setChannelArchived(
          spaceId,
          channel.channelId,
          true,
        );
      case _SpaceChannelAction.restore:
        applied = await service.setChannelArchived(
          spaceId,
          channel.channelId,
          false,
        );
    }
    if (!applied && context.mounted) {
      final hasActiveChildren =
          channel.kind == SpaceChannelKind.category &&
          channels.any(
            (candidate) =>
                candidate.categoryId == channel.channelId &&
                !candidate.archived,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasActiveChildren
                ? l.spaceChannelArchiveCategoryBlocked
                : l.spaceOperationFailed,
          ),
        ),
      );
    }
  }

  Future<bool?> _pickChannelRetention(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    NodeId channelId,
  ) async {
    final l = AppL10n.of(context);
    final history = await service.spaceRetentionHistoryOf(spaceId);
    SpaceRetentionPolicy current = SpaceRetentionPolicy(
      mode: SpaceRetentionMode.inherit,
      channelId: channelId,
    );
    for (final revision in history) {
      if (revision.policy.channelId == channelId) current = revision.policy;
    }
    if (!context.mounted) return null;
    final choices = <(String, SpaceRetentionMode, int?)>[
      (l.spaceRetentionGlobal, SpaceRetentionMode.inherit, null),
      (l.retentionUnlimited, SpaceRetentionMode.keepForever, null),
      (l.retention7, SpaceRetentionMode.deleteAfter, 7),
      (l.retention30, SpaceRetentionMode.deleteAfter, 30),
      (l.retention90, SpaceRetentionMode.deleteAfter, 90),
      (l.retention365, SpaceRetentionMode.deleteAfter, 365),
    ];
    var selectedMode = current.mode;
    var selectedDays = current.mode == SpaceRetentionMode.deleteAfter
        ? current.retentionMs! ~/ const Duration(days: 1).inMilliseconds
        : null;
    var selectedMediaOnly = current.mediaOnly;
    final picked = await showDialog<SpaceRetentionPolicy>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.spaceRetentionTitle),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final choice in choices)
                    ListTile(
                      key: ValueKey(
                        'space-channel-retention-${choice.$2.name}-${choice.$3}',
                      ),
                      leading: Icon(
                        selectedMode == choice.$2 &&
                                (choice.$2 != SpaceRetentionMode.deleteAfter ||
                                    selectedDays == choice.$3)
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                      ),
                      title: Text(choice.$1),
                      onTap: () => setDialogState(() {
                        selectedMode = choice.$2;
                        selectedDays = choice.$3;
                        if (selectedMode != SpaceRetentionMode.deleteAfter) {
                          selectedMediaOnly = false;
                        }
                      }),
                    ),
                  const Divider(),
                  SwitchListTile(
                    key: const ValueKey('space-channel-retention-media-only'),
                    value: selectedMediaOnly,
                    onChanged: selectedMode == SpaceRetentionMode.deleteAfter
                        ? (value) =>
                              setDialogState(() => selectedMediaOnly = value)
                        : null,
                    title: Text(l.spaceRetentionMediaOnly),
                    subtitle: Text(l.spaceRetentionMediaOnlyHint),
                    secondary: const Icon(Icons.perm_media_outlined),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('space-channel-retention-save'),
              onPressed: () => Navigator.of(dialog).pop(
                SpaceRetentionPolicy(
                  mode: selectedMode,
                  channelId: channelId,
                  retentionMs: selectedDays == null
                      ? null
                      : Duration(days: selectedDays!).inMilliseconds,
                  mediaOnly: selectedMediaOnly,
                ),
              ),
              child: Text(l.actionSave),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return null;
    return service.setSpaceRetentionPolicy(spaceId, picked);
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
    final contacts = (ref.read(conversationsProvider).value ?? const [])
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
          service.channelsOf(spaceId, includeArchived: true),
          service.spaceRecommendationCampaigns(spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          final channels = orderSpaceChannelsForDisplay(
            snapshot.data![1] as List<SpaceChannel>,
          );
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
          final acl = SpaceAcl(state);
          final canCreateChannel = acl.allowsAnyScope(
            service.selfId,
            SpacePermission.manageChannels,
          );
          final archived = state.isArchived;
          return Scaffold(
            appBar: AppBar(
              title: Text(state.name),
              actions: [
                if (SpaceAcl(state).allows(
                      service.selfId,
                      SpacePermission.distributeContent,
                    ) &&
                    state.recommendationsEnabled &&
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
            floatingActionButton: canCreateChannel
                ? FloatingActionButton(
                    heroTag: 'xveil-space-channel-create-$spaceIdHex',
                    tooltip: l.spaceChannelCreateTitle,
                    onPressed: () =>
                        _createChannel(context, ref, spaceId, channels),
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
                            final canManageChannel = acl.allows(
                              service.selfId,
                              SpacePermission.manageChannels,
                              channelId: channel.channelId,
                              categoryId:
                                  channel.kind == SpaceChannelKind.category
                                  ? channel.channelId
                                  : channel.categoryId,
                            );
                            final canManageChannelRetention = acl.allows(
                              service.selfId,
                              SpacePermission.manageStorage,
                              channelId: channel.channelId,
                              categoryId:
                                  channel.kind == SpaceChannelKind.category
                                  ? channel.channelId
                                  : channel.categoryId,
                            );
                            final isCategory =
                                channel.kind == SpaceChannelKind.category;
                            final icon = switch (channel.kind) {
                              SpaceChannelKind.text => Icons.tag,
                              SpaceChannelKind.voice =>
                                Icons.volume_up_outlined,
                              SpaceChannelKind.category =>
                                Icons.folder_outlined,
                            };
                            final subtitle = [
                              if (channel.archived) l.spaceChannelArchived,
                              if (channel.description.isNotEmpty)
                                channel.description,
                              if (channel.access != SpaceChannelAccess.space)
                                channel.access == SpaceChannelAccess.secret
                                    ? l.spaceChannelAccessSecret
                                    : l.spaceChannelAccessRestricted,
                            ];
                            return ListTile(
                              key: ValueKey(
                                'space-channel-${channel.channelId.hex}',
                              ),
                              contentPadding: EdgeInsets.only(
                                left: channel.categoryId == null ? 16 : 40,
                                right: 16,
                              ),
                              leading: Icon(
                                channel.archived
                                    ? Icons.archive_outlined
                                    : icon,
                              ),
                              title: Row(
                                children: [
                                  Expanded(child: Text(channel.name)),
                                  if (channel.isDefault)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Icon(
                                        Icons.home_outlined,
                                        size: 18,
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: subtitle.isEmpty
                                  ? null
                                  : Text(
                                      subtitle.join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: canManageChannel
                                  ? IconButton(
                                      key: ValueKey(
                                        'space-channel-manage-'
                                        '${channel.channelId.hex}',
                                      ),
                                      tooltip: l.spaceChannelManage,
                                      onPressed: () => _manageChannel(
                                        context,
                                        service,
                                        spaceId,
                                        channel,
                                        channels,
                                        canManageRetention:
                                            canManageChannelRetention,
                                      ),
                                      icon: const Icon(Icons.more_vert),
                                    )
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
                                      channel.archived ||
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
                              onLongPress: canManageChannel
                                  ? () => _manageChannel(
                                      context,
                                      service,
                                      spaceId,
                                      channel,
                                      channels,
                                      canManageRetention:
                                          canManageChannelRetention,
                                    )
                                  : null,
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

enum _SpaceChannelAction {
  members,
  retention,
  edit,
  makeDefault,
  archive,
  restore,
}

class _SpaceChannelDraft {
  const _SpaceChannelDraft({
    required this.name,
    required this.description,
    required this.kind,
    required this.access,
    required this.categoryId,
    required this.history,
    required this.historySinceMs,
    required this.members,
  });

  final String name;
  final String description;
  final SpaceChannelKind kind;
  final SpaceChannelAccess access;
  final NodeId? categoryId;
  final SpaceChannelHistory history;
  final int? historySinceMs;
  final List<NodeId> members;
}
