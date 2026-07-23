import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/log.dart';

/// Thin wrapper over `flutter_local_notifications` for incoming-message alerts.
///
/// Deniability note: this only DISPLAYS what the caller passes. The decision of
/// WHETHER to notify and WHAT to put in the title/body (hidden vs full preview)
/// lives in the controller above it — keep this layer dumb so the privacy policy
/// has exactly one home.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

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
      const windows = WindowsInitializationSettings(
        appName: 'xVeil',
        appUserModelId: 'VeilNetwork.xVeil',
        guid: 'c83f7894-6540-4f51-9d67-03cb858d9f6f',
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
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
  /// 13+). No-op where not applicable. Returns true if granted (best-effort).
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  MacOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission() ??
            true;
      }
    } catch (e) {
      devLog(() => 'xVeil[notify]: permission request failed: $e');
    }
    return true;
  }

  /// Post a notification. [id] is the OS notification id — message callers
  /// reuse one id globally so startup/mailbox bursts replace instead of stack.
  /// When
  /// [replyLabel] is non-null an inline reply action (Android RemoteInput) is
  /// attached — the typed text comes back through `onReply` (see [init]). Only
  /// offer it when the sender is visible (full preview), so the user knows whom
  /// they are answering.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    if (!_ready) return;
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
        title: title,
        body: body,
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
    } catch (e) {
      devLog(() => 'xVeil[notify]: show failed: $e');
    }
  }

  /// Clear all posted notifications (e.g. when the user opens the app).
  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
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
