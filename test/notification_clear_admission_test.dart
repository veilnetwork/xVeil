import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/notification_service.dart';

import 'support/queued_clear_notification_plugin.dart';

Future<bool> _post(
  NotificationService service,
  int id,
  bool Function() current,
) => service.showIfCurrent(
  id: id,
  title: 'xVeil',
  body: 'Controlled incoming alert',
  payload: 'new-$id',
  isCurrent: current,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final twoIds in [false, true]) {
    test('synchronous backend respects queued clears, twoIds=$twoIds', () async {
      final plugin = QueuedClearNotificationPlugin();
      final service = NotificationService(plugin: plugin);
      await service.init(onTap: (_) {});
      // No backend gates, timers, or delayed effects. The first clear's async
      // completion lets the old per-ID queue overtake the queued second clear.
      final first = service.cancelAll();
      final second = service.cancelAll();
      final post = _post(service, 1, () => true);
      final other = twoIds ? _post(service, 2, () => true) : null;
      await Future.wait([first, second, post, ?other]);
      expect(await post, isTrue);
      expect(plugin.clearCalls, 2);
      expect(plugin.posts, twoIds ? 2 : 1);
      expect(plugin.visible, {1: 'new-1', if (twoIds) 2: 'new-2'});
    });
  }

  for (final retired in [false, true]) {
    for (final twoIds in [false, true]) {
      test('pending clear admission retired=$retired twoIds=$twoIds', () async {
        final plugin = QueuedClearNotificationPlugin()..holdFirstClear = true;
        final service = NotificationService(plugin: plugin);
        await service.init(onTap: (_) {});
        final first = service.cancelAll();
        await plugin.firstClearEntered.future;
        final second = service.cancelAll();
        var current = true;
        final post = _post(service, 1, () => current);
        final other = twoIds ? _post(service, 2, () => current) : null;
        late int postsWhileClearing;
        try {
          await pumpEventQueue();
          postsWhileClearing = plugin.posts;
          if (retired) current = false;
        } finally {
          plugin.release();
          await Future.wait([first, second, post, ?other]);
        }
        expect(postsWhileClearing, 0);
        expect(await post, !retired);
        if (other != null) expect(await other, !retired);
        expect(
          plugin.visible,
          retired ? <int, String?>{} : {1: 'new-1', if (twoIds) 2: 'new-2'},
        );
        expect(plugin.posts, retired ? 0 : (twoIds ? 2 : 1));
      });
    }
  }

  test(
    'admission drains additional clear intents queued during its wait',
    () async {
      final plugin = QueuedClearNotificationPlugin()..holdFirstClear = true;
      final service = NotificationService(plugin: plugin);
      await service.init(onTap: (_) {});
      final first = service.cancelAll();
      await plugin.firstClearEntered.future;
      final post = _post(service, 1, () => true);
      late int postsWhileClearing;
      Future<void>? second, third;
      try {
        await pumpEventQueue();
        postsWhileClearing = plugin.posts;
        second = service.cancelAll();
        third = service.cancelAll();
      } finally {
        plugin.release();
        await Future.wait([first, post, ?second, ?third]);
      }
      expect(postsWhileClearing, 0);
      expect(plugin.clearCalls, 3);
      expect(await post, isTrue);
      expect(plugin.visible, {1: 'new-1'});
    },
  );

  for (final recovers in [false, true]) {
    test('post honors retained clear intent, recovers=$recovers', () async {
      final plugin = QueuedClearNotificationPlugin()..refuseClear = true;
      plugin.visible[33] = 'old-alert';
      final service = NotificationService(plugin: plugin);
      await service.init(onTap: (_) {});
      await service.cancelAll();
      expect(plugin.clearCalls, 1);
      plugin.refuseClear = !recovers;
      final posted = await _post(service, 1, () => true);
      expect(plugin.clearCalls, 2);
      expect(posted, recovers);
      expect(plugin.posts, recovers ? 1 : 0);
      expect(plugin.visible, recovers ? {1: 'new-1'} : {33: 'old-alert'});
    });
  }

  test('ordinary post without a clear remains admitted', () async {
    final plugin = QueuedClearNotificationPlugin();
    final service = NotificationService(plugin: plugin);
    await service.init(onTap: (_) {});
    expect(await _post(service, 1, () => true), isTrue);
    expect(plugin.clearCalls, 0);
    expect(plugin.visible, {1: 'new-1'});
  });

  test('already retired ticket does not retry clearing or post', () async {
    final plugin = QueuedClearNotificationPlugin()..refuseClear = true;
    final service = NotificationService(plugin: plugin);
    await service.init(onTap: (_) {});
    await service.cancelAll();
    expect(await _post(service, 1, () => false), isFalse);
    expect(plugin.clearCalls, 1);
    expect(plugin.posts, 0);
  });
}
