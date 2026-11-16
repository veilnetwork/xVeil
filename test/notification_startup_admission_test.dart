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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
