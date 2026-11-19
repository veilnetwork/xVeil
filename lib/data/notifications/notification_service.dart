import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';

import '../../core/diagnostic_journal.dart';
import '../../core/log.dart';
import 'windows_toast_content.dart';

/// Windows keeps both toast history and the COM activator outside our data
/// directory. A separately named QA executable must also separate these IDs.
/// One build namespace changes all three fields together; it is never derived
/// from an identity, a password, or the number of hidden spaces.
WindowsInitializationSettings windowsNotificationSettingsForNamespace(
  String namespace,
) {
  if (namespace.isEmpty) {
    return const WindowsInitializationSettings(
      appName: 'xVeil',
      appUserModelId: 'VeilNetwork.xVeil',
      guid: 'c83f7894-6540-4f51-9d67-03cb858d9f6f',
    );
  }
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(namespace)) {
    throw ArgumentError('Invalid Windows notification namespace');
  }
  return WindowsInitializationSettings(
    appName: 'xVeil ($namespace)',
    appUserModelId: 'VeilNetwork.xVeil.$namespace',
    guid: Uuid().v5(
      Namespace.url.value,
      'urn:veilnetwork:xveil:notifications:$namespace',
    ),
  );
}

typedef NotificationPost = ({
  String title,
  String body,
  String? payload,
  String? replyLabel,
  String? replyHint,
});

/// Thin wrapper over `flutter_local_notifications` for incoming-message alerts.
///
/// Deniability note: this only DISPLAYS what the caller passes. The decision of
/// WHETHER to notify and WHAT to put in the title/body (hidden vs full preview)
/// lives in the controller above it — keep this layer dumb so the privacy policy
/// has exactly one home.
class NotificationService {
  final Map<int, Future<void>> _posts = {};

  /// Post only while the originating session/ticket is current. Operations for
  /// one OS id are ordered through late completion and any required take-down;
  /// an obsolete post must never cancel a newer alert reusing that id.
  Future<bool> showIfCurrent({
    required bool Function() isCurrent,
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) => showPreparedIfCurrent(
    isCurrent: isCurrent,
    id: id,
    prepare: () => (
      title: title,
      body: body,
      payload: payload,
      replyLabel: replyLabel,
      replyHint: replyHint,
    ),
  );

  /// Apply presentation policy after queue, startup and clear waits, just
  /// before handing the post to the OS. [prepare] must be synchronous.
  Future<bool> showPreparedIfCurrent({
    required bool Function() isCurrent,
    required int id,
    required NotificationPost Function() prepare,
  }) {
    final result = (_posts[id] ?? Future<void>.value()).then((_) async {
      if (!isCurrent()) return false;
      // The first call/message can arrive while the OS backend is starting.
      // Join that owned initialization instead of permanently losing its post.
      final startup = _initializing;
      if (startup != null) await startup;
      if (!isCurrent()) return false;
      // Readiness checked by a caller can precede metadata/queue waits. A
      // global clear requested meanwhile must finish before this post, across
      // every OS id; otherwise a queued clear can erase a fresh accepted alert.
      await _waitForNativeClears();
      if (!isCurrent() || _clearWanted) return false;
      final post = prepare();
      try {
        final posted = await show(
          id: id,
          title: post.title,
          body: post.body,
          payload: post.payload,
          replyLabel: post.replyLabel,
          replyHint: post.replyHint,
        );
        return posted && isCurrent();
      } finally {
        // Failure is not proof that the OS was untouched. A retired ticket
        // must withdraw even after a false/exceptional completion, before a
        // successor using this id can enter the backend.
        if (!isCurrent()) await cancel(id);
      }
    });
    late final Future<void> tail;
    void release() {
      if (identical(_posts[id], tail)) _posts.remove(id);
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object error, StackTrace trace) => release(),
    );
    _posts[id] = tail;
    return result;
  }

  /// Order teardown against posts for the same OS id. Queue immediately when
  /// an owner retires, so its late cancellation cannot erase a successor post.
  Future<void> cancelAfterPosts(int id) {
    final result = (_posts[id] ?? Future<void>.value()).then((_) => cancel(id));
    late final Future<void> tail;
    void release() {
      if (identical(_posts[id], tail)) _posts.remove(id);
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object error, StackTrace stack) => release(),
    );
    _posts[id] = tail;
    return result;
  }

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// The init in flight, so a caller that arrives during startup can wait for
  /// it instead of being answered "not ready" and going away.
  Future<void>? _initializing;
  Future<void>? _nativeClear;

  /// A call may arrive before the notification backend finishes startup.
  /// Waiting here does not initialize a backend with missing response handlers.
  Future<bool> waitUntilReady() async {
    final running = _initializing;
    if (running != null) await running;
    await _waitForNativeClears();
    return isReady && !_clearWanted;
  }

  Future<void> _waitForNativeClears() async {
    if (isReady && _clearWanted) await cancelAll();
    while (true) {
      final clearing = _nativeClear;
      if (clearing == null) break;
      await clearing;
    }
  }

  /// A clear that arrived before there was anything to clear it with.
  ///
  /// The lock asks for this, and it used to be dropped: `init` is started
  /// fire-and-forget by the provider, and a lock during startup found
  /// `_ready` false, returned at once, and never came back. An OS notification
  /// from the previous session then outlived the lock — on a screen, after the
  /// person asked for the volume to be shut (report15 X15-M6).
  bool _clearWanted = false;

  /// Whether the running platform has a notification backend the plugin
  /// supports. Web is intentionally out of scope while xVeil remains a native
  /// deniable client.
  static bool get _supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;

  static const _channelId = 'xveil_messages';
  static const _channelName = 'Messages';

  /// Action id for the inline (RemoteInput) reply button on a message alert.
  static const replyActionId = 'xveil_reply';

  /// Initialize the plugin and wire the response handlers. [onTap] receives the
  /// notification's payload (a conversation id) so the app can open that chat;
  /// [onReply] receives (payload, text) when the user replies inline from the
  /// notification (Android RemoteInput) — routed only while the app process is
  /// ALIVE (foreground, or background with the keep-alive service), which is the
  /// only state in which the deniable node can actually send the reply.
  /// Idempotent + fail-safe — a failure here must never block app startup.
  Future<void> init({
    required void Function(String? payload) onTap,
    void Function(String payload, String text)? onReply,
  }) async {
    if (_ready || !_supported) return;
    final running = _initializing;
    if (running != null) return running;
    final gate = Completer<void>();
    _initializing = gate.future;
    try {
      await _init(onTap: onTap, onReply: onReply);
      // The ready barrier includes the clear requested before startup. A
      // failed initialization keeps the intent for the next attempt instead
      // of waiting on its own initialization future.
      if (_ready && _clearWanted) await cancelAll();
    } finally {
      _initializing = null;
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> _init({
    required void Function(String? payload) onTap,
    void Function(String payload, String text)? onReply,
  }) async {
    void handleResponse(NotificationResponse response) {
      // An inline reply (RemoteInput) carries the typed text in `input` under
      // our reply action id; anything else is a plain tap → open the chat.
      if (response.actionId == replyActionId) {
        final text = response.input?.trim() ?? '';
        final payload = response.payload;
        if (text.isNotEmpty && payload != null && payload.isNotEmpty) {
          onReply?.call(payload, text);
        }
        return;
      }
      onTap(response.payload);
    }

    try {
      // The Android launcher icon doubles as the notification icon.
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      // Defer the permission prompt to an explicit requestPermission() call so
      // it doesn't fire mid-startup.
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const linux = LinuxInitializationSettings(defaultActionName: 'Open');
      final windows = windowsNotificationSettingsForNamespace(
        const String.fromEnvironment('XVEIL_WINDOWS_NOTIFICATION_NAMESPACE'),
      );
      final initialized = await _plugin.initialize(
        settings: InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
          linux: linux,
          windows: windows,
        ),
        onDidReceiveNotificationResponse: handleResponse,
        onDidReceiveBackgroundNotificationResponse:
            _notificationBackgroundHandler,
      );
      if (initialized == false) return;
      _ready = true;
    } catch (e) {
      devLog(() => 'xVeil[notify]: init failed: $e');
      return;
    }
    // Since plugin v4, initialize() deliberately does not replay a tap that
    // launched a terminated app. Read the one-shot launch response explicitly
    // after initialization so notification deep links work from a cold start,
    // including mention links to an exact message/comment.
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        handleResponse(response);
      }
    } catch (e) {
      // Displaying future notifications is still valid even if a platform
      // cannot recover the launch response.
      devLog(() => 'xVeil[notify]: launch response unavailable: $e');
    }
  }

  /// Ask the OS for permission to post notifications (iOS/macOS always; Android
  /// 13+). Null means the backend could not report an OS decision. Platforms
  /// without this permission request report success without invoking the OS.
  Future<bool?> requestPermission() async {
    if (!_ready) return null;
    if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) {
      return true;
    }
    bool? granted;
    try {
      if (Platform.isIOS) {
        granted = await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isMacOS) {
        granted = await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else {
        granted = await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      devLog(() => 'xVeil[notify]: permission request failed: $e');
    }
    diagnosticJournal.record(
      DiagnosticEvent.notificationPermission,
      values: {
        DiagnosticMetric.state: switch (granted) {
          true => 1,
          false => 0,
          null => -1,
        },
      },
    );
    return granted;
  }

  /// Post a notification. [id] is the OS notification id — message callers
  /// reuse one id globally so startup/mailbox bursts replace instead of stack.
  /// When
  /// [replyLabel] is non-null an inline reply action (Android RemoteInput) is
  /// attached — the typed text comes back through `onReply` (see [init]). Only
  /// offer it when the sender is visible (full preview), so the user knows whom
  /// they are answering.
  ///
  /// Answers whether the backend accepted the post without an error. A false
  /// result does not establish that the OS had no side effect.
  /// It used to return void over two silent failure paths — a service that is
  /// not ready, and a plugin
  /// that threw — and the caller recorded the new alert's owner before
  /// calling: a show that did not happen left the PREVIOUS alert on screen
  /// with the new identity written against it, and its inline reply then went
  /// out from an identity that never had that conversation
  /// (report17 XV17-M12).
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    if (!_ready) return false;
    final windows = Platform.isWindows
        ? windowsToastContent(title: title, body: body, payload: payload)
        : null;
    // A routing token cannot be truncated into a different conversation.
    if (Platform.isWindows && windows == null) return false;
    try {
      final actions = (replyLabel != null && Platform.isAndroid)
          ? <AndroidNotificationAction>[
              AndroidNotificationAction(
                replyActionId,
                replyLabel,
                inputs: <AndroidNotificationActionInput>[
                  AndroidNotificationActionInput(label: replyHint),
                ],
                // MUST bring the app to the foreground (showsUserInterface:true).
                // A deniable app keeps its unlocked container + the node in the
                // MAIN isolate; with showsUserInterface:false a reply tapped while
                // backgrounded is delivered to a separate BACKGROUND isolate that
                // cannot reach either, so the reply is silently lost (the spinner
                // just hangs). Foregrounding routes the response to the main-
                // isolate handler ([onDidReceiveNotificationResponse]) where the
                // send actually works.
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ]
          : null;
      await _plugin.show(
        id: id,
        title: windows?.title ?? title,
        body: windows?.body ?? body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
            actions: actions,
          ),
          iOS: const DarwinNotificationDetails(),
          macOS: const DarwinNotificationDetails(),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
        payload: payload,
      );
      return true;
    } catch (e) {
      devLog(() => 'xVeil[notify]: show failed: $e');
      return false;
    }
  }

  /// Clear all posted notifications (e.g. when the user opens the app, or
  /// when a deniable volume is locked).
  ///
  /// Never a silent no-op. It used to return the moment `_ready` was false,
  /// which is exactly the state a lock during startup finds — so the clear the
  /// lock asked for simply did not happen, and a notification from the
  /// previous session stayed on the screen.
  Future<void> cancelAll() async {
    if (!_ready) {
      // Recorded BEFORE the wait, not after it. A startup can FAIL, and the
      // first version set this only on the branch where none was running — so
      // a clear that arrived during a failed init was dropped, and the retry
      // that succeeded later did not know it had been asked. Stale alerts
      // then survived a lock (report16 XV-12).
      if (_supported) _clearWanted = true;
      final running = _initializing;
      if (running != null) {
        // Startup is in flight. Wait for it rather than giving up: this is
        // the window the lock lands in.
        await running;
        // And it may have performed the clear on the way out — `init` does
        // that as its last step. Doing it twice is harmless and confusing;
        // the flag being down says it is done.
        if (!_clearWanted) return;
      }
      // Still nothing to clear with. The intent stands.
      if (!_ready) return;
    }
    final work = (_nativeClear ?? Future<void>.value()).then((_) async {
      // Each intent runs in order. Readiness must include an OS clear even
      // when it was requested after initialize() set the native ready bit.
      _clearWanted = false;
      try {
        await _plugin.cancelAll();
      } catch (_) {
        _clearWanted = true;
      }
    });
    _nativeClear = work;
    unawaited(
      work.then((_) {
        if (identical(_nativeClear, work)) _nativeClear = null;
      }),
    );
    await work;
  }

  /// Take ONE alert down, by the id it was posted with.
  ///
  /// [cancelAll] is the lock's tool and takes everything. This is for the
  /// alert that should never have been posted: a notification belonging to
  /// the identity that was active when it started, which finished arriving
  /// after the user had switched away. Leaving it up shows one identity's
  /// sender and preview under another, with its inline reply live.
  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {
      // Nothing to retry: the alert either went or the platform refused, and
      // a failed take-down must not become a second clear of everything.
    }
  }

  @visibleForTesting
  bool get isReady => _ready;
}

/// Fires in a SEPARATE isolate when a notification action is tapped while the app
/// PROCESS is dead. We cannot deliver a reply from here — the deniable container
/// is locked and the embedded node lives in the main isolate — so this is a
/// deliberate no-op (inline reply only works while the app / keep-alive service
/// is running). Registered so the plugin doesn't drop the background callback.
@pragma('vm:entry-point')
void _notificationBackgroundHandler(NotificationResponse response) {}
