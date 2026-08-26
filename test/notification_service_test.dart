import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:xveil/data/notifications/notification_service.dart';

class _LaunchDetailsPlatform extends FlutterLocalNotificationsPlatform {
  _LaunchDetailsPlatform(this.details, {this.startupDelay});

  final NotificationAppLaunchDetails details;

  /// Startup that takes a moment, the way a real one does — which is the
  /// window a lock lands in.
  final Duration? startupDelay;

  int cancelAllCalls = 0;

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    final wait = startupDelay;
    if (wait != null) await Future<void>.delayed(wait);
    return details;
  }

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
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

  group('clearing what is on the screen', () {
    // The lock asks for this. It used to return the moment `_ready` was false,
    // which is exactly what a lock during startup finds: `init` is started
    // fire-and-forget by the provider. So the clear did not happen, nothing
    // said so, and a notification from the previous session stayed on screen
    // after the person asked for the volume to be shut.
    const details = NotificationAppLaunchDetails(false);

    test('a clear asked for BEFORE startup still happens', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      final platform = _LaunchDetailsPlatform(details);
      FlutterLocalNotificationsPlatform.instance = platform;
      final service = NotificationService();

      await service.cancelAll();
      expect(
        platform.cancelAllCalls,
        0,
        reason: 'there was nothing to clear it with yet',
      );

      await service.init(onTap: (_) {});

      expect(
        platform.cancelAllCalls,
        1,
        reason: 'the clear the lock asked for was dropped',
      );
    });

    test('a clear asked for DURING startup waits for it', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      final platform = _LaunchDetailsPlatform(
        details,
        startupDelay: const Duration(milliseconds: 80),
      );
      FlutterLocalNotificationsPlatform.instance = platform;
      final service = NotificationService();

      final starting = service.init(onTap: (_) {});
      await service.cancelAll();

      expect(
        platform.cancelAllCalls,
        1,
        reason: 'it gave up because startup had not finished',
      );
      await starting;
    });

    test('and one asked for after startup happens at once', () async {
      // Vacuity guard: a service that never clears anything satisfies neither
      // of the above, but one that only ever clears LATER would satisfy the
      // first.
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      final platform = _LaunchDetailsPlatform(details);
      FlutterLocalNotificationsPlatform.instance = platform;
      final service = NotificationService();

      await service.init(onTap: (_) {});
      expect(platform.cancelAllCalls, 0);

      await service.cancelAll();

      expect(platform.cancelAllCalls, 1);
    });
  });
}
