import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/chat/notification_binder.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_setting_storage.dart';

NodeId _id(int v) => NodeId(Uint8List.fromList(List.filled(32, v)));

class _App extends AppController {
  @override
  AppState build() =>
      AppState(AppPhase.ready, identity: Identity(nodeId: _id(1)));
  void changeIdentity() {
    state = AppState(AppPhase.ready, identity: Identity(nodeId: _id(7)));
  }
}

class _Storage extends FakeSettingStorage {
  @override
  Future<Contact?> getContact(NodeId id) async => Contact(nodeId: id);
  @override
  Future<List<Conversation>> loadConversations() async => [];
}

class _Messaging implements MessagingService {
  final notices = StreamController<IncomingNotice>.broadcast();
  @override
  Stream<IncomingNotice> get incoming => notices.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _groupSource = StateProvider<GroupService?>((_) => null);

class _Groups implements GroupService {
  int streamReads = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      streamReads++;
      return const Stream<Never>.empty();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Notifications extends NotificationService {
  int? holdId;
  final entered = Completer<void>(), release = Completer<void>();
  final visible = <int, String?>{};
  final cancelled = <int>[];
  int shows = 0;
  bool failFirstShow = false;
  Completer<void>? cancelEntered, cancelRelease;

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> cancelAll() async => visible.clear();
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    cancelEntered?.complete();
    await cancelRelease?.future;
    visible.remove(id);
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    shows++;
    if (failFirstShow && shows == 1) throw StateError('fixture OS refusal');
    visible[id] = payload;
    if (id == holdId && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return true;
  }
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  Future<bool> post(
    _Notifications service,
    int id,
    String payload,
    bool Function() current,
  ) => service.showIfCurrent(
    id: id,
    title: 'fixture',
    body: 'fixture',
    payload: payload,
    isCurrent: current,
  );

  test(
    'stale take-down finishes before a later post using the same OS id',
    () async {
      final service = _Notifications()
        ..holdId = 1
        ..cancelEntered = Completer<void>()
        ..cancelRelease = Completer<void>();
      var current = true;
      final first = post(service, 1, 'old', () => current);
      await service.entered.future.timeout(const Duration(seconds: 1));
      current = false;
      final second = post(service, 1, 'new', () => true);
      service.release.complete();
      try {
        await service.cancelEntered!.future.timeout(const Duration(seconds: 1));
        expect(service.shows, 1);
      } finally {
        service.cancelRelease!.complete();
        expect(await first, isFalse);
        expect(await second, isTrue);
      }
      expect(service.visible[1], 'new');
    },
  );

  test('a stale queued ticket never reaches the OS', () async {
    final service = _Notifications()..holdId = 1;
    final first = post(service, 1, 'first', () => true);
    await service.entered.future.timeout(const Duration(seconds: 1));
    final skipped = post(service, 1, 'stale', () => false);
    service.release.complete();
    expect(await first, isTrue);
    expect(await skipped, isFalse);
    expect(service.shows, 1);
    expect(service.visible[1], 'first');
  });

  test('a refused post does not poison the next ticket', () async {
    final service = _Notifications()..failFirstShow = true;
    final failed = post(service, 1, 'failed', () => true);
    final next = post(service, 1, 'new', () => true);
    await expectLater(failed, throwsStateError);
    expect(await next, isTrue);
    expect(service.visible[1], 'new');
  });

  test(
    'a pending message does not block a different OS notification id',
    () async {
      final service = _Notifications()..holdId = 1;
      final first = post(service, 1, 'message', () => true);
      await service.entered.future.timeout(const Duration(seconds: 1));
      try {
        expect(await post(service, 2, 'clear-request', () => true), isTrue);
        expect(service.visible[2], 'clear-request');
      } finally {
        service.release.complete();
        await first;
      }
    },
  );

  late _Messaging messaging;
  late _Notifications notifications;
  late StreamController<List<PendingClearRequest>> requests;
  late ProviderContainer container;
  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    messaging = _Messaging();
    notifications = _Notifications();
    requests = StreamController<List<PendingClearRequest>>.broadcast();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(_Storage()),
          messagingServiceProvider.overrideWithValue(messaging),
          groupServiceProvider.overrideWith((ref) => ref.watch(_groupSource)),
          notificationServiceProvider.overrideWithValue(notifications),
          appControllerProvider.overrideWith(_App.new),
          pendingClearRequestsProvider.overrideWith((_) => requests.stream),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: NotificationBinder(child: Scaffold(body: Text('fixture'))),
        ),
      ),
    );
    await _pump(tester);
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await _pump(tester);
    }
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (!notifications.release.isCompleted) notifications.release.complete();
    await _pump(tester);
    await tester.pumpWidget(const SizedBox());
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await messaging.notices.close();
    await requests.close();
  }

  void message(int peer) => messaging.notices.add(
    IncomingNotice(from: _id(peer), preview: 'fixture', isFile: false),
  );

  testWidgets(
    'an incoming message cannot cancel a pending clear-request alert',
    (tester) async {
      await mount(tester);
      try {
        notifications.holdId = kNotificationIdClearRequests;
        requests.add([
          PendingClearRequest(
            chatHex: _id(2).hex,
            requesterHex: _id(2).hex,
            atMs: 1000,
            seq: 1,
            watermark: {},
          ),
        ]);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        message(3);
        await _pump(tester);
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.visible, contains(kNotificationIdClearRequests));
        expect(
          notifications.visible,
          contains(notificationIdForIncomingMessage('')),
        );
        expect(
          notifications.cancelled,
          isNot(contains(kNotificationIdClearRequests)),
        );
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'a late older OS completion cannot remove the newest message alert',
    (tester) async {
      await mount(tester);
      try {
        final id = notificationIdForIncomingMessage('');
        notifications.holdId = id;
        message(2);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        message(3);
        await _pump(tester);
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.shows, greaterThanOrEqualTo(2));
        expect(notifications.visible, contains(id));
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'group service startup cannot cancel the active request list alert',
    (tester) async {
      await mount(tester);
      try {
        notifications.holdId = kNotificationIdClearRequests;
        requests.add([
          PendingClearRequest(
            chatHex: _id(2).hex,
            requesterHex: _id(2).hex,
            atMs: 1000,
            seq: 1,
            watermark: {},
          ),
        ]);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        final groups = _Groups();
        container.read(_groupSource.notifier).state = groups;
        expect(container.read(groupServiceProvider), same(groups));
        await _pump(tester);
        expect(groups.streamReads, greaterThanOrEqualTo(5));
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.visible, contains(kNotificationIdClearRequests));
      } finally {
        await cleanup(tester);
      }
    },
  );

  for (final clear in [false, true]) {
    testWidgets(
      'a ${clear ? 'clear request' : 'message'} post notices an identity change before service rebind',
      (tester) async {
        await mount(tester);
        try {
          final id = clear
              ? kNotificationIdClearRequests
              : notificationIdForIncomingMessage('');
          notifications.holdId = id;
          if (clear) {
            requests.add([
              PendingClearRequest(
                chatHex: _id(2).hex,
                requesterHex: _id(2).hex,
                atMs: 1000,
                seq: 1,
                watermark: {},
              ),
            ]);
          } else {
            message(2);
          }
          await _pump(tester);
          expect(notifications.entered.isCompleted, isTrue);
          (container.read(appControllerProvider.notifier) as _App)
              .changeIdentity();
          expect(
            container.read(messagingServiceProvider),
            same(messaging),
            reason:
                'the binder has not been notified of a replacement service yet',
          );
          notifications.release.complete();
          await _pump(tester);
          expect(notifications.visible, isNot(contains(id)));
          expect(notifications.cancelled, contains(id));
        } finally {
          await cleanup(tester);
        }
      },
    );
  }

  testWidgets('disposing the binder reclaims a late OS post safely', (
    tester,
  ) async {
    await mount(tester);
    try {
      final id = notificationIdForIncomingMessage('');
      notifications.holdId = id;
      message(2);
      await _pump(tester);
      expect(notifications.entered.isCompleted, isTrue);
      final binder = tester.state(find.byType(NotificationBinder));
      await tester.pumpWidget(const SizedBox());
      // The background lifecycle intentionally disables normal frames.
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(binder.mounted, isFalse);
      notifications.release.complete();
      await _pump(tester);
      expect(notifications.visible, isNot(contains(id)));
      expect(notifications.cancelled, contains(id));
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup(tester);
    }
  });
}
