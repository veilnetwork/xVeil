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
  /// supports. Windows is unsupported by the plugin — never touch it there.
  static bool get _supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux;

  static const _channelId = 'xveil_messages';
  static const _channelName = 'Messages';

  /// Initialize the plugin and wire the tap handler. [onTap] receives the
  /// notification's payload (a conversation id) so the app can open that chat.
  /// Idempotent + fail-safe — a failure here must never block app startup.
  Future<void> init({required void Function(String? payload) onTap}) async {
    if (_ready || !_supported) return;
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
      await _plugin.initialize(
        const InitializationSettings(
            android: android, iOS: darwin, macOS: darwin, linux: linux),
        onDidReceiveNotificationResponse: (resp) => onTap(resp.payload),
      );
      _ready = true;
    } catch (e) {
      devLog(() => 'xVeil[notify]: init failed: $e');
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
                    IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            true;
      }
    } catch (e) {
      devLog(() => 'xVeil[notify]: permission request failed: $e');
    }
    return true;
  }

  /// Post a notification. [id] is the OS notification id — reuse the same id per
  /// conversation so a chat's notifications collapse instead of stacking.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
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
