import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text(l.navFeed)),
      body: StreamBuilder<int>(
        stream: service.changes.stream,
        builder: (context, _) => FutureBuilder<List<SpaceFeedItem>>(
          future: service.spaceFeed(limit: 100),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.dynamic_feed_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(l.feedEmpty),
                    const SizedBox(height: 4),
                    Text(
                      l.feedEmptyHint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }
            final spaces = {for (final item in items) item.spaceId};
            WidgetsBinding.instance.addPostFrameCallback((_) {
              for (final spaceId in spaces) {
                unawaited(service.markSpaceFeedSeen(spaceId));
              }
            });
            return RefreshIndicator(
              onRefresh: () async {
                await service.nudgeGroupSyncAll();
              },
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _PostCard(
                    item: item,
                    onTap: () =>
                        context.push('/space/${item.spaceId.hex}/posts'),
                    onReact: (emoji) => service.reactToSpacePost(
                      item.spaceId,
                      item.post.postId,
                      emoji,
                    ),
                    selfId: service.selfId,
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.item,
    required this.onTap,
    required this.onReact,
    required this.selfId,
  });

  final SpaceFeedItem item;
  final VoidCallback onTap;
  final Future<bool> Function(String emoji) onReact;
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
                ],
              ),
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
