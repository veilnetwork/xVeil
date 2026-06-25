import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

/// Bridges the active messaging service's [MessagingService.incoming] stream to
/// OS notifications, applying the privacy policy. A widget (not a bare provider)
/// so it has a [BuildContext] for localized, preview-respecting strings.
///
/// Suppresses an alert for the conversation already on screen while the app is
/// foreground; re-subscribes when the active identity's service changes.
class NotificationBinder extends ConsumerStatefulWidget {
  const NotificationBinder({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<NotificationBinder> createState() => _NotificationBinderState();
}

class _NotificationBinderState extends ConsumerState<NotificationBinder> {
  StreamSubscription<IncomingNotice>? _sub;

  @override
  void initState() {
    super.initState();
    // Ensure the OS backend is initialized + permission asked once.
    final svc = ref.read(notificationServiceProvider);
    unawaited(svc.requestPermission());
    _subscribe(ref.read(messagingServiceProvider));
  }

  void _subscribe(MessagingService service) {
    _sub?.cancel();
    _sub = service.incoming.listen(_onIncoming);
  }

  Future<void> _onIncoming(IncomingNotice notice) async {
    if (!mounted) return;
    final settings = ref.read(notificationSettingsProvider);
    if (!settings.enabled) return;
    // Don't alert for the chat the user is looking at (only when foreground).
    final foreground = WidgetsBinding.instance.lifecycleState ==
        AppLifecycleState.resumed;
    if (foreground && ref.read(activeConversationProvider) == notice.from.hex) {
      return;
    }
    final l = AppL10n.of(context);
    final String title;
    final String body;
    if (settings.preview == NotificationPreview.full) {
      // Prefer the contact's saved name; fall back to a short id (never the
      // full node id on a notification).
      String name = notice.from.short;
      try {
        final c = await ref.read(storageProvider).getContact(notice.from);
        if (c?.name != null && c!.name!.trim().isNotEmpty) name = c.name!.trim();
      } catch (_) {}
      title = name;
      body = notice.preview;
    } else {
      // Hidden: no sender, no text — just that something arrived.
      title = 'xVeil';
      body = l.notificationNewMessage;
    }
    await ref.read(notificationServiceProvider).show(
          id: notice.from.hex.hashCode & 0x7fffffff,
          title: title,
          body: body,
          payload: notice.from.hex, // tap → open this chat
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-subscribe when the active identity's messaging service changes.
    ref.listen(messagingServiceProvider, (_, next) => _subscribe(next));
    return widget.child;
  }
}
