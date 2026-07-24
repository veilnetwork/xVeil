import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ids.dart';
import '../../data/transport/wire_envelope.dart' show isServiceEchoBody;
import '../../domain/chat.dart';
import '../../domain/group_message.dart';
import '../../domain/space_channel.dart';
import '../../domain/space_post.dart';
import '../../domain/space_public_discussion.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/mention_identity.dart';
import '../../state/messaging.dart';
import '../../state/providers.dart';
import 'message_markdown.dart';
import 'message_mentions.dart';

enum MentionSourceKind { direct, group, spaceChannel, spacePost, spaceComment }

class MentionInboxEntry {
  const MentionInboxEntry({
    required this.id,
    required this.kind,
    required this.author,
    required this.contextName,
    required this.body,
    required this.timestampMs,
    required this.route,
  });

  final String id;
  final MentionSourceKind kind;
  final NodeId author;
  final String contextName;
  final String body;
  final int timestampMs;
  final String route;
}

List<MentionInboxEntry> sortMentionInboxEntriesNewestFirst(
  Iterable<MentionInboxEntry> entries,
) {
  final sorted = entries.toList();
  sorted.sort((left, right) {
    final time = right.timestampMs.compareTo(left.timestampMs);
    return time != 0 ? time : left.id.compareTo(right.id);
  });
  return List.unmodifiable(sorted);
}

MentionInboxEntry? publicSpaceCommentMentionInboxEntry({
  required NodeId self,
  required NodeId spaceId,
  required String spaceName,
  required SpacePublicCommentView comment,
}) {
  if (comment.author == self || !messageMentionsNode(comment.body, self)) {
    return null;
  }
  return MentionInboxEntry(
    id: 'public-space-comment:${spaceId.hex}:${comment.ref}',
    kind: MentionSourceKind.spaceComment,
    author: comment.author,
    contextName: spaceName,
    body: comment.body,
    timestampMs: comment.createdAtMs,
    route:
        '/space/${spaceId.hex}/public-comments?post=${Uri.encodeQueryComponent(comment.root.postId)}&comment=${Uri.encodeQueryComponent(comment.ref)}',
  );
}

MentionInboxEntry? publicSpacePostMentionInboxEntry({
  required NodeId self,
  required NodeId spaceId,
  required String spaceName,
  required SpacePostView post,
}) {
  final postText = [
    if (post.title.trim().isNotEmpty) post.title,
    if (post.body.trim().isNotEmpty) post.body,
  ].join('\n');
  if (post.author == self || !messageMentionsNode(postText, self)) {
    return null;
  }
  return MentionInboxEntry(
    id: 'public-space-post:${spaceId.hex}:${post.postId}',
    kind: MentionSourceKind.spacePost,
    author: post.author,
    contextName: spaceName,
    body: postText,
    timestampMs: post.publishedAtMs,
    route:
        '/space/${spaceId.hex}/public-posts?post=${Uri.encodeQueryComponent(post.postId)}',
  );
}

final mentionInboxProvider = FutureProvider.autoDispose<List<MentionInboxEntry>>((
  ref,
) async {
  final self = ref.watch(appControllerProvider).identity?.nodeId;
  if (self == null) return const [];
  final conversations =
      ref.watch(conversationsProvider).value ?? const <Conversation>[];
  final groups = ref.watch(groupListProvider).value ?? const <GroupListEntry>[];
  final spaces = ref.watch(spaceListProvider).value ?? const <GroupListEntry>[];
  final publicSubscriptions =
      ref.watch(publicSpaceSubscriptionListProvider).value ??
      const <SpacePublicSubscriptionView>[];
  final storage = ref.watch(storageProvider);
  final service = ref.watch(groupServiceProvider);
  final entries = <MentionInboxEntry>[];
  final blockedAuthors = <String, Future<bool>>{};
  Future<bool> isBlocked(NodeId author) {
    if (author == self) return Future<bool>.value(false);
    return blockedAuthors.putIfAbsent(author.hex, () async {
      try {
        return (await storage.getContact(author))?.status ==
            ContactStatus.blocked;
      } catch (_) {
        // A relationship block is an identity-local privacy boundary. If its
        // encrypted status cannot be read, do not flash the author's old
        // mentions back into the aggregate inbox.
        return true;
      }
    });
  }

  for (final conversation in conversations) {
    if (await isBlocked(conversation.peer.nodeId)) continue;
    final messages = await storage.loadMessages(conversation.id);
    for (final message in messages) {
      if (message.direction != MessageDirection.incoming ||
          isServiceEchoBody(message.body) ||
          !messageMentionsNode(message.body, self)) {
        continue;
      }
      entries.add(
        MentionInboxEntry(
          id: 'direct:${conversation.id}:${message.id}',
          kind: MentionSourceKind.direct,
          author: conversation.peer.nodeId,
          contextName: conversation.peer.label,
          body: message.body,
          timestampMs: message.timestamp.millisecondsSinceEpoch,
          route:
              '/chat/${conversation.id}?msg=${Uri.encodeQueryComponent(message.id)}',
        ),
      );
    }
  }

  if (service != null) {
    for (final group in groups) {
      final messages = await service.messagesOf(group.groupId);
      for (final message in messages) {
        if (message.author == self ||
            await isBlocked(message.author) ||
            !messageMentionsNode(message.body, self)) {
          continue;
        }
        entries.add(
          MentionInboxEntry(
            id: 'group:${group.groupId.hex}:${message.ref}',
            kind: MentionSourceKind.group,
            author: message.author,
            contextName: group.name,
            body: message.body,
            timestampMs: message.createdAtMs,
            route:
                '/group/${group.groupId.hex}?msg=${Uri.encodeQueryComponent(message.ref)}',
          ),
        );
      }
    }

    for (final space in spaces) {
      final messagesFuture = service.messagesOf(space.groupId);
      final discussionFuture = service.spacePostsAndCommentsOf(space.groupId);
      final messages = await messagesFuture;
      for (final message in messages) {
        if (message.author == self ||
            await isBlocked(message.author) ||
            !messageMentionsNode(message.body, self)) {
          continue;
        }
        final channelId =
            message.channelId ?? defaultSpaceChannelId(space.groupId);
        entries.add(
          MentionInboxEntry(
            id: 'space-message:${space.groupId.hex}:${message.ref}',
            kind: MentionSourceKind.spaceChannel,
            author: message.author,
            contextName: space.name,
            body: message.body,
            timestampMs: message.createdAtMs,
            route:
                '/space/${space.groupId.hex}/channel/${channelId.hex}?msg=${Uri.encodeQueryComponent(message.ref)}',
          ),
        );
      }

      final discussion = await discussionFuture;
      for (final post in discussion.posts) {
        final postText = [
          if (post.title.trim().isNotEmpty) post.title,
          if (post.body.trim().isNotEmpty) post.body,
        ].join('\n');
        if (post.author != self &&
            !await isBlocked(post.author) &&
            messageMentionsNode(postText, self)) {
          entries.add(
            MentionInboxEntry(
              id: 'space-post:${space.groupId.hex}:${post.postId}',
              kind: MentionSourceKind.spacePost,
              author: post.author,
              contextName: space.name,
              body: postText,
              timestampMs: post.publishedAtMs,
              route:
                  '/space/${space.groupId.hex}/comments?post=${Uri.encodeQueryComponent(post.postId)}',
            ),
          );
        }
        final comments =
            discussion.commentsByPost[post.postId] ??
            const <SpacePostCommentView>[];
        for (final comment in comments) {
          if (comment.author == self ||
              await isBlocked(comment.author) ||
              !messageMentionsNode(comment.body, self)) {
            continue;
          }
          entries.add(
            MentionInboxEntry(
              id: 'space-comment:${space.groupId.hex}:${comment.ref}',
              kind: MentionSourceKind.spaceComment,
              author: comment.author,
              contextName: space.name,
              body: comment.body,
              timestampMs: comment.createdAtMs,
              route:
                  '/space/${space.groupId.hex}/comments?post=${Uri.encodeQueryComponent(post.postId)}&comment=${Uri.encodeQueryComponent(comment.ref)}',
            ),
          );
        }
      }
    }

    for (final public in publicSubscriptions) {
      for (final post in public.feed.posts) {
        if (!await isBlocked(post.author)) {
          final entry = publicSpacePostMentionInboxEntry(
            self: self,
            spaceId: public.descriptor.spaceId,
            spaceName: public.descriptor.name,
            post: post,
          );
          if (entry != null) entries.add(entry);
        }
        final comments = await service.publicSpacePostComments(
          public.descriptor.spaceId,
          post.postId,
        );
        for (final comment in comments) {
          if (await isBlocked(comment.author)) continue;
          final entry = publicSpaceCommentMentionInboxEntry(
            self: self,
            spaceId: public.descriptor.spaceId,
            spaceName: public.descriptor.name,
            comment: comment,
          );
          if (entry != null) entries.add(entry);
        }
      }
    }
  }

  return sortMentionInboxEntriesNewestFirst(entries);
});

class MentionsScreen extends ConsumerWidget {
  const MentionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final mentions = ref.watch(mentionInboxProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.mentionsTitle)),
      body: mentions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(child: Text(l.mentionsLoadFailed)),
        data: (entries) => entries.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.alternate_email, size: 44),
                      const SizedBox(height: 12),
                      Text(l.mentionsEmpty),
                      const SizedBox(height: 6),
                      Text(l.mentionsEmptyHint, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                key: const ValueKey('mentions-list'),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _MentionTile(
                  entry: entries[index],
                  onTap: () => context.push(entries[index].route),
                ),
              ),
      ),
    );
  }
}

class _MentionTile extends ConsumerWidget {
  const _MentionTile({required this.entry, required this.onTap});

  final MentionInboxEntry entry;
  final VoidCallback onTap;

  IconData get _icon => switch (entry.kind) {
    MentionSourceKind.direct => Icons.person_outline,
    MentionSourceKind.group => Icons.group_outlined,
    MentionSourceKind.spaceChannel => Icons.tag,
    MentionSourceKind.spacePost => Icons.article_outlined,
    MentionSourceKind.spaceComment => Icons.forum_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(
      mentionIdentityProvider(MentionIdentityKey(entry.author.hex)),
    );
    final author = identity.value?.label ?? entry.author.short;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final time = DateFormat.yMMMd(
      locale,
    ).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(entry.timestampMs));
    return ListTile(
      key: ValueKey('mention-${entry.id}'),
      leading: CircleAvatar(child: Icon(_icon, size: 20)),
      title: Text('$author · ${entry.contextName}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          FormattedText(
            entry.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(time, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}
