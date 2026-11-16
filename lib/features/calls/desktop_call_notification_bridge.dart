import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/diagnostic_journal.dart';
import '../../core/ids.dart';
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

// Local presentation is optional: never postpone a ringing alert indefinitely
// behind a busy container. On timeout, full preview uses the peer's short ID.
const _callerLabelBudget = Duration(milliseconds: 250);
const _windowQueryBudget = Duration(milliseconds: 250);

enum _WindowQueryOutcome { observed, timedOut, failed }

typedef _WindowObservation = ({bool background, _WindowQueryOutcome outcome});

/// Bounded first answer, followed by one eventual native answer if still owned.
/// Neither a pending platform future nor its late callback retains a call,
/// provider or storage owner. Retirement also stops a second native query.
class _WindowQuery {
  _WindowQuery(this._fallback, this._onLate) {
    _deadline = Timer(_windowQueryBudget, () {
      if (!_initial.isCompleted) {
        _initial.complete((
          background: _fallback,
          outcome: _WindowQueryOutcome.timedOut,
        ));
      }
    });
    unawaited(_observe());
  }

  final bool _fallback;
  final _initial = Completer<_WindowObservation>();
  void Function(_WindowObservation)? _onLate;
  late final Timer _deadline;
  bool _cancelled = false;

  Future<_WindowObservation> get initial => _initial.future;

  void cancel() {
    _cancelled = true;
    _deadline.cancel();
    _onLate = null;
    // Release a retired awaiter immediately. The caller's request guard drops
    // this internal result, so cancellation is not exported as a query failure.
    if (!_initial.isCompleted) {
      _initial.complete((
        background: _fallback,
        outcome: _WindowQueryOutcome.failed,
      ));
    }
  }

  void _finish(_WindowObservation observation) {
    if (_cancelled) return;
    _deadline.cancel();
    final notifyLate = _onLate;
    _onLate = null;
    if (_initial.isCompleted) {
      notifyLate?.call(observation);
    } else {
      _initial.complete(observation);
    }
  }

  Future<void> _observe() async {
    try {
      final visible = await windowManager.isVisible();
      if (_cancelled) return;
      final focused = visible && await windowManager.isFocused();
      _finish((background: !focused, outcome: _WindowQueryOutcome.observed));
    } catch (error) {
      if (!_cancelled) {
        devLog(
          () =>
              'xVeil[call-notify]: window query failed (${error.runtimeType})',
        );
      }
      _finish((background: _fallback, outcome: _WindowQueryOutcome.failed));
    }
  }
}

// Construct the continuation outside the call update's closure context: it
// must not share captured call/provider locals with the notification sender.
_WindowQuery _windowQueryForOwner(
  bool fallback,
  WeakReference<_DesktopCallNotificationBridgeState> weakOwner,
  int request,
) => _WindowQuery(fallback, (observed) {
  final owner = weakOwner.target;
  if (owner == null ||
      owner._retired ||
      !owner.mounted ||
      owner._request != request) {
    return;
  }
  // Consume the eventual answer without starting the same slow query again.
  owner._refresh(windowObservation: observed);
});

Future<String?> _callerLabelWhileRinging(
  Storage storage,
  NodeId peer,
  Future<void> cancelled,
) async {
  final expired = Completer<String?>();
  final timer = Timer(_callerLabelBudget, () => expired.complete(null));
  try {
    return await Future.any<String?>([
      loadCallScreenCallerLabel(storage, peer),
      expired.future,
      cancelled.then<String?>((_) => null),
    ]);
  } catch (_) {
    // No driver/storage error text or private presentation data is retained.
    return null;
  } finally {
    timer.cancel();
  }
}

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
  Completer<void>? _labelCancellation;
  _WindowQuery? _windowQuery;
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

  void _refresh({_WindowObservation? windowObservation}) {
    if (_retired || !mounted) return;
    unawaited(
      _update(windowObservation: windowObservation).catchError((Object error) {
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

  void _cancelLabel() {
    final cancellation = _labelCancellation;
    _labelCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  @override
  void onWindowEvent(String eventName) => _refresh();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _refresh();

  Future<void> _update({_WindowObservation? windowObservation}) async {
    final request = ++_request;
    _windowQuery?.cancel();
    _windowQuery = null;
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
    _WindowQueryOutcome? windowQuery;
    if (_windows && settings.enabled && (directRinging || groupRinging)) {
      // Optional window chrome must not suppress a lifecycle-backed alert.
      if (windowObservation == null) {
        final query = _windowQueryForOwner(
          background,
          WeakReference(this),
          request,
        );
        _windowQuery = query;
        windowObservation = await query.initial;
      }
      background = windowObservation.background;
      windowQuery = windowObservation.outcome;
    }
    if (_retired || !mounted || request != _request) return;
    if (windowQuery != null) {
      diagnosticJournal.record(
        DiagnosticEvent.callAlertWindowQuery,
        values: {
          DiagnosticMetric.code: windowQuery.index,
          DiagnosticMetric.background: background ? 1 : 0,
          DiagnosticMetric.success: windowQuery == _WindowQueryOutcome.observed
              ? 1
              : 0,
        },
      );
    }
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
    _cancelLabel();
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
    final labelCancellation = Completer<void>();
    _labelCancellation = labelCancellation;
    Storage? presentationStorage;
    Future<String?>? presentationLabel;
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
            presentationStorage ??= ref.read(storageProvider);
            presentationLabel ??= _callerLabelWhileRinging(
              presentationStorage!,
              directRinging ? call!.mediaIdentity : room!.initiator,
              labelCancellation.future,
            );
            body = await presentationLabel ?? body;
          } catch (_) {
            // Provider failure also falls back. A captured storage remains
            // pinned even if its read fails or times out during retirement.
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
    _windowQuery?.cancel();
    _windowQuery = null;
    _cancelLabel();
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
