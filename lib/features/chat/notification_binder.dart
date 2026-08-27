import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/log.dart';
import '../../domain/chat.dart';
import '../../domain/group_message.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_recommendation.dart';
import '../../domain/space_post.dart';
import '../../domain/space_public_discussion.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart';
import '../../state/mention_identity.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';
import 'attachment_preview.dart';
import 'message_mentions.dart';

/// Bridges the active messaging service's [MessagingService.incoming] stream to
/// OS notifications, applying the privacy + lifecycle policy. A widget (not a
/// bare provider) so it has a [BuildContext] for localized, preview-respecting
/// strings, and a [WidgetsBindingObserver] for the app's foreground/background
/// transitions. Re-subscribes when the active identity's service changes.
///
/// Lifecycle policy ([shouldAlertIncoming] / [shouldAlertOnMinimize]):
/// * FOREGROUND — never pop a notification (the message shows in-app; over the
///   open chat a popup would be pure noise). What arrived for OTHER chats
///   surfaces when you minimize.
/// * BACKGROUND — update one latest-message alert in real time (this only fires
///   at all when the node is kept alive in the background — see
///   BackgroundNodeController; otherwise the process is suspended and no
///   message is received here).
/// * ON MINIMIZE — select the newest unread conversation (except the one you
///   were just reading) and post one alert, avoiding a startup/replay storm.
/// * ON RESUME — clear the posted notifications (the unread is visible in-app).
///
/// All provider interaction is deferred to a post-frame callback + done via
/// [WidgetRef.listenManual] — NEVER during build or initState directly. Reading
/// `messagingServiceProvider` (which watches `activeIdentityProvider`) inline
/// would register a listener mid-build, so the controller's identity-activation
/// write during the unlock→home cascade tripped Riverpod's "modify a provider
/// while the widget tree was building" guard.
class NotificationBinder extends ConsumerStatefulWidget {
  const NotificationBinder({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<NotificationBinder> createState() => _NotificationBinderState();
}

class _NotificationBinderState extends ConsumerState<NotificationBinder>
    with WidgetsBindingObserver {
  StreamSubscription<IncomingNotice>? _sub;
  ProviderSubscription<MessagingService>? _serviceListener;
  StreamSubscription<({NodeId groupId, GroupMessage message})>? _groupSub;
  StreamSubscription<({NodeId spaceId, GroupMessage message})>?
  _spaceCommentSub;
  StreamSubscription<({NodeId spaceId, SpacePostView post})>? _spacePostSub;
  StreamSubscription<({NodeId spaceId, SpacePostView post})>?
  _publicSpacePostSub;
  StreamSubscription<({NodeId spaceId, SpacePublicCommentView comment})>?
  _publicSpaceCommentSub;
  ProviderSubscription<GroupService?>? _groupServiceListener;
  final Map<
    String,
    ({
      String convHex,
      String? name,
      String shortId,
      String preview,
      int timestampMs,
      bool allowReply,
      bool isMention,
    })
  >
  _pendingSpaceComments = {};
  int _notificationGeneration = 0;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
      // Null only at the very first frame — treat as foreground (suppress).
      WidgetsBinding.instance.lifecycleState == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer until after the first frame so the unlock→home provider cascade has
    // fully settled before we attach any listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(notificationServiceProvider).requestPermission());
      _subscribe(ref.read(messagingServiceProvider));
      // Re-subscribe when the active identity's service changes (manual listen,
      // NOT in build).
      _serviceListener = ref.listenManual<MessagingService>(
        messagingServiceProvider,
        (_, next) => _subscribe(next),
      );
      // The group service appears once the signer is ready (and can change on
      // identity switch) — same manual-listen pattern.
      _subscribeGroups(ref.read(groupServiceProvider));
      _groupServiceListener = ref.listenManual<GroupService?>(
        groupServiceProvider,
        (_, next) => _subscribeGroups(next),
      );
    });
  }

  void _subscribe(MessagingService service) {
    _sub?.cancel();
    _sub = service.incoming.listen(_onIncoming);
  }

  void _subscribeGroups(GroupService? service) {
    _groupSub?.cancel();
    _spaceCommentSub?.cancel();
    _spacePostSub?.cancel();
    _publicSpacePostSub?.cancel();
    _publicSpaceCommentSub?.cancel();
    _groupSub = service?.incoming.listen(_onGroupIncoming);
    _spaceCommentSub = service?.incomingComments.listen(
      _onSpaceCommentIncoming,
    );
    _spacePostSub = service?.incomingPosts.listen(_onSpacePostIncoming);
    _publicSpacePostSub = service?.incomingPublicPosts.listen(
      _onPublicSpacePostIncoming,
    );
    _publicSpaceCommentSub = service?.incomingPublicComments.listen(
      _onPublicSpaceCommentIncoming,
    );
  }

  /// A message just arrived. Alert in real time ONLY when backgrounded; a
  /// foreground app shows it in-app and surfaces the rest on minimize.
  Future<void> _onIncoming(IncomingNotice notice) async {
    if (!mounted) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    Contact? contact;
    try {
      contact = await ref.read(storageProvider).getContact(notice.from);
    } catch (_) {}
    if (!mounted || generation != _notificationGeneration) return;
    final self = ref.read(appControllerProvider).identity?.nodeId;
    final isMention = self != null && messageMentionsNode(notice.preview, self);
    final mode =
        contact?.notificationModeAt(DateTime.now()) ?? NotificationMuteMode.all;
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted: !notificationModeAllows(mode, isMention: isMention),
      foreground: _foreground,
    )) {
      return;
    }
    final mentionRoute = notice.messageId == null
        ? null
        : '/chat/${notice.from.hex}?msg=${Uri.encodeQueryComponent(notice.messageId!)}';
    await _show(
      convHex: isMention && mentionRoute != null
          ? notificationMentionPayload(mentionRoute)
          : notice.from.hex,
      name: contact?.name,
      shortId: notice.from.short,
      // A file notice's [preview] echoes the stored `📎 <name>` body, which
      // for voice/video notes/stickers is an opaque uuid container name —
      // derive the human kind label instead (display-only).
      preview: notice.isFile
          ? attachmentPreviewText(
              AppL10n.of(context),
              name: notice.fileName,
              duration: sidecarDuration(notice.sidecar),
            )
          : notice.preview,
      settings: settings,
      allowReply: !isMention,
      isMention: isMention,
    );
  }

  /// A group message just arrived (post-dedup, verified, not ours). Same
  /// lifecycle policy as 1:1: foreground shows in-app, background alerts.
  Future<void> _onGroupIncoming(
    ({NodeId groupId, GroupMessage message}) n,
  ) async {
    if (!mounted) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    var policy = const NotificationMutePolicy.all();
    GroupService? service;
    try {
      service = ref.read(groupServiceProvider);
      policy =
          await service?.groupNotificationPolicy(n.groupId) ??
          const NotificationMutePolicy.all();
    } catch (_) {}
    if (!mounted || generation != _notificationGeneration) return;
    final self =
        service?.selfId ?? ref.read(appControllerProvider).identity?.nodeId;
    final isMention = self != null && messageMentionsNode(n.message.body, self);
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted: !notificationModeAllows(
        policy.effectiveAt(DateTime.now()),
        isMention: isMention,
      ),
      foreground: _foreground,
    )) {
      return;
    }
    String? name;
    try {
      name = (await service?.stateOf(n.groupId))?.name;
    } catch (_) {}
    if (!mounted || generation != _notificationGeneration) return;
    await _show(
      convHex: isMention
          ? notificationMentionPayload(
              '/group/${n.groupId.hex}?msg=${Uri.encodeQueryComponent(n.message.ref)}',
            )
          : 'group:${n.groupId.hex}',
      name: (name != null && name.trim().isNotEmpty) ? name : null,
      shortId: n.groupId.short,
      preview: _groupPreview(AppL10n.of(context), n.message),
      settings: settings,
      allowReply: !isMention,
      isMention: isMention,
    );
  }

  /// Kind-labelled attachment preview (shared helper). Callers pass the
  /// localized strings they captured under a mounted guard.
  static String _groupPreview(AppL10n l, GroupMessage m) =>
      groupMessagePreviewText(l, m);

  /// A publication is a Space-native event, not a group message. Its local
  /// notification preference is independent from whether that Space appears
  /// in the combined Feed.
  Future<void> _onSpacePostIncoming(
    ({NodeId spaceId, SpacePostView post}) n,
  ) async {
    if (!mounted) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    var notificationsEnabled = false;
    var policy = const NotificationMutePolicy.all();
    String? name;
    GroupService? service;
    try {
      service = ref.read(groupServiceProvider);
      final subscription = await service?.spaceSubscription(n.spaceId);
      notificationsEnabled = subscription?.notificationsEnabled ?? false;
      policy =
          await service?.groupNotificationPolicy(n.spaceId) ??
          const NotificationMutePolicy.all();
      name = (await service?.stateOf(n.spaceId))?.name;
    } catch (_) {}
    if (!mounted || generation != _notificationGeneration) return;
    final self =
        service?.selfId ?? ref.read(appControllerProvider).identity?.nodeId;
    final mentionText = '${n.post.title}\n${n.post.body}';
    final isMention = self != null && messageMentionsNode(mentionText, self);
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted:
          (!notificationsEnabled && !isMention) ||
          !notificationModeAllows(
            policy.effectiveAt(DateTime.now()),
            isMention: isMention,
          ),
      foreground: _foreground,
    )) {
      return;
    }
    await _show(
      convHex: isMention
          ? notificationMentionPayload(
              '/space/${n.spaceId.hex}/comments?post=${Uri.encodeQueryComponent(n.post.postId)}',
            )
          : 'space:${n.spaceId.hex}',
      name: (name != null && name.trim().isNotEmpty) ? name : null,
      shortId: n.spaceId.short,
      preview: n.post.title.trim().isNotEmpty
          ? n.post.title
          : n.post.body.trim().isNotEmpty
          ? n.post.body
          : '…',
      settings: settings,
      allowReply: false,
      isMention: isMention,
    );
  }

  Future<void> _onPublicSpacePostIncoming(
    ({NodeId spaceId, SpacePostView post}) n,
  ) async {
    if (!mounted) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    SpacePublicSubscriptionView? subscription;
    var policy = const NotificationMutePolicy.all();
    try {
      subscription = await service.publicSpaceSubscription(n.spaceId);
      policy = await service.groupNotificationPolicy(n.spaceId);
    } catch (_) {
      return;
    }
    if (!mounted ||
        generation != _notificationGeneration ||
        subscription == null) {
      return;
    }
    final mentionText = '${n.post.title}\n${n.post.body}';
    final isMention = messageMentionsNode(mentionText, service.selfId);
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted:
          (!subscription.subscription.notificationsEnabled && !isMention) ||
          !notificationModeAllows(
            policy.effectiveAt(DateTime.now()),
            isMention: isMention,
          ),
      foreground: _foreground,
    )) {
      return;
    }
    final route =
        '/space/${n.spaceId.hex}/public-posts?post=${Uri.encodeQueryComponent(n.post.postId)}';
    await _show(
      convHex: notificationMentionPayload(route),
      name: subscription.descriptor.name.trim().isNotEmpty
          ? subscription.descriptor.name
          : null,
      shortId: n.spaceId.short,
      preview: n.post.title.trim().isNotEmpty
          ? n.post.title
          : n.post.body.trim().isNotEmpty
          ? n.post.body
          : '…',
      settings: settings,
      allowReply: false,
      isMention: isMention,
    );
  }

  Future<void> _onPublicSpaceCommentIncoming(
    ({NodeId spaceId, SpacePublicCommentView comment}) n,
  ) async {
    if (!mounted) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final postId = n.comment.root.postId;
    final isMention = messageMentionsNode(n.comment.body, service.selfId);
    SpacePublicSubscriptionView? subscription;
    var policy = const NotificationMutePolicy.all();
    var mode = SpaceCommentNotificationMode.none;
    SpacePostView? post;
    SpacePublicCommentView? replyTarget;
    List<SpacePublicCommentView> visibleComments = const [];
    try {
      subscription = await service.publicSpaceSubscription(n.spaceId);
      if (subscription == null) return;
      mode = subscription.subscription.commentNotifications;
      if (mode == SpaceCommentNotificationMode.none && !isMention) return;
      policy = await service.groupNotificationPolicy(n.spaceId);
      post = subscription.feed.posts
          .where((candidate) => candidate.postId == postId)
          .firstOrNull;
      visibleComments = await service.publicSpacePostComments(
        n.spaceId,
        postId,
      );
      if (!visibleComments.any((candidate) => candidate.ref == n.comment.ref)) {
        return;
      }
      if (n.comment.replyTo != null) {
        replyTarget = visibleComments
            .where((candidate) => candidate.ref == n.comment.replyTo)
            .firstOrNull;
      }
    } catch (_) {
      return;
    }
    if (!mounted ||
        generation != _notificationGeneration ||
        post == null ||
        !notificationModeAllows(
          policy.effectiveAt(DateTime.now()),
          isMention: isMention,
        ) ||
        !(isMention ||
            shouldNotifySpaceComment(
              mode: mode,
              repliesToSelf: replyTarget?.author == service.selfId,
              commentsOnOwnPost: post.author == service.selfId,
            ))) {
      return;
    }
    final ordinaryPayload = 'space-public-comment:${n.spaceId.hex}:$postId';
    final route =
        '/space/${n.spaceId.hex}/public-comments?post=${Uri.encodeQueryComponent(postId)}'
        '&comment=${Uri.encodeQueryComponent(n.comment.ref)}';
    final candidate = (
      convHex: isMention ? notificationMentionPayload(route) : ordinaryPayload,
      name: subscription.descriptor.name.trim().isNotEmpty
          ? subscription.descriptor.name
          : null,
      shortId: n.spaceId.short,
      preview: n.comment.body.trim().isNotEmpty
          ? n.comment.body
          : n.comment.media?.name ?? n.comment.media?.kind ?? '…',
      timestampMs: n.comment.createdAtMs,
      allowReply: false,
      isMention: isMention,
    );
    if (_foreground) {
      if (ref.read(activeConversationProvider) != ordinaryPayload) {
        _pendingSpaceComments[ordinaryPayload] = candidate;
      }
      return;
    }
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted: false,
      foreground: false,
    )) {
      return;
    }
    await _show(
      convHex: candidate.convHex,
      name: candidate.name,
      shortId: candidate.shortId,
      preview: candidate.preview,
      settings: settings,
      allowReply: false,
      isMention: isMention,
    );
  }

  /// Comments have their own high-signal preference. Only accepted roots reach
  /// this stream, so edits cannot generate a second alert. While foregrounded,
  /// retain the newest relevant thread and compete with chat/post unread when
  /// the app is minimized, matching the rest of the notification policy.
  Future<void> _onSpaceCommentIncoming(
    ({NodeId spaceId, GroupMessage message}) n,
  ) async {
    if (!mounted) return;
    final postId = n.message.spacePostId;
    if (postId == null) return;
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    var mode = SpaceCommentNotificationMode.none;
    var policy = const NotificationMutePolicy.all();
    String? name;
    SpacePostView? post;
    List<SpacePostCommentView> comments = const [];
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final isMention = messageMentionsNode(n.message.body, service.selfId);
    try {
      final subscription = await service.spaceSubscription(n.spaceId);
      mode = subscription.commentNotifications;
      if (mode == SpaceCommentNotificationMode.none && !isMention) return;
      policy = await service.groupNotificationPolicy(n.spaceId);
      final results = await Future.wait<Object?>([
        service.stateOf(n.spaceId),
        service.postsOf(n.spaceId),
        service.spacePostCommentsOf(n.spaceId, postId),
      ]);
      name = (results[0] as GroupState?)?.name;
      post = (results[1] as List<SpacePostView>)
          .where((candidate) => candidate.postId == postId)
          .firstOrNull;
      comments = results[2] as List<SpacePostCommentView>;
      if (!comments.any((comment) => comment.ref == n.message.ref)) return;
    } catch (_) {
      return;
    }
    if (!mounted || generation != _notificationGeneration) {
      return;
    }
    final replyTarget = n.message.replyTo == null
        ? null
        : comments
              .where((comment) => comment.ref == n.message.replyTo)
              .firstOrNull;
    if (!notificationModeAllows(
          policy.effectiveAt(DateTime.now()),
          isMention: isMention,
        ) ||
        !(isMention ||
            shouldNotifySpaceComment(
              mode: mode,
              repliesToSelf: replyTarget?.author == service.selfId,
              commentsOnOwnPost: post?.author == service.selfId,
            ))) {
      return;
    }
    final ordinaryPayload = 'space-comment:${n.spaceId.hex}:$postId';
    final payload = isMention
        ? notificationMentionPayload(
            '/space/${n.spaceId.hex}/comments?post=${Uri.encodeQueryComponent(postId)}&comment=${Uri.encodeQueryComponent(n.message.ref)}',
          )
        : ordinaryPayload;
    final candidate = (
      convHex: payload,
      name: (name != null && name.trim().isNotEmpty) ? name : null,
      shortId: n.spaceId.short,
      preview: _groupPreview(AppL10n.of(context), n.message),
      timestampMs: n.message.createdAtMs,
      allowReply: false,
      isMention: isMention,
    );
    if (_foreground) {
      if (ref.read(activeConversationProvider) != ordinaryPayload) {
        _pendingSpaceComments[ordinaryPayload] = candidate;
      }
      return;
    }
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted: false,
      foreground: false,
    )) {
      return;
    }
    await _show(
      convHex: candidate.convHex,
      name: candidate.name,
      shortId: candidate.shortId,
      preview: candidate.preview,
      settings: settings,
      allowReply: false,
      isMention: isMention,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Invalidate contact/group lookups that began while backgrounded so they
      // cannot re-post an alert after cancelAll completes.
      _notificationGeneration++;
      // Back in the app — the unread is visible in-app; clear posted alerts.
      unawaited(ref.read(notificationServiceProvider).cancelAll());
      // And drain the mailbox promptly: after a background stint the idle
      // back-off can be minutes deep, and "open the app" is exactly when the
      // user expects parked messages to appear. Guarded: locked → no service.
      try {
        ref.read(messagingServiceProvider).onAppResumed();
      } catch (_) {}
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Minimized — surface every conversation that still has unread (so a
      // message that arrived while the app was open isn't silently missed).
      unawaited(_flushUnread());
    }
  }

  Future<Message?> _newestUnreadDirectMention(
    Conversation conversation,
    NodeId self,
  ) async {
    final storage = ref.read(storageProvider);
    final readAt = await storage.readMarker(conversation.id);
    final messages = await storage.loadMessages(conversation.id);
    return newestByTimestamp(
      messages.where(
        (message) =>
            message.direction == MessageDirection.incoming &&
            message.timestamp.millisecondsSinceEpoch > readAt &&
            messageMentionsNode(message.body, self),
      ),
      (message) => message.timestamp.millisecondsSinceEpoch,
    );
  }

  Future<GroupMessage?> _newestUnreadGroupMention(
    GroupService service,
    NodeId groupId,
  ) async {
    final seen =
        int.tryParse(
          await ref
                  .read(storageProvider)
                  .getSetting('group.seen:${groupId.hex}') ??
              '',
        ) ??
        0;
    final messages = await service.messagesOf(groupId);
    // `seen` is a local clock reading (GroupService.markGroupSeen), so this
    // compares against the derived stamp: a member that stamps itself into the
    // future is otherwise newer than every watermark this device can write,
    // and its mention re-alerts as "the newest one" forever.
    return newestByTimestamp(
      messages.where(
        (message) =>
            message.author != service.selfId &&
            message.orderedAtMs > seen &&
            messageMentionsNode(message.body, service.selfId),
      ),
      (message) => message.orderedAtMs,
    );
  }

  Future<void> _flushUnread() async {
    if (!mounted) return;
    // Captured once before any await: the localized labels the per-candidate
    // previews below need (the loop bodies sit past async gaps).
    final l = AppL10n.of(context);
    final generation = ++_notificationGeneration;
    final settings = ref.read(notificationSettingsProvider);
    devLog(() => 'xVeil[notify]: flush-unread (enabled=${settings.enabled})');
    if (!settings.enabled) return;
    final active = ref.read(activeConversationProvider);
    List<Conversation> convs;
    try {
      convs = await ref.read(storageProvider).loadConversations();
    } catch (_) {
      return;
    }
    if (!mounted || generation != _notificationGeneration) return;
    final candidates =
        <
          ({
            String convHex,
            String? name,
            String shortId,
            String preview,
            int timestampMs,
            bool allowReply,
            bool isMention,
          })
        >[];
    final self = ref.read(appControllerProvider).identity?.nodeId;
    for (final c in convs) {
      final mode = c.peer.notificationModeAt(DateTime.now());
      if (!shouldAlertOnMinimize(
        enabled: settings.enabled,
        unread: c.unread,
        muted: mode == NotificationMuteMode.none,
        isActive: c.id == active,
      )) {
        continue;
      }
      Message? mention;
      if (mode == NotificationMuteMode.mentionsOnly) {
        if (self == null) continue;
        mention = await _newestUnreadDirectMention(c, self);
        if (mention == null) continue;
      }
      candidates.add((
        convHex: mention == null
            ? c.id
            : notificationMentionPayload(
                '/chat/${c.id}?msg=${Uri.encodeQueryComponent(mention.id)}',
              ),
        name: c.peer.name,
        shortId: c.peer.nodeId.short,
        preview:
            mention?.body ??
            (c.lastMessage == null
                ? ''
                : (parseSpaceRecommendationMessage(c.lastMessage!.body)?.name ??
                      // Kind label instead of the stored `📎 <uuid>` body for
                      // voice/video-note/sticker files (display-only).
                      messagePreviewText(l, c.lastMessage!))),
        timestampMs:
            mention?.timestamp.millisecondsSinceEpoch ??
            c.lastMessage?.timestamp.millisecondsSinceEpoch ??
            0,
        allowReply: mention == null,
        isMention: mention != null,
      ));
    }
    // Groups compete with 1:1 chats for the same single latest alert.
    final gsvc = ref.read(groupServiceProvider);
    if (gsvc == null) {
      devLog(() => 'xVeil[notify]: flush — no group service');
    } else {
      try {
        final groups = await gsvc.listGroups();
        devLog(
          () =>
              'xVeil[notify]: flush — ${groups.length} groups, unread: '
              '${[for (final g in groups) g.unread]}',
        );
        if (!mounted || generation != _notificationGeneration) return;
        for (final g in groups) {
          final policy = await gsvc.groupNotificationPolicy(g.groupId);
          final mode = policy.effectiveAt(DateTime.now());
          if (g.unread <= 0 ||
              mode == NotificationMuteMode.none ||
              'group:${g.groupId.hex}' == active) {
            continue;
          }
          final mention = mode == NotificationMuteMode.mentionsOnly
              ? await _newestUnreadGroupMention(gsvc, g.groupId)
              : null;
          if (mode == NotificationMuteMode.mentionsOnly && mention == null) {
            continue;
          }
          candidates.add((
            convHex: mention == null
                ? 'group:${g.groupId.hex}'
                : notificationMentionPayload(
                    '/group/${g.groupId.hex}?msg=${Uri.encodeQueryComponent(mention.ref)}',
                  ),
            name: g.name.trim().isNotEmpty ? g.name : null,
            shortId: g.groupId.short,
            preview: mention == null ? '' : _groupPreview(l, mention),
            timestampMs: mention?.createdAtMs ?? g.lastTs,
            allowReply: mention == null,
            isMention: mention != null,
          ));
        }
        final spaces = await gsvc.listSpaces();
        for (final space in spaces) {
          final subscription = await gsvc.spaceSubscription(space.groupId);
          final policy = await gsvc.groupNotificationPolicy(space.groupId);
          final mode = policy.effectiveAt(DateTime.now());
          if (space.postUnread <= 0 ||
              mode == NotificationMuteMode.none ||
              'space:${space.groupId.hex}' == active) {
            continue;
          }
          final unreadPosts = await gsvc.unreadSpacePostViews(space.groupId);
          final requireMention =
              mode == NotificationMuteMode.mentionsOnly ||
              !subscription.notificationsEnabled;
          final latestPost = newestByTimestamp(
            unreadPosts.where(
              (post) =>
                  !requireMention ||
                  messageMentionsNode(
                    '${post.title}\n${post.body}',
                    gsvc.selfId,
                  ),
            ),
            // Ranked on the derived stamp: a publisher in 2027 would
            // otherwise always be "the newest unread post" and own every
            // notification this Space ever raises.
            (post) => post.orderedAtMs,
          );
          if (latestPost == null) continue;
          final isMention = messageMentionsNode(
            '${latestPost.title}\n${latestPost.body}',
            gsvc.selfId,
          );
          candidates.add((
            convHex: isMention
                ? notificationMentionPayload(
                    '/space/${space.groupId.hex}/comments?post=${Uri.encodeQueryComponent(latestPost.postId)}',
                  )
                : 'space:${space.groupId.hex}',
            name: space.name.trim().isNotEmpty ? space.name : null,
            shortId: space.groupId.short,
            preview: latestPost.title.trim().isNotEmpty
                ? latestPost.title
                : latestPost.body,
            timestampMs: latestPost.orderedAtMs,
            allowReply: false,
            isMention: isMention,
          ));
        }
        for (final public in await gsvc.publicSpaceSubscriptions()) {
          final spaceId = public.descriptor.spaceId;
          final policy = await gsvc.groupNotificationPolicy(spaceId);
          final mode = policy.effectiveAt(DateTime.now());
          if (mode == NotificationMuteMode.none ||
              'space:${spaceId.hex}' == active) {
            continue;
          }
          final unreadPosts = await gsvc.unreadSpacePostViews(spaceId);
          final requireMention =
              mode == NotificationMuteMode.mentionsOnly ||
              !public.subscription.notificationsEnabled;
          final latestPost = newestByTimestamp(
            unreadPosts.where(
              (post) =>
                  !requireMention ||
                  messageMentionsNode(
                    '${post.title}\n${post.body}',
                    gsvc.selfId,
                  ),
            ),
            // Ranked on the derived stamp: a publisher in 2027 would
            // otherwise always be "the newest unread post" and own every
            // notification this Space ever raises.
            (post) => post.orderedAtMs,
          );
          if (latestPost == null) continue;
          final isMention = messageMentionsNode(
            '${latestPost.title}\n${latestPost.body}',
            gsvc.selfId,
          );
          final route =
              '/space/${spaceId.hex}/public-posts?post=${Uri.encodeQueryComponent(latestPost.postId)}';
          candidates.add((
            convHex: notificationMentionPayload(route),
            name: public.descriptor.name.trim().isNotEmpty
                ? public.descriptor.name
                : null,
            shortId: spaceId.short,
            preview: latestPost.title.trim().isNotEmpty
                ? latestPost.title
                : latestPost.body,
            timestampMs: latestPost.orderedAtMs,
            allowReply: false,
            isMention: isMention,
          ));
        }
      } catch (e) {
        // A group-index failure must not suppress a valid 1:1 candidate.
        devLog(() => 'xVeil[notify]: flush — listGroups failed: $e');
      }
    }
    if (!mounted || generation != _notificationGeneration) return;
    final pendingComments = _pendingSpaceComments.entries.toList();
    _pendingSpaceComments.clear();
    for (final pending in pendingComments) {
      if (pending.key == active) continue;
      candidates.add(pending.value);
    }
    final latest = newestByTimestamp(candidates, (c) => c.timestampMs);
    if (latest == null) return;
    await _show(
      convHex: latest.convHex,
      name: latest.name,
      shortId: latest.shortId,
      preview: latest.preview,
      settings: settings,
      allowReply: latest.allowReply,
      isMention: latest.isMention,
    );
  }

  /// Post the single latest-message notification. Every conversation reuses the
  /// same OS id, so mailbox replay and background bursts replace rather than
  /// stack alerts. Honours the hidden/full preview.
  Future<void> _show({
    required String convHex,
    required String? name,
    required String shortId,
    required String preview,
    required NotificationSettings settings,
    bool allowReply = true,
    bool isMention = false,
  }) async {
    if (!mounted) return;
    final l = AppL10n.of(context);
    final full = settings.preview == NotificationPreview.full;
    // Mentions only resolve for a FULL preview — the hidden branch must not
    // even touch the message text.
    final resolved = full
        ? await resolveMentionsForLocalDisplay(ref, preview)
        : '';
    if (!mounted) return;
    final content = notificationContent(
      mode: settings.preview,
      contactName: name,
      shortId: shortId,
      preview: resolved,
      // Hidden: no sender, no text — just that something arrived.
      hiddenBody: isMention ? l.notificationMention : l.notificationNewMessage,
    );
    // Whose notification this is, so a reply can only go out from that
    // identity. Recorded against the RESOLVED payload — the reply callback
    // resolves an opaque token back to this before it looks.
    //
    // Read BEFORE the show and committed AFTER it, and both halves matter.
    // The identity is the one this alert is about, not whichever is active by
    // the time the OS answers. And the commit waits because the show has two
    // silent failure paths: a service that is not ready and a plugin that
    // threw. Recording first meant a show that never happened still moved the
    // owner — while the PREVIOUS alert, belonging to another identity, was
    // still on the screen with its inline reply live. That reply then went out
    // from an identity that never had this conversation, which tells the
    // person on the other end that the two are the same device
    // (report17 XV17-M12). Leaving the map alone on failure keeps the alert
    // that IS on screen attributable to whoever posted it.
    final owners = ref.read(notificationOwnersProvider);
    final owner = ref.read(appControllerProvider).identity?.nodeId.hex;
    final posted = await ref
        .read(notificationServiceProvider)
        .show(
          id: notificationIdForIncomingMessage(convHex),
          title: content.title,
          body: content.body,
          // HIDDEN mode hands the OS a token, not the conversation (audit
          // XV-03). Neutralising the title while still passing `convHex` left
          // the system notification database holding who the user talks to —
          // outside the volume, and long after the app is locked. Full preview
          // keeps the real payload: the title already names the sender, so an
          // indirection there would cost tap-routing and buy nothing.
          payload: full
              ? convHex
              : ref.read(opaqueNotificationPayloadsProvider).mint(convHex),
          // Offer inline reply ONLY when the sender is visible (full preview) —
          // replying to an anonymous "new message" would be confusing, and it
          // keeps the hidden-preview lock-screen surface minimal.
          replyLabel: full && allowReply ? l.notificationReply : null,
          replyHint: full && allowReply ? l.notificationReplyHint : null,
        );
    if (posted) owners.remember(convHex, owner);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceListener?.close();
    _groupServiceListener?.close();
    _sub?.cancel();
    _groupSub?.cancel();
    _spaceCommentSub?.cancel();
    _spacePostSub?.cancel();
    _publicSpacePostSub?.cancel();
    _publicSpaceCommentSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
