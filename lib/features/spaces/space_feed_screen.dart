import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../home/home_section_scaffold.dart';
import 'space_post_actions.dart';
import 'space_post_body.dart';
import 'space_post_media.dart';
import 'space_post_reactions.dart';

class SpaceFeedScreen extends ConsumerStatefulWidget {
  const SpaceFeedScreen({super.key});

  @override
  ConsumerState<SpaceFeedScreen> createState() => _SpaceFeedScreenState();
}

class _SpaceFeedScreenState extends ConsumerState<SpaceFeedScreen> {
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

  bool _matches(SpaceFeedItem item) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return item.spaceName.toLowerCase().contains(query) ||
        item.spaceId.hex.contains(query) ||
        item.post.title.toLowerCase().contains(query) ||
        item.post.body.toLowerCase().contains(query) ||
        item.post.author.hex.contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final availableById = <String, ({NodeId id, String name})>{
      for (final space
          in ref.watch(spaceListProvider).valueOrNull ??
              const <GroupListEntry>[])
        space.groupId.hex: (id: space.groupId, name: space.name),
      for (final public
          in ref.watch(publicSpaceSubscriptionListProvider).valueOrNull ??
              const <SpacePublicSubscriptionView>[])
        public.descriptor.spaceId.hex: (
          id: public.descriptor.spaceId,
          name: public.descriptor.name,
        ),
    };
    final availableSpaces = availableById.values.toList(growable: false)
      ..sort((left, right) => left.name.compareTo(right.name));
    if (service == null) {
      return HomeSectionScaffold(
        title: l.navFeed,
        searching: _searching,
        searchController: _searchController,
        searchHint: l.searchHint,
        onSearchStart: _startSearch,
        onSearchClose: _closeSearch,
        onSearchChanged: (value) => setState(() => _query = value),
        contextActions: [
          IconButton(
            key: const ValueKey('space-feed-mentions-open'),
            icon: const Icon(Icons.alternate_email),
            tooltip: l.mentionsOpenTooltip,
            onPressed: () => context.push('/mentions'),
          ),
          IconButton(
            key: const ValueKey('space-feed-type-filter'),
            tooltip: l.feedFilterTitle,
            onPressed: null,
            icon: const Icon(Icons.filter_alt_outlined),
          ),
        ],
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    Future<void> hidePost(SpaceFeedItem item) async {
      try {
        await service.setSpaceFeedPostHidden(
          item.spaceId,
          item.post.postId,
          true,
        );
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.feedPostHideFailed)));
        }
        return;
      }
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.feedPostHidden),
          action: SnackBarAction(
            label: l.feedPostUndo,
            onPressed: () {
              unawaited(() async {
                try {
                  await service.setSpaceFeedPostHidden(
                    item.spaceId,
                    item.post.postId,
                    false,
                  );
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.feedPostHideFailed)),
                    );
                  }
                }
              }());
            },
          ),
        ),
      );
    }

    Future<void> chooseFilter(SpaceFeedFilter current) async {
      final selected = await showModalBottomSheet<SpaceFeedFilter>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _SpaceFeedFilterSheet(
          initial: current,
          availableSpaces: availableSpaces,
        ),
      );
      if (selected == null) return;
      try {
        await service.setSpaceFeedFilter(selected);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.feedFilterUpdateFailed)));
        }
      }
    }

    return StreamBuilder<int>(
      stream: service.changes.stream,
      initialData: service.changes.value,
      builder: (context, _) =>
          FutureBuilder<
            ({
              SpaceFeedFilter filter,
              List<SpaceFeedItem> pinnedItems,
              List<SpaceFeedItem> items,
            })
          >(
            key: ValueKey(('space-feed', service.feedAccessChanges.value)),
            future: () async {
              final filter = await service.spaceFeedFilter();
              final pages = await Future.wait([
                service.spaceFeed(limit: 100, filter: filter, pinned: true),
                service.spaceFeed(limit: 100, filter: filter, pinned: false),
              ]);
              return (filter: filter, pinnedItems: pages[0], items: pages[1]);
            }(),
            builder: (context, snapshot) {
              final filter = snapshot.data?.filter;
              final filtering = filter != null && !filter.isDefault;
              return HomeSectionScaffold(
                title: l.navFeed,
                searching: _searching,
                searchController: _searchController,
                searchHint: l.searchHint,
                onSearchStart: _startSearch,
                onSearchClose: _closeSearch,
                onSearchChanged: (value) => setState(() => _query = value),
                contextActions: [
                  IconButton(
                    key: const ValueKey('space-feed-mentions-open'),
                    icon: const Icon(Icons.alternate_email),
                    tooltip: l.mentionsOpenTooltip,
                    onPressed: () => context.push('/mentions'),
                  ),
                  IconButton(
                    key: const ValueKey('space-feed-type-filter'),
                    tooltip: l.feedFilterTitle,
                    onPressed: filter == null
                        ? null
                        : () => chooseFilter(filter),
                    icon: Badge(
                      isLabelVisible: filtering,
                      label: Text('${filter?.activeDimensionCount ?? 0}'),
                      child: Icon(
                        filtering
                            ? Icons.filter_alt
                            : Icons.filter_alt_outlined,
                      ),
                    ),
                  ),
                ],
                body: Builder(
                  builder: (context) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final pinnedItems = snapshot.data!.pinnedItems
                        .where(_matches)
                        .toList(growable: false);
                    final items = snapshot.data!.items
                        .where(_matches)
                        .toList(growable: false);
                    if (pinnedItems.isEmpty && items.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.dynamic_feed_outlined,
                              size: 48,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(l.feedEmpty),
                            const SizedBox(height: 4),
                            Text(
                              _query.trim().isNotEmpty
                                  ? l.searchNoResults
                                  : filtering
                                  ? l.feedFilterEmptyHint
                                  : l.feedEmptyHint,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    }
                    final spaces = {
                      for (final item in pinnedItems) item.spaceId,
                      for (final item in items) item.spaceId,
                    };
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      for (final spaceId in spaces) {
                        unawaited(service.markSpaceFeedSeen(spaceId));
                      }
                    });
                    return RefreshIndicator(
                      onRefresh: () async {
                        await service.nudgeGroupSyncAll();
                      },
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          if (pinnedItems.isNotEmpty) ...[
                            _FeedSectionHeader(
                              icon: Icons.push_pin,
                              label: l.feedPinnedTitle,
                            ),
                            for (final item in pinnedItems) ...[
                              _PostCard(
                                item: item,
                                onTap: () => context.push(
                                  item.publicOnly
                                      ? '/space/${item.spaceId.hex}/public-posts?post=${Uri.encodeQueryComponent(item.post.postId)}'
                                      : '/space/${item.spaceId.hex}/posts',
                                ),
                                onReact: item.publicOnly
                                    ? null
                                    : (emoji) => service.reactToSpacePost(
                                        item.spaceId,
                                        item.post.postId,
                                        emoji,
                                      ),
                                onComments: item.publicOnly
                                    ? null
                                    : () => context.push(
                                        '/space/${item.spaceId.hex}/comments?post='
                                        '${Uri.encodeQueryComponent(item.post.postId)}',
                                      ),
                                onHide: () => hidePost(item),
                                onDelete: item.canDeletePost
                                    ? () async {
                                        await confirmAndDeleteOwnSpacePost(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                        );
                                      }
                                    : null,
                                onModerateDelete: item.canModeratePost
                                    ? () async {
                                        await promptAndModerateDeleteSpacePost(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                        );
                                      }
                                    : null,
                                onSetPinned: item.canManagePosts
                                    ? (pinned) async {
                                        await updateSpacePostPinned(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                          pinned,
                                        );
                                      }
                                    : null,
                                selfId: service.selfId,
                              ),
                              const SizedBox(height: 4),
                            ],
                          ],
                          if (items.isNotEmpty) ...[
                            if (pinnedItems.isNotEmpty)
                              _FeedSectionHeader(
                                icon: Icons.schedule,
                                label: l.feedRecentTitle,
                              ),
                            for (final item in items) ...[
                              _PostCard(
                                item: item,
                                onTap: () => context.push(
                                  item.publicOnly
                                      ? '/space/${item.spaceId.hex}/public-posts?post=${Uri.encodeQueryComponent(item.post.postId)}'
                                      : '/space/${item.spaceId.hex}/posts',
                                ),
                                onReact: item.publicOnly
                                    ? null
                                    : (emoji) => service.reactToSpacePost(
                                        item.spaceId,
                                        item.post.postId,
                                        emoji,
                                      ),
                                onComments: item.publicOnly
                                    ? null
                                    : () => context.push(
                                        '/space/${item.spaceId.hex}/comments?post='
                                        '${Uri.encodeQueryComponent(item.post.postId)}',
                                      ),
                                onHide: () => hidePost(item),
                                onDelete: item.canDeletePost
                                    ? () async {
                                        await confirmAndDeleteOwnSpacePost(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                        );
                                      }
                                    : null,
                                onModerateDelete: item.canModeratePost
                                    ? () async {
                                        await promptAndModerateDeleteSpacePost(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                        );
                                      }
                                    : null,
                                onSetPinned: item.canManagePosts
                                    ? (pinned) async {
                                        await updateSpacePostPinned(
                                          context,
                                          service,
                                          item.spaceId,
                                          item.post,
                                          pinned,
                                        );
                                      }
                                    : null,
                                selfId: service.selfId,
                              ),
                              const SizedBox(height: 4),
                            ],
                          ],
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
    );
  }
}

class _FeedSectionHeader extends StatelessWidget {
  const _FeedSectionHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label, style: Theme.of(context).textTheme.titleSmall),
      ],
    ),
  );
}

class _SpaceFeedFilterSheet extends StatefulWidget {
  const _SpaceFeedFilterSheet({
    required this.initial,
    required this.availableSpaces,
  });

  final SpaceFeedFilter initial;
  final List<({NodeId id, String name})> availableSpaces;

  @override
  State<_SpaceFeedFilterSheet> createState() => _SpaceFeedFilterSheetState();
}

class _SpaceFeedFilterSheetState extends State<_SpaceFeedFilterSheet> {
  late final Set<SpacePostType> _types = widget.initial.types.toSet();
  late bool _mentionsOnly = widget.initial.mentionsOnly;
  late SpaceFeedTimePreset _timePreset = widget.initial.timePreset;
  late int? _customFromMs = widget.initial.customFromMs;
  late int? _customToMs = widget.initial.customToMs;
  late final Set<NodeId> _spaces = widget.initial.spaceIds.toSet();

  void _reset() => setState(() {
    _types
      ..clear()
      ..addAll(SpacePostType.values);
    _mentionsOnly = false;
    _timePreset = SpaceFeedTimePreset.all;
    _customFromMs = null;
    _customToMs = null;
    _spaces.clear();
  });

  Future<void> _selectTimePreset(SpaceFeedTimePreset preset) async {
    if (preset != SpaceFeedTimePreset.custom) {
      setState(() => _timePreset = preset);
      return;
    }
    final now = DateTime.now();
    final firstDate = DateTime(2000);
    final storedStart = _customFromMs == null
        ? now.subtract(const Duration(days: 7))
        : DateTime.fromMillisecondsSinceEpoch(_customFromMs!);
    final storedEnd = _customToMs == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(_customToMs!);
    final initialStart = storedStart.isBefore(firstDate)
        ? firstDate
        : storedStart.isAfter(now)
        ? now
        : storedStart;
    final initialEnd =
        storedEnd.isBefore(initialStart) || storedEnd.isAfter(now)
        ? now
        : storedEnd;
    final dates = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: DateUtils.dateOnly(initialStart),
        end: DateUtils.dateOnly(initialEnd),
      ),
    );
    if (dates == null || !mounted) return;
    final startTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialStart),
    );
    if (startTime == null || !mounted) return;
    final endTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialEnd),
    );
    if (endTime == null || !mounted) return;
    final start = DateTime(
      dates.start.year,
      dates.start.month,
      dates.start.day,
      startTime.hour,
      startTime.minute,
    );
    final end = DateTime(
      dates.end.year,
      dates.end.month,
      dates.end.day,
      endTime.hour,
      endTime.minute,
      59,
      999,
    );
    if (end.isBefore(start)) return;
    setState(() {
      _timePreset = SpaceFeedTimePreset.custom;
      _customFromMs = start.millisecondsSinceEpoch;
      _customToMs = end.millisecondsSinceEpoch;
    });
  }

  String _dateTimeLabel(BuildContext context, int milliseconds) {
    final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final material = MaterialLocalizations.of(context);
    return '${material.formatCompactDate(value)}, '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  void _toggleSpace(NodeId id, bool selected) {
    final all = {for (final space in widget.availableSpaces) space.id};
    setState(() {
      if (_spaces.isEmpty && !selected) {
        _spaces
          ..addAll(all)
          ..remove(id);
      } else if (selected) {
        _spaces.add(id);
      } else {
        _spaces.remove(id);
      }
      if (_spaces.length == all.length && _spaces.containsAll(all)) {
        _spaces.clear();
      }
    });
  }

  SpaceFeedFilter _result() => SpaceFeedFilter(
    types: _types,
    mentionsOnly: _mentionsOnly,
    timePreset: _timePreset,
    customFromMs: _customFromMs,
    customToMs: _customToMs,
    spaceIds: _spaces,
  );

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final customRange =
        _timePreset == SpaceFeedTimePreset.custom &&
            _customFromMs != null &&
            _customToMs != null
        ? '${_dateTimeLabel(context, _customFromMs!)} — '
              '${_dateTimeLabel(context, _customToMs!)}'
        : null;
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.feedFilterTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('space-feed-filter-all'),
                        onPressed: _reset,
                        child: Text(l.feedFilterAll),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('space-feed-filter-scroll'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          key: const ValueKey('space-feed-filter-mentions'),
                          value: _mentionsOnly,
                          secondary: const Icon(Icons.alternate_email),
                          title: Text(l.feedFilterMentionsOnly),
                          subtitle: Text(l.feedFilterMentionsOnlyHint),
                          onChanged: (value) =>
                              setState(() => _mentionsOnly = value),
                        ),
                        _FilterSectionTitle(label: l.feedFilterTypesTitle),
                        for (final type in SpacePostType.values)
                          CheckboxListTile(
                            key: ValueKey('space-feed-filter-${type.name}'),
                            value: _types.contains(type),
                            secondary: Icon(_postTypeIcon(type)),
                            title: Text(_postTypeLabel(l, type)),
                            onChanged: (checked) => setState(() {
                              if (checked ?? false) {
                                _types.add(type);
                              } else if (_types.length > 1) {
                                _types.remove(type);
                              }
                            }),
                          ),
                        _FilterSectionTitle(label: l.feedFilterTimeTitle),
                        RadioGroup<SpaceFeedTimePreset>(
                          groupValue: _timePreset,
                          onChanged: (value) {
                            if (value != null) {
                              unawaited(_selectTimePreset(value));
                            }
                          },
                          child: Column(
                            children: [
                              for (final preset in SpaceFeedTimePreset.values)
                                RadioListTile<SpaceFeedTimePreset>(
                                  key: ValueKey(
                                    'space-feed-filter-time-${preset.name}',
                                  ),
                                  value: preset,
                                  title: Text(_timePresetLabel(l, preset)),
                                  subtitle:
                                      preset == SpaceFeedTimePreset.custom &&
                                          customRange != null
                                      ? Text(customRange)
                                      : null,
                                ),
                            ],
                          ),
                        ),
                        if (widget.availableSpaces.isNotEmpty) ...[
                          _FilterSectionTitle(
                            label: l.feedFilterCommunitiesTitle,
                          ),
                          CheckboxListTile(
                            key: const ValueKey(
                              'space-feed-filter-community-all',
                            ),
                            value: _spaces.isEmpty,
                            secondary: const Icon(Icons.groups_outlined),
                            title: Text(l.feedFilterAllCommunities),
                            onChanged: (_) => setState(() => _spaces.clear()),
                          ),
                          for (final space in widget.availableSpaces)
                            CheckboxListTile(
                              key: ValueKey(
                                'space-feed-filter-community-${space.id.hex}',
                              ),
                              value:
                                  _spaces.isEmpty || _spaces.contains(space.id),
                              secondary: CircleAvatar(
                                radius: 14,
                                child: Text(
                                  space.name.isEmpty
                                      ? '#'
                                      : space.name.characters.first
                                            .toUpperCase(),
                                ),
                              ),
                              title: Text(space.name),
                              subtitle: Text(space.id.short),
                              onChanged: (checked) =>
                                  _toggleSpace(space.id, checked ?? false),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('space-feed-filter-apply'),
                      onPressed: () => Navigator.of(context).pop(_result()),
                      child: Text(l.feedFilterApply),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterSectionTitle extends StatelessWidget {
  const _FilterSectionTitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

String _timePresetLabel(AppL10n l, SpaceFeedTimePreset preset) =>
    switch (preset) {
      SpaceFeedTimePreset.all => l.feedFilterTimeAll,
      SpaceFeedTimePreset.lastHour => l.feedFilterTimeHour,
      SpaceFeedTimePreset.lastDay => l.feedFilterTimeDay,
      SpaceFeedTimePreset.lastWeek => l.feedFilterTimeWeek,
      SpaceFeedTimePreset.lastMonth => l.feedFilterTimeMonth,
      SpaceFeedTimePreset.custom => l.feedFilterTimeCustom,
    };

String _postTypeLabel(AppL10n l, SpacePostType type) => switch (type) {
  SpacePostType.post => l.spacePostTypePost,
  SpacePostType.article => l.spacePostTypeArticle,
  SpacePostType.video => l.spacePostTypeVideo,
  SpacePostType.shortVideo => l.spacePostTypeShortVideo,
  SpacePostType.audio => l.spacePostTypeAudio,
  SpacePostType.voiceMessage => l.spacePostTypeVoiceMessage,
};

IconData _postTypeIcon(SpacePostType type) => switch (type) {
  SpacePostType.post => Icons.campaign_outlined,
  SpacePostType.article => Icons.article_outlined,
  SpacePostType.video => Icons.video_library_outlined,
  SpacePostType.shortVideo => Icons.smart_display_outlined,
  SpacePostType.audio => Icons.headphones_outlined,
  SpacePostType.voiceMessage => Icons.mic_none_outlined,
};

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.item,
    required this.onTap,
    required this.onReact,
    required this.onComments,
    required this.onHide,
    required this.onDelete,
    required this.onModerateDelete,
    required this.onSetPinned,
    required this.selfId,
  });

  final SpaceFeedItem item;
  final VoidCallback onTap;
  final Future<bool> Function(String emoji)? onReact;
  final VoidCallback? onComments;
  final Future<void> Function() onHide;
  final Future<void> Function()? onDelete;
  final Future<void> Function()? onModerateDelete;
  final Future<void> Function(bool pinned)? onSetPinned;
  final NodeId selfId;

  @override
  Widget build(BuildContext context) {
    final post = item.post;
    final published = MaterialLocalizations.of(
      context,
    ).formatShortDate(DateTime.fromMillisecondsSinceEpoch(post.publishedAtMs));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    child: Text(
                      item.spaceName.isEmpty
                          ? '#'
                          : item.spaceName.characters.first.toUpperCase(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.spaceName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text(published, style: Theme.of(context).textTheme.bodySmall),
                  PopupMenuButton<_FeedPostAction>(
                    key: ValueKey('space-feed-post-menu-${post.postId}'),
                    onSelected: (action) {
                      switch (action) {
                        case _FeedPostAction.pin:
                          unawaited(onSetPinned!(true));
                        case _FeedPostAction.unpin:
                          unawaited(onSetPinned!(false));
                        case _FeedPostAction.delete:
                          unawaited(onDelete!());
                        case _FeedPostAction.moderateDelete:
                          unawaited(onModerateDelete!());
                        case _FeedPostAction.hide:
                          unawaited(onHide());
                      }
                    },
                    itemBuilder: (context) => [
                      if (onSetPinned != null)
                        PopupMenuItem(
                          value: post.pinned
                              ? _FeedPostAction.unpin
                              : _FeedPostAction.pin,
                          child: _FeedPostMenuLabel(
                            icon: Icons.push_pin_outlined,
                            label: post.pinned
                                ? AppL10n.of(context).spacePostUnpin
                                : AppL10n.of(context).spacePostPin,
                          ),
                        ),
                      if (onDelete != null)
                        PopupMenuItem(
                          value: _FeedPostAction.delete,
                          child: _FeedPostMenuLabel(
                            icon: Icons.delete_outline,
                            label: AppL10n.of(context).spacePostDelete,
                          ),
                        )
                      else if (onModerateDelete != null)
                        PopupMenuItem(
                          value: _FeedPostAction.moderateDelete,
                          child: _FeedPostMenuLabel(
                            icon: Icons.delete_forever_outlined,
                            label: AppL10n.of(
                              context,
                            ).spaceModerationDeletePost,
                          ),
                        ),
                      PopupMenuItem(
                        value: _FeedPostAction.hide,
                        child: _FeedPostMenuLabel(
                          icon: Icons.visibility_off_outlined,
                          label: AppL10n.of(context).feedPostHide,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (post.pinned) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.push_pin, size: 15),
                    const SizedBox(width: 4),
                    Text(
                      AppL10n.of(context).spacePostPinned,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ],
              if (post.title.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(post.title, style: Theme.of(context).textTheme.titleLarge),
              ],
              if (post.body.isNotEmpty) ...[
                const SizedBox(height: 8),
                SpacePostBody(post.body),
              ],
              SpacePostMediaList(
                spaceId: item.spaceId,
                post: post,
                compact: true,
                publicOnly: item.publicOnly,
              ),
              const SizedBox(height: 8),
              if (onReact != null)
                SpacePostReactionBar(
                  postId: post.postId,
                  reactions: item.reactions,
                  selfId: selfId,
                  onReact: onReact!,
                ),
              if (onComments != null)
                TextButton.icon(
                  key: ValueKey('space-feed-comments-${post.postId}'),
                  onPressed: onComments,
                  icon: const Icon(Icons.forum_outlined, size: 18),
                  label: Text(AppL10n.of(context).spacePostCommentsOpen),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FeedPostAction { pin, unpin, delete, moderateDelete, hide }

class _FeedPostMenuLabel extends StatelessWidget {
  const _FeedPostMenuLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );
}
