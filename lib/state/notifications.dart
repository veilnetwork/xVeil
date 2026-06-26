import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/notifications/notification_service.dart';
import '../routing/router.dart';
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
}) =>
    enabled && !muted && !foreground;

/// Whether, as the app goes to the background, to alert for a conversation —
/// it has unread, isn't muted, and isn't the chat currently open (the one on
/// screen is being read, so it never alerts). This is what makes "minimize the
/// app while a chat has unread → a notification appears" work.
bool shouldAlertOnMinimize({
  required bool enabled,
  required int unread,
  required bool muted,
  required bool isActive,
}) =>
    enabled && unread > 0 && !muted && !isActive;

const _kEnabledKey = 'notifications_enabled';
const _kPreviewKey = 'notifications_preview';

class NotificationSettings {
  const NotificationSettings({required this.enabled, required this.preview});
  final bool enabled;
  final NotificationPreview preview;

  NotificationSettings copyWith({bool? enabled, NotificationPreview? preview}) =>
      NotificationSettings(
        enabled: enabled ?? this.enabled,
        preview: preview ?? this.preview,
      );

  static const defaults =
      NotificationSettings(enabled: true, preview: NotificationPreview.hidden);
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
        NotificationSettingsController.new);

/// The conversation the user is currently VIEWING (peer hex), or null. Set by
/// [ChatScreen] on open/close so the notification layer can suppress an alert
/// for the chat already on screen.
final activeConversationProvider = StateProvider<String?>((ref) => null);

/// The OS-notification backend, initialized once. The tap handler opens the
/// chat named by the notification's payload (the peer hex).
final notificationServiceProvider = Provider<NotificationService>((ref) {
  final svc = NotificationService();
  // Fire-and-forget init; show() is a no-op until it completes.
  svc.init(
    onTap: (payload) {
      if (payload != null && payload.isNotEmpty) {
        ref.read(routerProvider).go('/chat/$payload');
      }
    },
    onReply: (payload, text) {
      // Deliver an inline (notification) reply through the active identity's
      // node. Reachable only while the app / keep-alive service is running (the
      // unlocked container lives in this isolate). Sends from the ACTIVE
      // identity — the common single-identity case; a reply to a notification
      // from a since-switched identity would go from the wrong one.
      try {
        final peer = NodeId.fromHex(payload);
        unawaited(ref.read(messagingServiceProvider).sendText(peer, text));
      } catch (e) {
        devLog(() => 'xVeil[notify]: inline reply failed: $e');
      }
    },
  );
  ref.onDispose(svc.cancelAll);
  return svc;
});
