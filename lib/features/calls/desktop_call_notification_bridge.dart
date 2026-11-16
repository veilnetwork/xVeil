import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/diagnostic_journal.dart';
import '../../core/log.dart';
import '../../data/notifications/notification_service.dart';
import '../../data/storage/storage.dart';
import '../../domain/call.dart';
import '../../domain/group_call.dart';
import '../../state/call_notification_session.dart';
import '../../state/call_screen_caller.dart';
import '../../state/call_service.dart';
import '../../state/group_call_service.dart';
import '../../state/locale_controller.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

/// The single desktop call-alert owner. Backend events still run while Flutter
/// frames are suspended. Posting never shows or focuses the window.
class DesktopCallNotificationBridge extends ConsumerStatefulWidget {
  const DesktopCallNotificationBridge({super.key});
  @override
  ConsumerState<DesktopCallNotificationBridge> createState() =>
      _DesktopCallNotificationBridgeState();
}

class _DesktopCallNotificationBridgeState
    extends ConsumerState<DesktopCallNotificationBridge>
    with WindowListener, WidgetsBindingObserver {
  final _sessions = CallNotificationSession();
  StreamSubscription<Call?>? _direct;
  StreamSubscription<GroupCall?>? _group;
  NotificationService? _notifications;
  Future<void> _work = Future<void>.value();
  String? _desired;
  int _request = 0, _generation = 0;
  Timer? _retry;
  bool _retired = false, _windowListening = false;

  bool get _enabled =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    if (_windows) {
      windowManager.addListener(this);
      _windowListening = true;
    }
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
    ref.listenManual(localeProvider, (_, _) => _refresh());
  }

  void _refresh() {
    if (_retired || !mounted) return;
    unawaited(
      _update().catchError((Object error) {
        devLog(
          () => 'xVeil[call-notify]: update failed (${error.runtimeType})',
        );
        diagnosticJournal.record(
          DiagnosticEvent.callAlert,
          values: {DiagnosticMetric.state: 3, DiagnosticMetric.success: 0},
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
    final l = l10nFor(
      ref.read(localeProvider) ?? PlatformDispatcher.instance.locale,
    );
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    var background =
        lifecycle != null && lifecycle != AppLifecycleState.resumed;
    if (_windows && settings.enabled && (directRinging || groupRinging)) {
      try {
        final visible = await windowManager.isVisible();
        final focused = visible && await windowManager.isFocused();
        background = !focused;
      } catch (error) {
        // Optional window chrome must not suppress a lifecycle-backed alert.
        devLog(
          () =>
              'xVeil[call-notify]: window query failed (${error.runtimeType})',
        );
      }
    }
    if (_retired || !mounted || request != _request) return;
    final owner = directRinging
        ? direct
        : groupRinging
        ? group
        : null;
    final session = settings.enabled && background && owner != null
        ? _sessions.bind(
            owner,
            directRinging ? call!.callId : room!.callId,
            directRinging ? call!.startedAt : room!.startedAt,
          )
        : null;
    final key = session == null
        ? null
        : '$session:${settings.preview.name}:${l.localeName}';
    if (key == _desired) return;
    _retry?.cancel();
    _retry = null;
    _desired = key;
    final generation = ++_generation;
    final NotificationService notifications =
        _notifications ?? ref.read(notificationServiceProvider);
    _notifications = notifications;
    if (key == null) {
      // Register withdrawal immediately with the shared OS-id queue. Waiting
      // behind this widget's pending post could let retirement erase a new
      // widget's already queued replacement notification.
      unawaited(
        notifications
            .cancelAfterPosts(kNotificationIdIncomingCall)
            .then(
              (_) => diagnosticJournal.record(
                DiagnosticEvent.callAlertDismissed,
                values: {DiagnosticMetric.state: 2},
              ),
              onError: (Object error, StackTrace stack) =>
                  diagnosticJournal.record(
                    DiagnosticEvent.callAlert,
                    values: {
                      DiagnosticMetric.state: 3,
                      DiagnosticMetric.success: 0,
                    },
                  ),
            ),
      );
      return;
    }
    Storage? presentationStorage;
    bool current() {
      if (_retired ||
          !mounted ||
          generation != _generation ||
          key != _desired) {
        return false;
      }
      final liveSettings = ref.read(notificationSettingsProvider);
      if (!liveSettings.enabled || liveSettings.preview != settings.preview) {
        return false;
      }
      if (presentationStorage != null &&
          !identical(ref.read(storageProvider), presentationStorage)) {
        return false;
      }
      if (directRinging) {
        final live = direct.current;
        return identical(ref.read(callServiceProvider), direct) &&
            live?.status == CallStatus.ringing &&
            live?.isIncoming == true &&
            live?.callId == call!.callId &&
            live?.startedAt == call.startedAt;
      }
      final live = group?.current;
      return identical(ref.read(groupCallServiceProvider), group) &&
          live?.status == GroupCallStatus.ringing &&
          live?.callId == room!.callId &&
          live?.startedAt == room.startedAt;
    }

    var attempts = 0;
    late void Function() enqueue;
    void retryPost() {
      if (!current() || attempts >= 4) return;
      _retry?.cancel();
      _retry = Timer(Duration(seconds: 1 << (attempts - 1)), () {
        _retry = null;
        if (current()) enqueue();
      });
    }

    Future<void> attempt() async {
      var triedPost = false;
      try {
        if (!current()) return;
        if (!await notifications.waitUntilReady()) {
          diagnosticJournal.record(
            DiagnosticEvent.callAlert,
            values: {DiagnosticMetric.state: 0, DiagnosticMetric.success: 0},
          );
          return; // Do not reinitialize a failed native backend.
        }
        if (!current()) return;
        var body = directRinging
            ? call!.mediaIdentity.short
            : room!.initiator.short;
        if (settings.preview == NotificationPreview.full) {
          try {
            presentationStorage = ref.read(storageProvider);
            final caller = await loadCallScreenCaller(
              presentationStorage!,
              directRinging ? call!.mediaIdentity : room!.initiator,
            );
            body = caller.label;
          } catch (_) {
            presentationStorage = null;
          }
          if (!current()) return;
        }
        final incoming = directRinging
            ? l.callNotificationIncoming
            : l.callNotificationGroupIncoming;
        attempts++;
        triedPost = true;
        final posted = await notifications.showIfCurrent(
          isCurrent: current,
          id: kNotificationIdIncomingCall,
          title: settings.preview == NotificationPreview.full
              ? incoming
              : 'xVeil',
          body: settings.preview == NotificationPreview.full ? body : incoming,
          payload: kNotificationPayloadIncomingCall,
        );
        diagnosticJournal.record(
          DiagnosticEvent.callAlert,
          values: {
            DiagnosticMetric.state: 1,
            DiagnosticMetric.success: posted ? 1 : 0,
          },
        );
        if (!posted) retryPost();
      } catch (_) {
        diagnosticJournal.record(
          DiagnosticEvent.callAlert,
          values: {DiagnosticMetric.state: 3, DiagnosticMetric.success: 0},
        );
        if (triedPost) retryPost();
      }
    }

    enqueue = () {
      _work = _work.then((_) => attempt());
    };
    enqueue();
  }

  @override
  void dispose() {
    _retired = true;
    _retry?.cancel();
    if (_enabled) {
      if (_windowListening) windowManager.removeListener(this);
      WidgetsBinding.instance.removeObserver(this);
      ++_request;
      ++_generation;
      _sessions.clear();
      final notifications = _notifications;
      if (notifications != null) {
        unawaited(notifications.cancelAfterPosts(kNotificationIdIncomingCall));
      }
    }
    unawaited(_direct?.cancel());
    unawaited(_group?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
