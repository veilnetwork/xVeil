import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backend effects happen immediately. Only the first clear's acknowledgement
/// can be gated; subsequent clears are queued by the real NotificationService.
class QueuedClearNotificationPlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  bool holdFirstClear = false;
  bool refuseClear = false;
  int clearCalls = 0, posts = 0;
  final firstClearEntered = Completer<void>();
  final firstClearReply = Completer<void>();
  final visible = <int, String?>{};

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async =>
      const NotificationAppLaunchDetails(false);

  @override
  Future<void> cancelAll() async {
    clearCalls++;
    if (refuseClear) throw StateError('controlled clear refusal');
    visible.clear();
    if (!firstClearEntered.isCompleted) {
      firstClearEntered.complete();
      if (holdFirstClear) await firstClearReply.future;
    }
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    posts++;
    visible[id] = payload;
  }

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      visible.remove(id);

  void release() {
    if (!firstClearReply.isCompleted) firstClearReply.complete();
  }
}
