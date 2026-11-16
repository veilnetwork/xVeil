import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/log.dart';
import '../../data/notifications/notification_service.dart';
import '../../domain/call.dart';
import '../../domain/group_call.dart';
import '../../state/call_notification_session.dart';
import '../../state/call_screen_caller.dart';
import '../../state/call_service.dart';
import '../../state/group_call_service.dart';
import '../../state/locale_controller.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

/// Windows has no Android foreground-service call notification. Keep its toast
/// alive from backend events, including while the Flutter window is hidden.
/// Posting never shows or focuses the window; only an explicit toast tap can.
class DesktopCallNotificationBridge extends ConsumerStatefulWidget {
  const DesktopCallNotificationBridge({super.key});

  @override
  ConsumerState<DesktopCallNotificationBridge> createState() =>
      _DesktopCallNotificationBridgeState();
}

class _DesktopCallNotificationBridgeState
    extends ConsumerState<DesktopCallNotificationBridge>
    with WindowListener, WidgetsBindingObserver {
  late final NotificationService _notifications;
  bool _retired = false;

  final _sessions = CallNotificationSession();
  Future<void> _work = Future.value();
  int _request = 0, _generation = 0;
  (String, NotificationPreview)? _desired;

  bool get _enabled => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    _notifications = ref.read(notificationServiceProvider);
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(callServiceProvider, (_, next) {
      unawaited(_direct?.cancel());
      _direct = next.changes.listen((_) => _refresh());
      _refresh();
    }, fireImmediately: true);
    ref.listenManual(groupCallServiceProvider, (_, next) {
      unawaited(_group?.cancel());
      _group = next?.changes.listen((_) => _refresh());
      _refresh();
    }, fireImmediately: true);
    ref.listenManual(notificationSettingsProvider, (_, _) => _refresh());
  }

  StreamSubscription<Call?>? _direct;
  StreamSubscription<GroupCall?>? _group;

  void _refresh() {
    if (_retired || !mounted) return;
    unawaited(
      _update().catchError((Object error) {
        // Do not put caller names, call IDs or platform exception text in logs.
        devLog(
          () => 'xVeil[call-notify]: update failed (${error.runtimeType})',
        );
      }),
    );
  }

  @override
  void onWindowEvent(String eventName) => _refresh();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _refresh();

  Future<void> _update() async {
    final request = ++_request;
    final direct = ref.read(callServiceProvider);
    final group = ref.read(groupCallServiceProvider);
    final call = direct.current;
    final room = group?.current;
    final directRinging =
        call?.isIncoming == true && call?.status == CallStatus.ringing;
    final groupRinging =
        !directRinging && room?.status == GroupCallStatus.ringing;
    final settings = ref.read(notificationSettingsProvider);
    String? session;
    if (settings.enabled && (directRinging || groupRinging)) {
      // Read-only window queries: closing to tray need not produce a new frame.
      final visible = await windowManager.isVisible();
      final focused = visible && await windowManager.isFocused();
      if (!mounted || request != _request) return;
      if (!focused) {
        session = _sessions.bind(
          directRinging ? direct : group!,
          directRinging ? call!.callId : room!.callId,
          directRinging ? call!.startedAt : room!.startedAt,
        );
      }
    }
    if (!mounted || request != _request) return;
    final desired = session == null ? null : (session, settings.preview);
    if (desired == _desired) return;
    _desired = desired;
    final generation = ++_generation;
    final notifications = _notifications;
    bool current() => !_retired && mounted && generation == _generation;
    _work = _work
        .then((_) async {
          if (!current()) return;
          if (desired == null) {
            await notifications.cancel(kNotificationIdIncomingCall);
            return;
          }
          final l = l10nFor(
            ref.read(localeProvider) ?? PlatformDispatcher.instance.locale,
          );
          var body = l.callIncoming;
          if (settings.preview == NotificationPreview.full) {
            final peer = directRinging ? call!.mediaIdentity : room!.initiator;
            try {
              final caller = await loadCallScreenCaller(
                ref.read(storageProvider),
                peer,
              );
              body = caller.label;
            } catch (_) {
              // An unreadable name must not hide the incoming call itself.
            }
            if (!current()) return;
          }
          await notifications.showIfCurrent(
            isCurrent: current,
            id: kNotificationIdIncomingCall,
            title: 'xVeil',
            body: settings.preview == NotificationPreview.full
                ? '${groupRinging ? l.callNotificationGroupIncoming : l.callNotificationIncoming}\n$body'
                : (groupRinging
                      ? l.callNotificationGroupIncoming
                      : l.callNotificationIncoming),
            payload: kNotificationPayloadIncomingCall,
          );
        })
        .catchError((Object error) {
          devLog(
            () => 'xVeil[call-notify]: post failed (${error.runtimeType})',
          );
        });
  }

  @override
  void dispose() {
    _retired = true;
    if (_enabled) {
      windowManager.removeListener(this);
      WidgetsBinding.instance.removeObserver(this);
      ++_request;
      ++_generation;
      _sessions.clear();
      final notifications = _notifications;
      // A delayed OS post is joined before clearing this owner's alert. Its
      // isCurrent guard prevents a toast from surviving an identity teardown.
      unawaited(notifications.cancelAfterPosts(kNotificationIdIncomingCall));
    }
    unawaited(_direct?.cancel());
    unawaited(_group?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
