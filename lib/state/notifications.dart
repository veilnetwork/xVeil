import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notifications/notification_service.dart';
import '../routing/router.dart';
import 'providers.dart';

/// How much of an incoming message a notification reveals. Default is
/// [hidden] — a deniability messenger must not paint the sender + text onto a
/// lock screen anyone nearby (or a shoulder-surfer / a seized device) can read.
enum NotificationPreview { hidden, full }

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
  svc.init(onTap: (payload) {
    if (payload != null && payload.isNotEmpty) {
      ref.read(routerProvider).go('/chat/$payload');
    }
  });
  ref.onDispose(svc.cancelAll);
  return svc;
});
