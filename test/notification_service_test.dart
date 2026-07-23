import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:xveil/data/notifications/notification_service.dart';

class _LaunchDetailsPlatform extends FlutterLocalNotificationsPlatform {
  _LaunchDetailsPlatform(this.details);

  final NotificationAppLaunchDetails details;

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => details;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'cold notification tap is delivered after plugin initialization',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      FlutterLocalNotificationsPlatform.instance = _LaunchDetailsPlatform(
        const NotificationAppLaunchDetails(
          true,
          notificationResponse: NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: 'space:feed',
          ),
        ),
      );
      String? tapped;
      final service = NotificationService();

      await service.init(onTap: (payload) => tapped = payload);

      expect(service.isReady, isTrue);
      expect(tapped, 'space:feed');
    },
  );

  test('cold inline reply is trimmed and kept out of the tap path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    FlutterLocalNotificationsPlatform.instance = _LaunchDetailsPlatform(
      const NotificationAppLaunchDetails(
        true,
        notificationResponse: NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: NotificationService.replyActionId,
          input: '  hello  ',
          payload: 'peer',
        ),
      ),
    );
    String? tapped;
    (String, String)? reply;
    final service = NotificationService();

    await service.init(
      onTap: (payload) => tapped = payload,
      onReply: (payload, text) => reply = (payload, text),
    );

    expect(tapped, isNull);
    expect(reply, ('peer', 'hello'));
  });
}
