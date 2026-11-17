import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/notification_service.dart';

class _StartingPlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final entered = Completer<void>();
  final release = Completer<void>();
  int posts = 0;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    entered.complete();
    await release.future;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async =>
      const NotificationAppLaunchDetails(false);

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    posts++;
  }
}

class _ReplyFailurePlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  final entered = Completer<void>(), release = Completer<void>();
  final visible = <int, String?>{};
  final cancelled = <int>[];
  int posts = 0;
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
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    visible[id] = payload;
    if (++posts == 1) {
      entered.complete();
      await release.future;
      throw StateError('synthetic response failure after backend effect');
    }
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add(id);
    visible.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final change in ['retired', 'successor', 'current']) {
    test('backend reply failure respects $change notification owner', () async {
      final plugin = _ReplyFailurePlugin();
      final service = NotificationService(plugin: plugin);
      await service.init(onTap: (_) {});
      expect(service.isReady, isTrue);
      var current = true;
      final first = service.showIfCurrent(
        isCurrent: () => current,
        id: 1,
        title: 'xVeil',
        body: 'old',
        payload: 'old',
      );
      Future<bool>? second;
      try {
        await plugin.entered.future;
        current = change == 'current';
        if (change == 'successor') {
          second = service.showIfCurrent(
            isCurrent: () => true,
            id: 1,
            title: 'xVeil',
            body: 'new',
            payload: 'new',
          );
        }
      } finally {
        plugin.release.complete();
        expect(
          await first,
          isFalse,
          reason: 'the real wrapper reports the plugin exception as false',
        );
        if (second != null) expect(await second, isTrue);
      }
      expect(plugin.cancelled, change == 'current' ? isEmpty : [1]);
      expect(plugin.visible, switch (change) {
        'current' => {1: 'old'},
        'successor' => {1: 'new'},
        _ => <int, String?>{},
      });
    });
  }

  for (final retireDuringStartup in [false, true]) {
    test('guarded alert joins startup; retired=$retireDuringStartup', () async {
      final plugin = _StartingPlugin();
      final service = NotificationService(plugin: plugin);
      var current = true;
      final startup = service.init(onTap: (_) {});
      await plugin.entered.future;
      final post = service.showIfCurrent(
        isCurrent: () => current,
        id: 1,
        title: 'xVeil',
        body: 'Incoming call',
      );
      try {
        // Give the queued operation a turn while OS initialization is held.
        // No elapsed-time limit or timing threshold decides the verdict.
        await Future<void>.delayed(Duration.zero);
        expect(service.isReady, isFalse);
        expect(plugin.posts, 0);
        if (retireDuringStartup) current = false;
      } finally {
        plugin.release.complete();
        await startup;
      }
      expect(await post, !retireDuringStartup);
      expect(plugin.posts, retireDuringStartup ? 0 : 1);
      if (retireDuringStartup) {
        expect(
          await service.showIfCurrent(
            isCurrent: () => true,
            id: 1,
            title: 'xVeil',
            body: 'Next call',
          ),
          isTrue,
        );
        expect(plugin.posts, 1);
      }
    });
  }
}
