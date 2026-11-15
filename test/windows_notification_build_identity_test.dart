import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/notification_service.dart';

class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  InitializationSettings? received;
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    received = settings;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async =>
      const NotificationAppLaunchDetails(false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('variant namespaces change toast and activator identities together', () {
    final production = windowsNotificationSettingsForNamespace('');
    final first = windowsNotificationSettingsForNamespace(
      'storage-qa-20261115',
    );
    final again = windowsNotificationSettingsForNamespace(
      'storage-qa-20261115',
    );
    final other = windowsNotificationSettingsForNamespace('storage-qa-next');
    expect(first.appName, isNot(production.appName));
    expect(first.appUserModelId, isNot(production.appUserModelId));
    expect(first.guid, '83d3277b-3a97-596f-8397-afafdbe2bb55');
    expect(first.guid, isNot(production.guid));
    expect(again.guid, first.guid);
    expect(other.guid, isNot(first.guid));
    expect(other.appUserModelId, isNot(first.appUserModelId));
  });

  test('invalid variant refuses instead of using production registration', () {
    for (final namespace in ['../private', ' bad', 'bad.name', 'a' * 33]) {
      expect(
        () => windowsNotificationSettingsForNamespace(namespace),
        throwsArgumentError,
      );
    }
  });

  test(
    'notification service uses one coherent Windows build identity',
    () async {
      final plugin = _Plugin();
      final service = NotificationService(plugin: plugin);
      await service.init(onTap: (_) {});
      expect(service.isReady, isTrue);
      final windows = plugin.received!.windows!;
      const qa = bool.fromEnvironment('XVEIL_TEST_QA_NOTIFICATION_BUILD');
      expect(windows.appName, qa ? 'xVeil (storage-qa-20261115)' : 'xVeil');
      expect(
        windows.appUserModelId,
        qa ? 'VeilNetwork.xVeil.storage-qa-20261115' : 'VeilNetwork.xVeil',
      );
      expect(
        windows.guid,
        qa
            ? '83d3277b-3a97-596f-8397-afafdbe2bb55'
            : 'c83f7894-6540-4f51-9d67-03cb858d9f6f',
      );
    },
  );
}
