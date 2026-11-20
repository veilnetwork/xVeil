import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
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
import '../../domain/clear_request.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart';
import '../../state/mention_identity.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';
import 'attachment_preview.dart';
import 'message_mentions.dart';

typedef _MessageAlertAttempt = ({
  int generation,
  int sequence,
  NodeId? owner,
  int? groupGeneration,
});
typedef _MessageAlertCandidate = ({
  String convHex,
  String? name,
  String shortId,
  String preview,
  int timestampMs,
  bool allowReply,
  bool isMention,
});

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
  ProviderSubscription<AsyncValue<List<PendingClearRequest>>>?
  _clearRequestListener;

  /// The requests already alerted for, so a list that merely RE-EMITS — every
  /// service signal rebuilds it — does not re-announce a question the person
  /// has already been shown. Cleared on identity switch with everything else.
  final Set<String> _announcedClearRequests = {};
  Set<String> _liveClearRequests = const {};
  int? _clearRequestPostGeneration;
  final _pendingSpaceComments =
      <
        String,
        ({_MessageAlertAttempt attempt, _MessageAlertCandidate candidate})
      >{};
  int _notificationGeneration = 0;
  int? _unreadScanGeneration;
  int _groupNotificationGeneration = 0;
  final _unreadGroupWaits = <VoidCallback>{};
  int _notificationSequence = 0;
  int _latestEligibleSequence = 0;
  // Clear requests have a separate OS id. An ordinary message supersedes the
  // message preview, but must not invalidate a pending destructive question.
  int _clearRequestGeneration = 0;
  bool _permissionRequestPending = false;
  bool _permissionDecided = false;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
      // Null only at the very first frame — treat as foreground (suppress).
      WidgetsBinding.instance.lifecycleState == null;

  _MessageAlertAttempt _beginMessageAlert({bool groupScoped = false}) => (
    generation: _notificationGeneration,
    sequence: ++_notificationSequence,
    owner: ref.read(appControllerProvider).identity?.nodeId,
    groupGeneration: groupScoped ? _groupNotificationGeneration : null,
  );

  bool _canContinueMessageAlert(_MessageAlertAttempt attempt) =>
      mounted &&
      attempt.generation == _notificationGeneration &&
      (attempt.groupGeneration == null ||
          attempt.groupGeneration == _groupNotificationGeneration) &&
      attempt.sequence >= _latestEligibleSequence &&
      ref.read(appControllerProvider).identity?.nodeId == attempt.owner;

  void _rememberSpaceComment(
    String thread,
    _MessageAlertAttempt attempt,
    _MessageAlertCandidate candidate,
  ) {
    if (ref.read(activeConversationProvider) == thread) return;
    final previous = _pendingSpaceComments[thread];
    if (previous != null && previous.attempt.sequence > attempt.sequence) {
      return;
    }
    _pendingSpaceComments[thread] = (attempt: attempt, candidate: candidate);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer until after the first frame so the unlock→home provider cascade has
    // fully settled before we attach any listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_requestNotificationPermission());
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
      // A request to EMPTY a conversation, waiting for an answer. Without an
      // alert it is only found by opening settings, and a question nobody is
      // shown is the same as one declined for them — which is exactly what the
      // "ask me" policy exists to avoid.
      _clearRequestListener = ref
          .listenManual<AsyncValue<List<PendingClearRequest>>>(
            pendingClearRequestsProvider,
            (_, next) {
              final requests = next.asData?.value;
              if (requests != null) unawaited(_onClearRequests(requests));
            },
            fireImmediately: true,
          );
    });
  }

  Future<void> _requestNotificationPermission() async {
    if (_permissionDecided || _permissionRequestPending || !_foreground) {
      return;
    }
    _permissionRequestPending = true;
    try {
      final service = ref.read(notificationServiceProvider);
      // Reading the provider starts native initialization. Its permission
      // method cannot ask Android/iOS until that initialization has finished.
      if (!await service.waitUntilReady() ||
          !mounted ||
          !_foreground ||
          ref.read(appControllerProvider).phase != AppPhase.ready) {
        return;
      }
      // The pending flag covers the prompt's own inactive/resumed transition.
      // Only a real OS decision suppresses attempts on later returns.
      _permissionDecided = await service.requestPermission() != null;
    } finally {
      _permissionRequestPending = false;
    }
  }

  void _subscribe(MessagingService service) {
    // The SWITCH ITSELF invalidates whatever is in flight. Re-subscribing is
    // what a switch does here, and it used to leave the generation alone — so
    // a notice that arrived under A and was still resolving mentions kept its
    // ticket and finished under B.
    _notificationGeneration++;
    _clearRequestGeneration++;
    _cancelUnreadGroupWaits();
    // The requests belong to the identity that was on screen, and the list is
    // rebuilt for the new one — so the memory of what has been announced goes
    // with the old identity rather than suppressing the new one's questions.
    _announcedClearRequests.clear();
    _liveClearRequests = const {};
    _pendingSpaceComments.clear();
    _sub?.cancel();
    _sub = service.incoming.listen(_onIncoming);
  }

  void _subscribeGroups(GroupService? service) {
    _groupNotificationGeneration++;
    _cancelUnreadGroupWaits();
    _pendingSpaceComments.clear();
    // Group service initialization does not replace the messaging service's
    // request list. Its alerts retain their own identity/lifecycle fence.
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
    final attempt = _beginMessageAlert();
    final l = AppL10n.of(context);
    final settings = ref.read(notificationSettingsProvider);
    final Contact? contact;
    try {
      contact = await ref.read(storageProvider).getContact(notice.from);
    } catch (_) {
      // A failed read cannot establish that the conversation is unmuted.
      return;
    }
    if (!_canContinueMessageAlert(attempt)) return;
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
      attempt: attempt,
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
              l,
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
    final attempt = _beginMessageAlert(groupScoped: true);
    final l = AppL10n.of(context);
    final settings = ref.read(notificationSettingsProvider);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final NotificationMutePolicy policy;
    try {
      policy = await service.groupNotificationPolicy(n.groupId);
    } catch (_) {
      return;
    }
    if (!_canContinueMessageAlert(attempt)) return;
    final isMention = messageMentionsNode(n.message.body, service.selfId);
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
      name = (await service.stateOf(n.groupId))?.name;
    } catch (_) {}
    if (!_canContinueMessageAlert(attempt)) return;
    await _show(
      attempt: attempt,
      convHex: isMention
          ? notificationMentionPayload(
              '/group/${n.groupId.hex}?msg=${Uri.encodeQueryComponent(n.message.ref)}',
            )
          : 'group:${n.groupId.hex}',
      name: (name != null && name.trim().isNotEmpty) ? name : null,
      shortId: n.groupId.short,
      preview: _groupPreview(l, n.message),
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
    final attempt = _beginMessageAlert(groupScoped: true);
    final settings = ref.read(notificationSettingsProvider);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final SpaceSubscription subscription;
    final NotificationMutePolicy policy;
    try {
      subscription = await service.spaceSubscription(n.spaceId);
      policy = await service.groupNotificationPolicy(n.spaceId);
    } catch (_) {
      return;
    }
    if (!_canContinueMessageAlert(attempt)) return;
    final mentionText = '${n.post.title}\n${n.post.body}';
    final isMention = messageMentionsNode(mentionText, service.selfId);
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted:
          (!subscription.notificationsEnabled && !isMention) ||
          !notificationModeAllows(
            policy.effectiveAt(DateTime.now()),
            isMention: isMention,
          ),
      foreground: _foreground,
    )) {
      return;
    }
    String? name;
    try {
      name = (await service.stateOf(n.spaceId))?.name;
    } catch (_) {}
    if (!_canContinueMessageAlert(attempt)) return;
    await _show(
      attempt: attempt,
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
    final attempt = _beginMessageAlert(groupScoped: true);
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
    if (!_canContinueMessageAlert(attempt) || subscription == null) {
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
      attempt: attempt,
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
    final attempt = _beginMessageAlert(groupScoped: true);
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
    if (!_canContinueMessageAlert(attempt) ||
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
      _rememberSpaceComment(ordinaryPayload, attempt, candidate);
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
      attempt: attempt,
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
    final attempt = _beginMessageAlert(groupScoped: true);
    final l = AppL10n.of(context);
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
    if (!_canContinueMessageAlert(attempt)) {
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
      preview: _groupPreview(l, n.message),
      timestampMs: n.message.createdAtMs,
      allowReply: false,
      isMention: isMention,
    );
    if (_foreground) {
      _rememberSpaceComment(ordinaryPayload, attempt, candidate);
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
      attempt: attempt,
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
      _clearRequestGeneration++;
      _cancelUnreadGroupWaits();
      // Back in the app — the unread is visible in-app; clear posted alerts.
      unawaited(ref.read(notificationServiceProvider).cancelAll());
      unawaited(_requestNotificationPermission());
      // And drain the mailbox promptly: after a background stint the idle
      // back-off can be minutes deep, and "open the app" is exactly when the
      // user expects parked messages to appear. Guarded: locked → no service.
      try {
        ref.read(messagingServiceProvider).onAppResumed();
      } catch (_) {}
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Mobile can emit hidden, paused, then hidden again before resume.
      // Reconcile unread once per background stay for this messaging owner.
      if (_unreadScanGeneration == _notificationGeneration) return;
      _unreadScanGeneration = _notificationGeneration;
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

  Future<T?> _readUnread<T>(String source, Future<T> Function() read) async {
    try {
      return await read();
    } catch (error) {
      // A failed summary or policy read says nothing about the other chats.
      devLog(() => 'xVeil[notify]: unread $source failed (${error.runtimeType})');
      return null;
    }
  }

  void _cancelUnreadGroupWaits() {
    for (final cancel in _unreadGroupWaits) {
      cancel();
    }
    _unreadGroupWaits.clear();
  }

  Future<void> _flushUnread() async {
    if (!mounted) return;
    // Captured once before any await: the localized labels the per-candidate
    // previews below need (the loop bodies sit past async gaps).
    final l = AppL10n.of(context);
    final attempt = _beginMessageAlert();
    final groupAttempt = (
      generation: attempt.generation,
      sequence: attempt.sequence,
      owner: attempt.owner,
      groupGeneration: _groupNotificationGeneration,
    );
    final settings = ref.read(notificationSettingsProvider);
    devLog(() => 'xVeil[notify]: flush-unread (enabled=${settings.enabled})');
    if (!settings.enabled) return;
    final active = ref.read(activeConversationProvider);
    final convs = await _readUnread(
      'chats',
      () => ref.read(storageProvider).loadConversations(),
    );
    if (!_canContinueMessageAlert(attempt)) return;
    final directCandidates = <_MessageAlertCandidate>[];
    final self = ref.read(appControllerProvider).identity?.nodeId;
    for (final c in convs ?? const <Conversation>[]) {
      if (!_canContinueMessageAlert(attempt)) return;
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
        mention = await _readUnread<Message?>(
          'chat mentions',
          () => _newestUnreadDirectMention(c, self),
        );
        if (mention == null) continue;
      }
      directCandidates.add((
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
    final groupCandidates = <_MessageAlertCandidate>[];
    final gsvc = _canContinueMessageAlert(groupAttempt)
        ? ref.read(groupServiceProvider)
        : null;
    if (gsvc == null) {
      devLog(() => 'xVeil[notify]: flush — no group service');
    } else {
      Future<T?> readGroup<T>(String source, Future<T> Function() read) async {
        if (!_canContinueMessageAlert(groupAttempt)) return null;
        // A retired group service may still be resolving a disk read.
        // Stop waiting so a valid personal chat can finish this selection.
        final retired = Completer<T?>();
        void cancel() => retired.complete(null);
        _unreadGroupWaits.add(cancel);
        try {
          return await Future.any([_readUnread(source, read), retired.future]);
        } finally {
          _unreadGroupWaits.remove(cancel);
        }
      }

      try {
        final groups = await readGroup('groups', gsvc.listGroups) ?? [];
        devLog(
          () =>
              'xVeil[notify]: flush — ${groups.length} groups, unread: '
              '${[for (final g in groups) g.unread]}',
        );
        if (!_canContinueMessageAlert(attempt)) return;
        for (final g in groups) {
          if (g.unread <= 0 || 'group:${g.groupId.hex}' == active) continue;
          final policy = await readGroup(
            'group policy',
            () => gsvc.groupNotificationPolicy(g.groupId),
          );
          final mode = policy?.effectiveAt(DateTime.now());
          if (mode == null || mode == NotificationMuteMode.none) {
            continue;
          }
          final mention = mode == NotificationMuteMode.mentionsOnly
              ? await readGroup<GroupMessage?>(
                  'group mentions',
                  () => _newestUnreadGroupMention(gsvc, g.groupId),
                )
              : null;
          if (mode == NotificationMuteMode.mentionsOnly && mention == null) {
            continue;
          }
          groupCandidates.add((
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
        final spaces = await readGroup('spaces', gsvc.listSpaces) ?? [];
        for (final space in spaces) {
          if (space.postUnread <= 0 || 'space:${space.groupId.hex}' == active) {
            continue;
          }
          final policy = await readGroup(
            'space policy',
            () => gsvc.groupNotificationPolicy(space.groupId),
          );
          final mode = policy?.effectiveAt(DateTime.now());
          if (mode == null || mode == NotificationMuteMode.none) continue;
          final subscription = await readGroup(
            'space subscription',
            () => gsvc.spaceSubscription(space.groupId),
          );
          if (subscription == null) continue;
          final unreadPosts = await readGroup(
            'space posts',
            () => gsvc.unreadSpacePostViews(space.groupId),
          );
          if (unreadPosts == null) continue;
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
          groupCandidates.add((
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
        final publicSpaces =
            await readGroup('public spaces', gsvc.publicSpaceSubscriptions) ??
            [];
        for (final public in publicSpaces) {
          final spaceId = public.descriptor.spaceId;
          if ('space:${spaceId.hex}' == active) continue;
          final policy = await readGroup(
            'public space policy',
            () => gsvc.groupNotificationPolicy(spaceId),
          );
          final mode = policy?.effectiveAt(DateTime.now());
          if (mode == null || mode == NotificationMuteMode.none) {
            continue;
          }
          final unreadPosts = await readGroup(
            'public space posts',
            () => gsvc.unreadSpacePostViews(spaceId),
          );
          if (unreadPosts == null) continue;
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
          groupCandidates.add((
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
        // Keep any healthy candidate even if its peer's projection fails.
        devLog(
          () => 'xVeil[notify]: unread projection failed (${e.runtimeType})',
        );
      }
    }
    if (!_canContinueMessageAlert(attempt)) return;
    _MessageAlertCandidate? groupLatest;
    if (_canContinueMessageAlert(groupAttempt)) {
      final pendingComments = _pendingSpaceComments.entries.toList();
      _pendingSpaceComments.clear();
      for (final pending in pendingComments) {
        if (pending.key == active ||
            pending.value.attempt.owner != attempt.owner) {
          continue;
        }
        groupCandidates.add(pending.value.candidate);
      }
      groupLatest = newestByTimestamp(groupCandidates, (c) => c.timestampMs);
    }
    final directLatest = newestByTimestamp(
      directCandidates,
      (c) => c.timestampMs,
    );
    final useGroup =
        groupLatest != null &&
        (directLatest == null ||
            groupLatest.timestampMs > directLatest.timestampMs);
    final latest = useGroup ? groupLatest : directLatest;
    if (latest == null) return;
    await _show(
      attempt: useGroup ? groupAttempt : attempt,
      convHex: latest.convHex,
      name: latest.name,
      shortId: latest.shortId,
      preview: latest.preview,
      settings: settings,
      allowReply: latest.allowReply,
      isMention: latest.isMention,
    );
  }

  /// Announce requests that have not been announced yet.
  ///
  /// The list re-emits on every service signal, so the set of keys already
  /// announced is what keeps one question to one alert. Nothing about WHICH
  /// chat was asked about reaches the OS: the alert opens the list, and a
  /// payload naming a conversation would leave that name in the system
  /// notification database, outside the volume — the same reason a hidden
  /// message preview mints an opaque token instead of the conversation id.
  Future<void> _onClearRequests(List<PendingClearRequest> requests) async {
    if (!mounted) return;
    final live = {for (final request in requests) request.key};
    if (!setEquals(_liveClearRequests, live)) {
      _liveClearRequests = live;
      _clearRequestGeneration++;
      _announcedClearRequests.retainAll(live);
      if (live.isEmpty) {
        await ref
            .read(notificationServiceProvider)
            .cancelAfterPosts(kNotificationIdClearRequests);
        return;
      }
    }
    final generation = _clearRequestGeneration;
    if (_clearRequestPostGeneration == generation ||
        !ref.read(notificationSettingsProvider).enabled) {
      return;
    }
    final fresh = live.difference(_announcedClearRequests);
    if (fresh.isEmpty) return;
    final identity = ref.read(appControllerProvider).identity?.nodeId;
    final l = AppL10n.of(context);
    bool current() =>
        mounted &&
        generation == _clearRequestGeneration &&
        ref.read(appControllerProvider).identity?.nodeId == identity &&
        ref.read(notificationSettingsProvider).enabled;

    _clearRequestPostGeneration = generation;
    try {
      final posted = await ref
          .read(notificationServiceProvider)
          .showIfCurrent(
            isCurrent: current,
            id: kNotificationIdClearRequests,
            title: l.clearRequestsNotificationTitle,
            body: l.clearRequestsNotificationBody(live.length),
            payload: kNotificationPayloadClearRequests,
          );
      if (posted && current()) _announcedClearRequests.addAll(fresh);
    } finally {
      if (_clearRequestPostGeneration == generation) {
        _clearRequestPostGeneration = null;
      }
    }
  }

  /// Post the single latest-message notification with the configured preview.
  Future<void> _show({
    required _MessageAlertAttempt attempt,
    required String convHex,
    required String? name,
    required String shortId,
    required String preview,
    required NotificationSettings settings,
    bool allowReply = true,
    bool isMention = false,
  }) async {
    if (!_canContinueMessageAlert(attempt)) return;
    final liveSettings = ref.read(notificationSettingsProvider);
    if (!liveSettings.enabled) return;
    // An arrival can replace the pending alert only after passing policy.
    // Compare arrival order so even if an older lookup finishes after a
    // newer eligible one, the OS keeps the newer message.
    _latestEligibleSequence = attempt.sequence;
    final l = AppL10n.of(context);
    final mayShowFull =
        settings.preview == NotificationPreview.full &&
        liveSettings.preview == NotificationPreview.full;
    // Mentions only resolve for a FULL preview — the hidden branch must not
    // even touch the message text.
    final resolved = mayShowFull
        ? await resolveMentionsForLocalDisplay(ref, preview)
        : '';
    if (!_canContinueMessageAlert(attempt)) return;
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
    final owner = attempt.owner?.hex;
    final id = notificationIdForIncomingMessage(convHex);
    var postedFull = false;
    bool current() {
      if (!_canContinueMessageAlert(attempt)) return false;
      final settings = ref.read(notificationSettingsProvider);
      return settings.enabled &&
          (!postedFull || settings.preview == NotificationPreview.full);
    }

    final posted = await ref
        .read(notificationServiceProvider)
        .showPreparedIfCurrent(
          isCurrent: current,
          id: id,
          prepare: () {
            // A downgrade applies immediately. An alert that opted out of
            // full text earlier cannot gain it while queued.
            postedFull =
                mayShowFull &&
                ref.read(notificationSettingsProvider).preview ==
                    NotificationPreview.full;
            final content = notificationContent(
              mode: postedFull
                  ? NotificationPreview.full
                  : NotificationPreview.hidden,
              contactName: name,
              shortId: shortId,
              preview: resolved,
              hiddenBody: isMention
                  ? l.notificationMention
                  : l.notificationNewMessage,
            );
            return (
              title: content.title,
              body: content.body,
              // Keep conversation IDs out of the OS database in hidden mode.
              payload: postedFull
                  ? convHex
                  : ref.read(opaqueNotificationPayloadsProvider).mint(convHex),
              replyLabel: postedFull && allowReply ? l.notificationReply : null,
              replyHint: postedFull && allowReply
                  ? l.notificationReplyHint
                  : null,
            );
          },
        );
    if (!posted) return;
    // The service orders a stale post's take-down BEFORE a newer post using
    // this id. Never cancel here: the id may already belong to a later alert.
    if (!current()) return;
    owners.remember(convHex, owner);
  }

  @override
  void dispose() {
    _notificationGeneration++;
    _clearRequestGeneration++;
    _cancelUnreadGroupWaits();
    WidgetsBinding.instance.removeObserver(this);
    _serviceListener?.close();
    _groupServiceListener?.close();
    _clearRequestListener?.close();
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
