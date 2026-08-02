import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/notifications/notification_service.dart';
import '../data/notifications/opaque_payload.dart';
import '../domain/space_post.dart';
import '../domain/chat.dart' show NotificationMuteMode;
import '../routing/router.dart';
import 'group_service_providers.dart' show groupServiceProvider;
import 'messaging.dart';
import 'providers.dart';

/// How much of an incoming message a notification reveals. Default is
/// [hidden] — a deniability messenger must not paint the sender + text onto a
/// lock screen anyone nearby (or a shoulder-surfer / a seized device) can read.
enum NotificationPreview { hidden, full }

/// Whether to alert in REAL TIME for a freshly-arrived message. We only pop a
/// notification while the app is BACKGROUNDED — a foreground app shows the
/// message in-app, so a popup over it (or over the very chat you're reading)
/// would be noise. What was missed while foreground surfaces on minimize via
/// [shouldAlertOnMinimize]. (Real-time background delivery needs the node kept
/// alive in the background — see BackgroundNodeController.)
bool shouldAlertIncoming({
  required bool enabled,
  required bool muted,
  required bool foreground,
}) => enabled && !muted && !foreground;

/// Whether, as the app goes to the background, to alert for a conversation —
/// it has unread, isn't muted, and isn't the chat currently open (the one on
/// screen is being read, so it never alerts). This is what makes "minimize the
/// app while a chat has unread → a notification appears" work.
bool shouldAlertOnMinimize({
  required bool enabled,
  required int unread,
  required bool muted,
  required bool isActive,
}) => enabled && unread > 0 && !muted && !isActive;

bool notificationModeAllows(
  NotificationMuteMode mode, {
  required bool isMention,
}) => switch (mode) {
  NotificationMuteMode.all => true,
  NotificationMuteMode.mentionsOnly => isMention,
  NotificationMuteMode.none => false,
};

/// Whether an accepted Space discussion entry matches the device-local mode.
/// The focused mode includes direct replies and comments below our own post.
bool shouldNotifySpaceComment({
  required SpaceCommentNotificationMode mode,
  required bool repliesToSelf,
  required bool commentsOnOwnPost,
}) => switch (mode) {
  SpaceCommentNotificationMode.all => true,
  SpaceCommentNotificationMode.replies => repliesToSelf || commentsOnOwnPost,
  SpaceCommentNotificationMode.none => false,
};

/// The title/body privacy split for one message notification (pure — the
/// binder feeds it localized strings). [NotificationPreview.hidden] reveals
/// NOTHING message- or sender-derived: a fixed app title plus the caller's
/// generic [hiddenBody]; [preview] and the contact identity are used only
/// under [NotificationPreview.full].
({String title, String body}) notificationContent({
  required NotificationPreview mode,
  required String? contactName,
  required String shortId,
  required String preview,
  required String hiddenBody,
}) {
  if (mode != NotificationPreview.full) {
    return (title: 'xVeil', body: hiddenBody);
  }
  // Prefer the contact's saved name; fall back to a short id (never the full
  // node id on a notification).
  final cn = contactName?.trim();
  return (
    title: (cn != null && cn.isNotEmpty) ? cn : shortId,
    body: preview,
  );
}

/// All message alerts intentionally reuse one OS notification id. A mailbox
/// replay can restore many unread conversations at startup; assigning an id per
/// conversation would turn that replay into a notification storm. Reusing one
/// id makes each newer alert replace the previous one while preserving the
/// latest conversation payload for tap/reply actions.
int notificationIdForIncomingMessage(String _) => 0x78564d53; // "xVMS"

/// Maps the opaque notification payload to its in-app destination. Spaces are
/// deliberately distinct from group chats: a publication alert opens the
/// community publication surface, never `/group/...` or a direct chat.
String? notificationRouteForPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  if (payload.startsWith('mention:')) {
    try {
      final encoded = payload.substring('mention:'.length);
      final route = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      return route.startsWith('/chat/') ||
              route.startsWith('/group/') ||
              route.startsWith('/space/')
          ? route
          : null;
    } catch (_) {
      return null;
    }
  }
  if (payload.startsWith('space-comment:')) {
    final value = payload.substring('space-comment:'.length);
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) return null;
    final space = value.substring(0, separator);
    final post = value.substring(separator + 1);
    return '/space/$space/comments?post=${Uri.encodeQueryComponent(post)}';
  }
  if (payload.startsWith('space:')) {
    final space = payload.substring(6);
    return space.isEmpty ? null : '/space/$space/posts';
  }
  if (payload.startsWith('group:')) {
    final group = payload.substring(6);
    return group.isEmpty ? null : '/group/$group';
  }
  return '/chat/$payload';
}

String notificationMentionPayload(String route) =>
    'mention:${base64Url.encode(utf8.encode(route)).replaceAll('=', '')}';

/// Publications have no message composer, so the OS must not expose an inline
/// reply action for their payload even when full previews are enabled.
bool notificationPayloadSupportsReply(String payload) =>
    !payload.startsWith('space:') &&
    !payload.startsWith('space-comment:') &&
    !payload.startsWith('mention:');

/// Select the newest candidate without relying on storage/list sort order.
/// Pinned chats, groups, and restored logs can all have different ordering.
T? newestByTimestamp<T>(
  Iterable<T> candidates,
  int Function(T candidate) timestampOf,
) {
  T? newest;
  var newestTimestamp = -1;
  for (final candidate in candidates) {
    final timestamp = timestampOf(candidate);
    if (newest == null || timestamp > newestTimestamp) {
      newest = candidate;
      newestTimestamp = timestamp;
    }
  }
  return newest;
}

const _kEnabledKey = 'notifications_enabled';
const _kPreviewKey = 'notifications_preview';

class NotificationSettings {
  const NotificationSettings({required this.enabled, required this.preview});
  final bool enabled;
  final NotificationPreview preview;

  NotificationSettings copyWith({
    bool? enabled,
    NotificationPreview? preview,
  }) => NotificationSettings(
    enabled: enabled ?? this.enabled,
    preview: preview ?? this.preview,
  );

  static const defaults = NotificationSettings(
    enabled: true,
    preview: NotificationPreview.hidden,
  );
}

/// Notification preferences, persisted to `shared_preferences` (NOT sensitive —
/// whether previews show is not identity-revealing — and needed independent of
/// the unlocked container). Default: enabled, **hidden** preview.
class NotificationSettingsController extends Notifier<NotificationSettings> {
  bool _userSet = false;

  @override
  NotificationSettings build() {
    _load();
    return NotificationSettings.defaults;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (_userSet) return; // don't clobber a set() that raced ahead
      final enabled = prefs.getBool(_kEnabledKey) ?? true;
      final preview = (prefs.getString(_kPreviewKey) == 'full')
          ? NotificationPreview.full
          : NotificationPreview.hidden;
      state = NotificationSettings(enabled: enabled, preview: preview);
    } catch (_) {
      // No prefs (widget tests) — keep the safe defaults.
    }
  }

  Future<void> setEnabled(bool value) async {
    _userSet = true;
    state = state.copyWith(enabled: value);
    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_kEnabledKey, value);
  }

  Future<void> setPreview(NotificationPreview value) async {
    _userSet = true;
    state = state.copyWith(preview: value);
    final prefs = await ref.read(prefsProvider.future);
    await prefs.setString(_kPreviewKey, value.name);
  }
}

final notificationSettingsProvider =
    NotifierProvider<NotificationSettingsController, NotificationSettings>(
      NotificationSettingsController.new,
    );

/// The conversation the user is currently VIEWING (peer hex), or null. Set by
/// [ChatScreen] on open/close so the notification layer can suppress an alert
/// for the chat already on screen.
final activeConversationProvider = StateProvider<String?>((ref) => null);

/// The OS-notification backend, initialized once. The tap handler opens the
/// chat named by the notification's payload (the peer hex).
/// Session-lifetime map from opaque notification tokens to real payloads.
///
/// See [OpaqueNotificationPayloads]: in hidden-preview mode the OS gets a token
/// instead of the conversation id, so its notification database stops
/// accumulating a social graph outside the volume (audit XV-03).
final opaqueNotificationPayloadsProvider = Provider<OpaqueNotificationPayloads>(
  (ref) => OpaqueNotificationPayloads(),
);

/// Turn whatever the OS handed back into the payload the router understands.
///
/// An opaque token that no longer resolves — minted before a lock, or evicted —
/// yields null, and the tap falls through to simply opening the app. That is
/// the correct outcome: the alternative is guessing a destination for a
/// conversation this session may not be able to open.
String? resolveNotificationPayload(Ref ref, String? payload) {
  if (payload == null || payload.isEmpty) return null;
  if (!isOpaqueNotificationToken(payload)) return payload;
  return ref.read(opaqueNotificationPayloadsProvider).resolve(payload);
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final svc = NotificationService();
  // Fire-and-forget init; show() is a no-op until it completes.
  svc.init(
    onTap: (raw) {
      final payload = resolveNotificationPayload(ref, raw);
      final route = notificationRouteForPayload(payload);
      if (route != null) {
        // go() alone REPLACES the stack: the chat would open with no back
        // button (user-reported on desktop). Root the stack at home first,
        // then push — back leads to the chat list, like a normal open.
        // A `group:<hex>` payload opens the group chat instead of a 1:1.
        ref.read(routerProvider)
          ..go('/home')
          ..push(route);
      }
    },
    onReply: (raw, text) {
      // Reply is offered only in FULL preview (the hidden lock screen has no
      // sender to reply to), so `raw` is normally the real payload — but it is
      // resolved anyway rather than assumed, because the two decisions live in
      // different files and only one of them is about privacy.
      final payload = resolveNotificationPayload(ref, raw);
      if (payload == null) return;
      // A notification reply (showsUserInterface:true) foregrounds the app and
      // lands here on the MAIN isolate, where the unlocked container + the node
      // live, so the send actually works. Open the chat too, so the user sees
      // their just-sent message. Sends from the ACTIVE identity (the common
      // single-identity case; a reply from a since-switched identity would go
      // from the wrong one).
      try {
        if (!notificationPayloadSupportsReply(payload)) {
          final route = notificationRouteForPayload(payload);
          if (route != null) {
            ref.read(routerProvider)
              ..go('/home')
              ..push(route);
          }
          return;
        }
        if (payload.startsWith('group:')) {
          final gidHex = payload.substring(6);
          final svc = ref.read(groupServiceProvider);
          if (svc != null) {
            unawaited(svc.postMessage(NodeId.fromHex(gidHex), text));
          }
          ref.read(routerProvider)
            ..go('/home')
            ..push('/group/$gidHex');
          return;
        }
        final peer = NodeId.fromHex(payload);
        unawaited(ref.read(messagingServiceProvider).sendText(peer, text));
        // Same stack-rooting as onTap: never land in a chat with no way back.
        ref.read(routerProvider)
          ..go('/home')
          ..push('/chat/$payload');
      } catch (e) {
        devLog(() => 'xVeil[notify]: inline reply failed: $e');
      }
    },
  );
  ref.onDispose(svc.cancelAll);
  return svc;
});
