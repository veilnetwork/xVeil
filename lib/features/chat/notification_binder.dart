import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

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
/// * BACKGROUND — alert in real time, per message (this only fires at all when
///   the node is kept alive in the background — see BackgroundNodeController;
///   otherwise the process is suspended and no message is received here).
/// * ON MINIMIZE — alert for every conversation that still has unread (except
///   the one you were just reading), so nothing is missed.
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
    });
  }

  void _subscribe(MessagingService service) {
    _sub?.cancel();
    _sub = service.incoming.listen(_onIncoming);
  }

  /// A message just arrived. Alert in real time ONLY when backgrounded; a
  /// foreground app shows it in-app and surfaces the rest on minimize.
  Future<void> _onIncoming(IncomingNotice notice) async {
    if (!mounted) return;
    final settings = ref.read(notificationSettingsProvider);
    Contact? contact;
    try {
      contact = await ref.read(storageProvider).getContact(notice.from);
    } catch (_) {}
    if (!mounted) return;
    if (!shouldAlertIncoming(
      enabled: settings.enabled,
      muted: contact?.muted ?? false,
      foreground: _foreground,
    )) {
      return;
    }
    await _show(
      convHex: notice.from.hex,
      name: contact?.name,
      shortId: notice.from.short,
      preview: notice.preview,
      settings: settings,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back in the app — the unread is visible in-app; clear posted alerts.
      unawaited(ref.read(notificationServiceProvider).cancelAll());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Minimized — surface every conversation that still has unread (so a
      // message that arrived while the app was open isn't silently missed).
      unawaited(_flushUnread());
    }
  }

  Future<void> _flushUnread() async {
    if (!mounted) return;
    final settings = ref.read(notificationSettingsProvider);
    if (!settings.enabled) return;
    final active = ref.read(activeConversationProvider);
    List<Conversation> convs;
    try {
      convs = await ref.read(storageProvider).loadConversations();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    for (final c in convs) {
      if (!shouldAlertOnMinimize(
        enabled: settings.enabled,
        unread: c.unread,
        muted: c.peer.muted,
        isActive: c.id == active,
      )) {
        continue;
      }
      await _show(
        convHex: c.id,
        name: c.peer.name,
        shortId: c.peer.nodeId.short,
        preview: c.lastMessage?.body ?? '',
        settings: settings,
      );
    }
  }

  /// Post one notification for a conversation. Same OS id per conversation, so a
  /// chat's alerts collapse instead of stacking. Honours the hidden/full preview.
  Future<void> _show({
    required String convHex,
    required String? name,
    required String shortId,
    required String preview,
    required NotificationSettings settings,
  }) async {
    if (!mounted) return;
    final l = AppL10n.of(context);
    final String title;
    final String body;
    if (settings.preview == NotificationPreview.full) {
      // Prefer the contact's saved name; fall back to a short id (never the full
      // node id on a notification).
      final cn = name?.trim();
      title = (cn != null && cn.isNotEmpty) ? cn : shortId;
      body = preview;
    } else {
      // Hidden: no sender, no text — just that something arrived.
      title = 'xVeil';
      body = l.notificationNewMessage;
    }
    await ref.read(notificationServiceProvider).show(
          id: convHex.hashCode & 0x7fffffff,
          title: title,
          body: body,
          payload: convHex, // tap → open this chat
        );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceListener?.close();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
