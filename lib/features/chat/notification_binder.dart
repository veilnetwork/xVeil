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

class _NotificationBinderState extends ConsumerState<NotificationBinder> {
  StreamSubscription<IncomingNotice>? _sub;
  ProviderSubscription<MessagingService>? _serviceListener;

  @override
  void initState() {
    super.initState();
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
    });
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
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
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
    _serviceListener?.close();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
