import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import 'space_post_reactions.dart';

class SpaceFeedScreen extends ConsumerWidget {
  const SpaceFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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

    Future<void> chooseTypes(Set<SpacePostType> current) async {
      final selected = await showModalBottomSheet<Set<SpacePostType>>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _PostTypeFilterSheet(initial: current),
      );
      if (selected == null) return;
      try {
        await service.setSpaceFeedTypeFilter(selected);
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
      builder: (context, _) =>
          FutureBuilder<
            ({
              Set<SpacePostType> types,
              List<SpaceFeedItem> pinnedItems,
              List<SpaceFeedItem> items,
            })
          >(
            future: () async {
              final types = await service.spaceFeedTypeFilter();
              final pages = await Future.wait([
                service.spaceFeed(limit: 100, types: types, pinned: true),
                service.spaceFeed(limit: 100, types: types, pinned: false),
              ]);
              return (types: types, pinnedItems: pages[0], items: pages[1]);
            }(),
            builder: (context, snapshot) {
              final selectedTypes = snapshot.data?.types;
              final filtering =
                  selectedTypes != null &&
                  selectedTypes.length != SpacePostType.values.length;
              return Scaffold(
                appBar: AppBar(
                  title: Text(l.navFeed),
                  actions: [
                    IconButton(
                      key: const ValueKey('space-feed-type-filter'),
                      tooltip: l.feedFilterTitle,
                      onPressed: selectedTypes == null
                          ? null
                          : () => chooseTypes(selectedTypes),
                      icon: Badge(
                        isLabelVisible: filtering,
                        label: Text('${selectedTypes?.length ?? 0}'),
                        child: Icon(
                          filtering
                              ? Icons.filter_alt
                              : Icons.filter_alt_outlined,
                        ),
                      ),
                    ),
                  ],
                ),
                body: Builder(
                  builder: (context) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final pinnedItems = snapshot.data!.pinnedItems;
                    final items = snapshot.data!.items;
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
                              filtering
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
                                  '/space/${item.spaceId.hex}/posts',
                                ),
                                onReact: (emoji) => service.reactToSpacePost(
                                  item.spaceId,
                                  item.post.postId,
                                  emoji,
                                ),
                                onHide: () => hidePost(item),
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
                                  '/space/${item.spaceId.hex}/posts',
                                ),
                                onReact: (emoji) => service.reactToSpacePost(
                                  item.spaceId,
                                  item.post.postId,
                                  emoji,
                                ),
                                onHide: () => hidePost(item),
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

class _PostTypeFilterSheet extends StatefulWidget {
  const _PostTypeFilterSheet({required this.initial});

  final Set<SpacePostType> initial;

  @override
  State<_PostTypeFilterSheet> createState() => _PostTypeFilterSheetState();
}

class _PostTypeFilterSheetState extends State<_PostTypeFilterSheet> {
  late final Set<SpacePostType> _selected = widget.initial.toSet();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.feedFilterTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('space-feed-filter-all'),
                      onPressed: () => setState(() {
                        _selected
                          ..clear()
                          ..addAll(SpacePostType.values);
                      }),
                      child: Text(l.feedFilterAll),
                    ),
                  ],
                ),
                for (final type in SpacePostType.values)
                  CheckboxListTile(
                    key: ValueKey('space-feed-filter-${type.name}'),
                    value: _selected.contains(type),
                    secondary: Icon(_postTypeIcon(type)),
                    title: Text(_postTypeLabel(l, type)),
                    onChanged: (checked) => setState(() {
                      if (checked ?? false) {
                        _selected.add(type);
                      } else if (_selected.length > 1) {
                        _selected.remove(type);
                      }
                    }),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('space-feed-filter-apply'),
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: Text(l.feedFilterApply),
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
    required this.onHide,
    required this.selfId,
  });

  final SpaceFeedItem item;
  final VoidCallback onTap;
  final Future<bool> Function(String emoji) onReact;
  final Future<void> Function() onHide;
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
                  PopupMenuButton<String>(
                    key: ValueKey('space-feed-post-menu-${post.postId}'),
                    tooltip: AppL10n.of(context).feedPostHide,
                    onSelected: (_) => unawaited(onHide()),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'hide',
                        child: Row(
                          children: [
                            const Icon(Icons.visibility_off_outlined),
                            const SizedBox(width: 12),
                            Text(AppL10n.of(context).feedPostHide),
                          ],
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
                Text(post.body),
              ],
              if (post.media.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.attach_file, size: 18),
                    const SizedBox(width: 4),
                    Text('${post.media.length}'),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              SpacePostReactionBar(
                postId: post.postId,
                reactions: item.reactions,
                selfId: selfId,
                onReact: onReact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
